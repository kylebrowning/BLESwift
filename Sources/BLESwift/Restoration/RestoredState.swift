//
//  RestoredState.swift
//  BLESwift
//

// NOTE — dual-access declarations: see the note in `RestorationConfiguration.swift`. Each
// type here is declared twice — public on iOS, an internal mirror elsewhere — so the
// restoration logic stays compiled (and testable under `swift test` on macOS) without
// restoration appearing in the non-iOS public API surface. **Keep the two in sync.**

#if os(iOS)
import CoreBluetooth
#endif

#if os(iOS)

/// The connection state a restored peripheral was in when CoreBluetooth handed it back,
/// mapped from `CBPeripheralState`. Determines how ``Central`` routes the peripheral —
/// see ``RestorationEvent``.
public enum RestoredPeripheralState: Sendable, Hashable {
    /// A connection attempt was in progress. `Central` issues a manual re-connect
    /// (CoreBluetooth never completes a restored-connecting attempt on its own).
    case connecting
    /// The peripheral was connected. `Central` adopts it as the live session.
    case connected
    /// The peripheral was disconnecting. Restoration fails with
    /// ``BLESwiftError/notConnected`` (untested upstream — see ``RestorationEvent``).
    case disconnecting
    /// The peripheral was disconnected. Restoration fails with
    /// ``BLESwiftError/notConnected`` (untested upstream — see ``RestorationEvent``).
    case disconnected
}

/// One peripheral CoreBluetooth preserved and handed back during state restoration.
public struct RestoredPeripheral: Sendable, Hashable {

    /// The restored peripheral's identifier.
    public let identifier: PeripheralIdentifier

    /// The connection state the peripheral was restored in.
    public let state: RestoredPeripheralState

    /// Creates a `RestoredPeripheral`.
    public init(identifier: PeripheralIdentifier, state: RestoredPeripheralState) {
        self.identifier = identifier
        self.state = state
    }
}

/// A `Sendable` snapshot of the scan options CoreBluetooth preserved
/// (`CBCentralManagerRestoredStateScanOptionsKey`), if a scan was in progress when the
/// app was terminated.
public struct RestoredScanOptions: Sendable, Hashable {

    /// Whether the restored scan allowed duplicate discoveries
    /// (`CBCentralManagerScanOptionAllowDuplicatesKey`).
    public let allowDuplicates: Bool

    /// The solicited service UUIDs of the restored scan
    /// (`CBCentralManagerScanOptionSolicitedServiceUUIDsKey`), if any.
    public let solicitedServices: [ServiceIdentifier]

    /// Creates a `RestoredScanOptions`.
    public init(allowDuplicates: Bool, solicitedServices: [ServiceIdentifier] = []) {
        self.allowDuplicates = allowDuplicates
        self.solicitedServices = solicitedServices
    }
}

/// Everything CoreBluetooth handed back in its `willRestoreState` delegate callback,
/// converted eagerly (in the delegate proxy — the only place raw `[String: Any]`
/// dictionaries are touched) into `Sendable` BLESwift value types.
///
/// Delivered as ``RestorationEvent/willRestore(_:)`` on ``Central/restorationEvents()``,
/// which buffers every restoration event until the first consumer arrives — so state
/// restored before your app finished wiring its consumers is never lost.
public struct RestoredState: Sendable, Hashable {

    /// The peripherals CoreBluetooth preserved (`CBCentralManagerRestoredStatePeripheralsKey`).
    /// In practice at most one (BLESwift enforces single-peripheral connection
    /// discipline).
    public let peripherals: [RestoredPeripheral]

    /// The services of the scan CoreBluetooth preserved
    /// (`CBCentralManagerRestoredStateScanServicesKey`) — empty if no scan was in
    /// progress. Note that `Central` does **not** automatically resume a restored scan:
    /// call ``Central/scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``
    /// yourself if the app should still be scanning.
    public let scanServices: [ServiceIdentifier]

    /// The options of the scan CoreBluetooth preserved, or `nil` if no scan was in
    /// progress. See ``scanServices``.
    public let scanOptions: RestoredScanOptions?

    /// Creates a `RestoredState`.
    public init(
        peripherals: [RestoredPeripheral],
        scanServices: [ServiceIdentifier] = [],
        scanOptions: RestoredScanOptions? = nil
    ) {
        self.peripherals = peripherals
        self.scanServices = scanServices
        self.scanOptions = scanOptions
    }
}

#else

/// Internal mirror of the iOS-only public `RestoredPeripheralState` — see the dual-access
/// note at the top of this file.
enum RestoredPeripheralState: Sendable, Hashable {
    case connecting
    case connected
    case disconnecting
    case disconnected
}

/// Internal mirror of the iOS-only public `RestoredPeripheral` — see the dual-access note
/// at the top of this file.
struct RestoredPeripheral: Sendable, Hashable {
    let identifier: PeripheralIdentifier
    let state: RestoredPeripheralState

    init(identifier: PeripheralIdentifier, state: RestoredPeripheralState) {
        self.identifier = identifier
        self.state = state
    }
}

/// Internal mirror of the iOS-only public `RestoredScanOptions` — see the dual-access note
/// at the top of this file.
struct RestoredScanOptions: Sendable, Hashable {
    let allowDuplicates: Bool
    let solicitedServices: [ServiceIdentifier]

    init(allowDuplicates: Bool, solicitedServices: [ServiceIdentifier] = []) {
        self.allowDuplicates = allowDuplicates
        self.solicitedServices = solicitedServices
    }
}

/// Internal mirror of the iOS-only public `RestoredState` — see the dual-access note at
/// the top of this file.
struct RestoredState: Sendable, Hashable {
    let peripherals: [RestoredPeripheral]
    let scanServices: [ServiceIdentifier]
    let scanOptions: RestoredScanOptions?

    init(
        peripherals: [RestoredPeripheral],
        scanServices: [ServiceIdentifier] = [],
        scanOptions: RestoredScanOptions? = nil
    ) {
        self.peripherals = peripherals
        self.scanServices = scanServices
        self.scanOptions = scanOptions
    }
}

#endif

#if os(iOS)

extension RestoredState {

    /// Eagerly converts CoreBluetooth's raw `willRestoreState` dictionary into `Sendable`
    /// BLESwift value types. Called **only** by `CentralDelegateProxy` (the single place BLESwift
    /// touches a raw `[String: Any]` — same discipline as `AdvertisementData`'s
    /// dictionary-conversion initializer).
    init(restorationDictionary dictionary: [String: Any]) {
        let cbPeripherals = dictionary[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let peripherals = cbPeripherals.map { peripheral in
            RestoredPeripheral(
                identifier: PeripheralIdentifier(uuid: peripheral.identifier, name: peripheral.name),
                state: RestoredPeripheralState(peripheral.state)
            )
        }

        let scanServices = (dictionary[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] ?? [])
            .map(ServiceIdentifier.init(cbuuid:))

        let scanOptions: RestoredScanOptions?
        if let rawOptions = dictionary[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any] {
            scanOptions = RestoredScanOptions(
                allowDuplicates: (rawOptions[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool) ?? false,
                solicitedServices: (rawOptions[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
                    .map(ServiceIdentifier.init(cbuuid:))
            )
        } else {
            scanOptions = nil
        }

        self.init(peripherals: peripherals, scanServices: scanServices, scanOptions: scanOptions)
    }
}

extension RestoredPeripheralState {

    /// Maps `CBPeripheralState` into BLESwift's own vocabulary (no CoreBluetooth types in the
    /// public API). `@unknown` future states map to ``disconnected`` — the safe reading
    /// (restoration of a state BLESwift doesn't understand is treated as nothing to restore).
    init(_ state: CBPeripheralState) {
        switch state {
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .disconnecting:
            self = .disconnecting
        case .disconnected:
            self = .disconnected
        @unknown default:
            self = .disconnected
        }
    }
}

#endif
