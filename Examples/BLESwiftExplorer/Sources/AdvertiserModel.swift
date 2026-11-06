//
//  AdvertiserModel.swift
//  BLESwiftExplorer
//
//  The peripheral-role counterpart to `ExplorerModel`. It is a `PeripheralHost` that advertises a
//  Heart Rate service, answers reads and writes, and notifies subscribers every second. In the
//  Simulator it runs over the simulator link (see `ExplorerModel.init()`), so a `bleswift-provider`
//  on the host can see the app as an advertising peripheral.
//

#if os(iOS) || os(macOS)

import BLESwift
import BLESwiftProfiles
import Foundation
import Observation

@MainActor
@Observable
final class AdvertiserModel {

    /// The advertised local name. It is fixed because the end-to-end test asserts on it.
    static let localName = "BLESwift Explorer Sim"

    /// The Heart Rate Control Point (`2A39`). The host exposes it as write-only, so the UI can log
    /// writes.
    static let controlPoint = CharacteristicIdentifier(uuid: "2A39", service: HeartRateMeasurement.service)

    // MARK: - Published state

    var isAdvertising = false
    var bpm = 60
    var stateText = "unknown"
    var log: [LogEntry] = []

    // MARK: - Private state

    // Created lazily on the first `start()`, so that `BackendRegistry` is consulted *after*
    // `SimulatorLink.install()` has run. `PeripheralHost()` resolves its backend once, at
    // construction. The model keeps the host across `stop()` and `start()` cycles.
    private var host: PeripheralHost?
    private var didAddService = false
    private var isPublishing = false
    private var streamTasks: [Task<Void, Never>] = []
    private var startTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var bpmRising = true

    // MARK: - Start / stop

    /// Builds the host (first call only), publishes the Heart Rate service, and starts advertising
    /// and the one-second notification timer.
    func start() {
        guard !isAdvertising else { return }
        isAdvertising = true
        startTask = Task { [weak self] in await self?.startAdvertising() }
    }

    /// Stops advertising and cancels the timer and the stream consumers. The model keeps the host.
    func stop() {
        isAdvertising = false
        startTask?.cancel()
        startTask = nil
        tickTask?.cancel()
        tickTask = nil
        for task in streamTasks { task.cancel() }
        streamTasks = []
        guard let host else { return }
        Task { await host.stopAdvertising() }
        append("Stopped advertising")
    }

    private func startAdvertising() async {
        let host = existingOrNewHost()

        // Subscribe to the request streams *before* advertising. They do not replay.
        if streamTasks.isEmpty {
            streamTasks.append(Task { [weak self] in await self?.consumeStateEvents(host) })
            streamTasks.append(Task { [weak self] in await self?.consumeReadRequests(host) })
            streamTasks.append(Task { [weak self] in await self?.consumeWriteRequests(host) })
        }

        // The host's manager must reach `.poweredOn` before the app can publish its GATT database.
        // Otherwise `add(_:)` waits for a CoreBluetooth callback that never comes.
        for await state in await host.stateEvents() where state == .poweredOn { break }
        guard isAdvertising, !Task.isCancelled else { return }
        await publish(on: host)
    }

    /// Publishes the GATT database (once for each power cycle) and starts advertising.
    ///
    /// Two callers use this method: the opening `start()` and every later `.poweredOn`. If a
    /// simulator link drops, the provider loses its copy of the database and the advertisement. A
    /// CoreBluetooth power bounce has the same effect. So the reconnect must publish both again.
    /// Both callers observe the first `.poweredOn`, and the reentrancy guard prevents them from
    /// racing into a double `add(_:)`.
    private func publish(on host: PeripheralHost) async {
        guard isAdvertising, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        do {
            if !didAddService {
                try await host.add(Self.service)
                didAddService = true
            }
            try await host.startAdvertising(
                PeripheralAdvertisement(
                    localName: Self.localName,
                    serviceUUIDs: [HeartRateMeasurement.service]
                )
            )
            append("Advertising as \(Self.localName)")
            tickTask?.cancel()
            tickTask = Task { [weak self] in await self?.tick(host) }
        } catch {
            append("Advertise failed: \(error)")
            isAdvertising = false
        }
    }

    private func existingOrNewHost() -> PeripheralHost {
        if let host { return host }
        let host = PeripheralHost()
        self.host = host
        return host
    }

    /// The hosted GATT database: `2A37` dynamic (`[.read, .notify]`) and a `2A39` write sink.
    private static let service = GATTService(
        identifier: HeartRateMeasurement.service,
        characteristics: [
            GATTCharacteristic(
                identifier: HeartRateMeasurement.characteristic,
                properties: [.read, .notify],
                permissions: [.readable]
            ),
            GATTCharacteristic(
                identifier: AdvertiserModel.controlPoint,
                properties: [.write],
                permissions: [.writeable]
            )
        ]
    )

    // MARK: - Streams

    private func consumeStateEvents(_ host: PeripheralHost) async {
        for await state in await host.stateEvents() {
            stateText = String(describing: state)
            guard state == .poweredOn else {
                // Any other state means that the radio is gone. In the Simulator it can mean that
                // the provider session is gone, and the hosted database with it. The code drops the
                // latch so that the next `.poweredOn` adds the service again and does not assume it
                // is still there.
                didAddService = false
                continue
            }
            await publish(on: host)
        }
    }

    private func consumeReadRequests(_ host: PeripheralHost) async {
        for await request in await host.readRequests() {
            await host.respond(to: request, with: .success(measurementValue))
        }
    }

    private func consumeWriteRequests(_ host: PeripheralHost) async {
        for await request in await host.writeRequests() {
            for entry in request.entries {
                append("Write \(entry.characteristic.uuidString): \(entry.value.map { String(format: "%02X", $0) }.joined())")
            }
            await host.respond(to: request, with: .success(()))
        }
    }

    /// Cycles `bpm` 60 → 100 → 60, one beat each second, and pushes each value to subscribers.
    private func tick(_ host: PeripheralHost) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            advanceBPM()
            do {
                try await host.updateValue(measurementValue, for: HeartRateMeasurement.characteristic)
            } catch {
                append("updateValue failed: \(error)")
            }
        }
    }

    private func advanceBPM() {
        if bpmRising {
            bpm += 1
            if bpm >= 100 { bpmRising = false }
        } else {
            bpm -= 1
            if bpm <= 60 { bpmRising = true }
        }
    }

    /// A Heart Rate Measurement value: flags `0x00` (UInt8 BPM), then the BPM byte.
    private var measurementValue: Data {
        Data([0x00, UInt8(clamping: bpm)])
    }

    // MARK: - Log

    private func append(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

#endif
