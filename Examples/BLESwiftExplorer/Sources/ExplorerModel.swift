//
//  ExplorerModel.swift
//  BLESwiftExplorer
//
//  The single owner of the app's `Central`. Because `Central` is an actor, every call is
//  `await`; async streams are consumed from `.task {}` / `Task {}` and their results are
//  published to this `@MainActor @Observable` state for SwiftUI to render.
//

import BLESwift
import BLESwiftProfiles
import BLESwiftSimulatorLink
import Foundation
import Observation

/// A discovered peripheral, wrapped for `Identifiable` list rendering.
struct DiscoveredPeripheral: Identifiable {
    var id: UUID { discovery.peripheral.uuid }
    var discovery: Discovery
    var name: String { discovery.peripheral.name }
    var rssi: Int { discovery.rssi }
    var services: [ServiceIdentifier] { discovery.advertisement.serviceUUIDs ?? [] }
}

/// A single connection-log line.
struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

/// Which GATT-compatibility profile the next connect uses (Task 5).
enum CompatibilityChoice: String, CaseIterable, Identifiable {
    case strict, lenient, customLenientRead
    var id: String { rawValue }

    var value: GATTCompatibility {
        switch self {
        case .strict: return .strict
        case .lenient: return .lenient
        // A custom `GATTCompatibility` (Task 5): read without the `.read` property, but
        // keep filtered discovery and strict notify/write.
        case .customLenientRead: return GATTCompatibility(allowReadWithoutProperty: true)
        }
    }
}

@MainActor
@Observable
final class ExplorerModel {

    // The single `Central`, built synchronously at launch (restoration needs it early).
    let central: Central

    // State & authorization (Screen 1).
    var centralState: CentralState = .unknown
    var authorization: BluetoothAuthorization = .notDetermined

    // Scan results (Screen 2).
    var isScanning = false
    var discoveries: [DiscoveredPeripheral] = []
    var scanError: String?

    // Connection log (Screen 4).
    var connectionLog: [LogEntry] = []

    // Saved devices (Screen 5).
    var savedDeviceIDs: [UUID] {
        didSet { persistSavedDevices() }
    }

    // System connection events (Screen 6).
    var systemEventLog: [LogEntry] = []

    // Background restoration (Screen 7).
    var restorationLog: [LogEntry] = []

    private var scanTask: Task<Void, Never>?
    private let savedDevicesKey = "BLESwiftExplorer.savedDeviceIDs"

    init() {
        #if targetEnvironment(simulator)
        // The Simulator has no Bluetooth; route Central/PeripheralHost to a host-side
        // bleswift-provider (BLESWIFT_LINK overrides the endpoint).
        // Must stay ahead of the `Central(configuration:)` below, in this same
        // initializer: `Central` resolves its backend from `BackendRegistry` once, at
        // construction, so an install that ran after it would leave this `Central` on
        // CoreBluetooth for good.
        SimulatorLink.install()
        #endif

        // Restoration is iOS-only; on macOS the plain `Configuration` initializer is used.
        #if os(iOS)
        let configuration = Configuration(
            showPowerAlert: true,
            restoration: RestorationConfiguration(identifier: "com.bleswift.explorer.central")
        )
        #else
        let configuration = Configuration(showPowerAlert: true)
        #endif
        self.central = Central(configuration: configuration)

        let stored = UserDefaults.standard.array(forKey: savedDevicesKey) as? [String] ?? []
        self.savedDeviceIDs = stored.compactMap(UUID.init(uuidString:))

        // Start consuming restoration events immediately, in the same launch path — the
        // stream replays everything buffered since `Central.init`.
        #if os(iOS)
        Task { [weak self] in await self?.consumeRestorationEvents() }
        #endif
    }

    /// Kicks off the long-lived stream consumers. Called from the root view's `.task`.
    func start() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.consumeStateEvents() }
            group.addTask { [weak self] in await self?.consumeConnectionEvents() }
        }
    }

    // MARK: - Screen 1: state & authorization

    private func consumeStateEvents() async {
        for await state in await central.stateEvents() {
            centralState = state
            authorization = await central.authorization
        }
    }

    // MARK: - Screen 2: scanning with a ScanFilter (Task 4)

    /// Starts a filtered scan. Every field of `ScanFilter` reachable from the UI is wired
    /// through here, plus `allowDuplicates`, `rssiThreshold`, `lossTimeout`, and `timeout`.
    func startScan(filter: ScanFilter, allowDuplicates: Bool, rssiThreshold: Int?) {
        stopScan()
        discoveries = []
        scanError = nil
        isScanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await central.scan(
                    filter: filter,
                    allowDuplicates: allowDuplicates,
                    rssiThreshold: rssiThreshold,
                    lossTimeout: .seconds(15),
                    timeout: nil
                )
                for try await event in stream {
                    switch event {
                    case .discovered(let discovery), .updated(let discovery):
                        upsert(discovery)
                    case .lost(let discovery):
                        discoveries.removeAll { $0.id == discovery.peripheral.uuid }
                    @unknown default:
                        break
                    }
                }
            } catch {
                scanError = String(describing: error)
            }
            isScanning = false
        }
    }

    /// A baseline `scan(services:)` (no `ScanFilter`) — exercises the pre-Task-4 overload.
    func startServiceScan(services: [ServiceIdentifier]) {
        stopScan()
        discoveries = []
        scanError = nil
        isScanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in await central.scan(services: services) {
                    if case .discovered(let discovery) = event { upsert(discovery) }
                }
            } catch {
                scanError = String(describing: error)
            }
            isScanning = false
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func upsert(_ discovery: Discovery) {
        let wrapped = DiscoveredPeripheral(discovery: discovery)
        if let index = discoveries.firstIndex(where: { $0.id == wrapped.id }) {
            discoveries[index] = wrapped
        } else {
            discoveries.append(wrapped)
        }
    }

    /// `findFirst(matching:timeout:)` (Task 4): returns the first sighting matching `filter`.
    func findFirst(matching filter: ScanFilter) async -> String {
        do {
            let discovery = try await central.findFirst(matching: filter, timeout: .seconds(10))
            return "Found \(discovery.peripheral.name) @ \(discovery.rssi) dBm"
        } catch {
            return "findFirst failed: \(error)"
        }
    }

    // MARK: - Connecting (Tasks 4 & 5 & 7)

    /// Connects to a discovered peripheral. `compatibility` (Task 5) and, on iOS,
    /// `requiresANCS` (Task 7) are threaded through the baseline `connect(_:reconnect:...)`.
    func connect(
        _ discovery: Discovery,
        compatibility: GATTCompatibility,
        requiresANCS: Bool
    ) async -> Peripheral? {
        stopScan()
        do {
            let peripheral: Peripheral
            #if os(iOS)
            peripheral = try await central.connect(
                discovery.peripheral,
                reconnect: .always(maxAttempts: 5),
                compatibility: compatibility,
                requiresANCS: requiresANCS
            )
            #else
            peripheral = try await central.connect(
                discovery.peripheral,
                reconnect: .always(maxAttempts: 5),
                compatibility: compatibility
            )
            #endif
            rememberSavedDevice(discovery.peripheral.uuid)
            return peripheral
        } catch {
            appendConnectionLog("Connect failed: \(error)")
            return nil
        }
    }

    // MARK: - Screen 4: connection log (Task 2 notificationsRestored)

    private func consumeConnectionEvents() async {
        for await event in await central.connectionEvents() {
            switch event {
            case .connecting(let id):
                appendConnectionLog("Connecting \(id.name)")
            case .connected(let id):
                appendConnectionLog("Connected \(id.name)")
            case .disconnected(let id, let error, let willReconnect):
                appendConnectionLog("Disconnected \(id.name): \(error.map { "\($0)" } ?? "clean"); willReconnect=\(willReconnect)")
            case .reconnecting(let id, let attempt):
                appendConnectionLog("Reconnecting \(id.name) (attempt \(attempt))")
            case .notificationsRestored(let id, let restored, let failed):
                appendConnectionLog("Notifications restored \(id.name): \(restored.count) ok, \(failed.count) failed")
            @unknown default:
                break
            }
        }
    }

    func appendConnectionLog(_ text: String) {
        connectionLog.append(LogEntry(text: text))
        if connectionLog.count > 200 { connectionLog.removeFirst(connectionLog.count - 200) }
    }

    // MARK: - Screen 5: saved devices (Task 4 connect(identifier:fallbackScan:))

    /// Reconnects a saved peripheral by UUID, falling back to a `ScanFilter` scan when the
    /// system no longer knows it (`connect(identifier:fallbackScan:reconnect:...)`).
    func reconnectSaved(_ identifier: UUID, fallback: ScanFilter?) async -> Peripheral? {
        do {
            let peripheral = try await central.connect(
                identifier: identifier,
                fallbackScan: fallback,
                reconnect: .always(),
                timeout: .seconds(15),
                compatibility: .strict
            )
            return peripheral
        } catch {
            appendConnectionLog("Reconnect \(identifier) failed: \(error)")
            return nil
        }
    }

    /// Baseline retrieval: peripherals the system already has connected for these services.
    func systemConnected(services: [ServiceIdentifier]) async -> [PeripheralIdentifier] {
        (try? await central.systemConnectedPeripherals(withServices: services)) ?? []
    }

    private func rememberSavedDevice(_ uuid: UUID) {
        guard !savedDeviceIDs.contains(uuid) else { return }
        savedDeviceIDs.append(uuid)
    }

    func removeSavedDevice(_ uuid: UUID) {
        savedDeviceIDs.removeAll { $0 == uuid }
    }

    private func persistSavedDevices() {
        UserDefaults.standard.set(savedDeviceIDs.map(\.uuidString), forKey: savedDevicesKey)
    }

    // MARK: - Screen 6: system connection events (Task 7)

    #if !os(macOS)
    /// Subscribes to system-level connection events (`connectionEventRegistration` +
    /// `SystemConnectionEvent`). Not available on macOS.
    func consumeSystemConnectionEvents(services: [ServiceIdentifier]?) async {
        for await event in await central.connectionEventRegistration(services: services, peripherals: nil) {
            let verb: String
            switch event.kind {
            case .peerConnected: verb = "peerConnected"
            case .peerDisconnected: verb = "peerDisconnected"
            @unknown default: verb = "unknown"
            }
            systemEventLog.append(LogEntry(text: "\(event.peripheral.name): \(verb)"))
            if systemEventLog.count > 200 { systemEventLog.removeFirst(systemEventLog.count - 200) }
        }
    }
    #endif

    // MARK: - Screen 7: background restoration (iOS)

    #if os(iOS)
    private func consumeRestorationEvents() async {
        for await event in await central.restorationEvents() {
            let text: String
            switch event {
            case .willRestore(let state):
                text = "willRestore: \(state.peripherals.count) peripheral(s)"
            case .restoredConnection(let id):
                text = "restoredConnection: \(id.name)"
            case .failedToRestoreConnection(let id, let error):
                text = "failedToRestore: \(id.name): \(error)"
            case .unhandledNotification(let id, let characteristic, _):
                text = "unhandledNotification: \(id.name) \(characteristic.uuidString)"
            @unknown default:
                text = "unknown restoration event"
            }
            restorationLog.append(LogEntry(text: text))
            if restorationLog.count > 200 { restorationLog.removeFirst(restorationLog.count - 200) }
        }
    }
    #endif
}
