//
//  RestoredState.swift
//  BLESwiftCore
//

/// One peripheral CoreBluetooth preserved and handed back during state restoration.
public struct RestoredPeripheral: Sendable, Hashable {

    /// The restored peripheral's identifier.
    public let identifier: PeripheralIdentifier

    /// The connection state the peripheral was restored in. Determines how `Central`
    /// routes the peripheral — see `RestorationEvent` (in the `BLESwift` module).
    public let state: PeripheralConnectionState

    /// Creates a `RestoredPeripheral`.
    public init(identifier: PeripheralIdentifier, state: PeripheralConnectionState) {
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
/// converted eagerly into `Sendable` BLESwift value types. Delivered as
/// `RestorationEvent.willRestore(_:)` on `Central.restorationEvents()`, which buffers
/// every restoration event until the first consumer arrives.
public struct RestoredState: Sendable, Hashable {

    /// The peripherals CoreBluetooth preserved (`CBCentralManagerRestoredStatePeripheralsKey`).
    public let peripherals: [RestoredPeripheral]

    /// The services of the scan CoreBluetooth preserved
    /// (`CBCentralManagerRestoredStateScanServicesKey`) — empty if no scan was in
    /// progress. Note that `Central` does **not** automatically resume a restored scan.
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
