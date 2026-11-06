//
//  RestoredState.swift
//  BLESwiftCore
//

/// One peripheral that CoreBluetooth preserved and handed back during state restoration.
public struct RestoredPeripheral: Sendable, Hashable {

    /// The restored peripheral's identifier.
    public let identifier: PeripheralIdentifier

    /// The connection state in which the peripheral was restored. `Central` routes the peripheral
    /// by it. See `RestorationEvent` (in the `BLESwift` module).
    public let state: PeripheralConnectionState

    /// Creates a `RestoredPeripheral`.
    public init(identifier: PeripheralIdentifier, state: PeripheralConnectionState) {
        self.identifier = identifier
        self.state = state
    }
}

/// A `Sendable` snapshot of the scan options that CoreBluetooth preserved
/// (`CBCentralManagerRestoredStateScanOptionsKey`). It exists only if a scan was in progress when
/// the app was terminated.
public struct RestoredScanOptions: Sendable, Hashable {

    /// Whether the restored scan allowed duplicate discoveries
    /// (`CBCentralManagerScanOptionAllowDuplicatesKey`).
    public let allowDuplicates: Bool

    /// The restored scan's solicited service UUIDs
    /// (`CBCentralManagerScanOptionSolicitedServiceUUIDsKey`), if any.
    public let solicitedServices: [ServiceIdentifier]

    /// Creates a `RestoredScanOptions`.
    public init(allowDuplicates: Bool, solicitedServices: [ServiceIdentifier] = []) {
        self.allowDuplicates = allowDuplicates
        self.solicitedServices = solicitedServices
    }
}

/// Everything that CoreBluetooth handed back in its `willRestoreState` delegate callback, converted
/// immediately to `Sendable` BLESwift value types. `Central.restorationEvents()` delivers it as
/// `RestorationEvent.willRestore(_:)` and buffers every restoration event until the first consumer
/// arrives.
public struct RestoredState: Sendable, Hashable {

    /// The peripherals that CoreBluetooth preserved
    /// (`CBCentralManagerRestoredStatePeripheralsKey`).
    public let peripherals: [RestoredPeripheral]

    /// The services of the scan that CoreBluetooth preserved
    /// (`CBCentralManagerRestoredStateScanServicesKey`). The array is empty if no scan was in
    /// progress. `Central` does **not** resume a restored scan automatically.
    public let scanServices: [ServiceIdentifier]

    /// The options of the scan that CoreBluetooth preserved, or `nil` if no scan was in progress.
    /// See ``scanServices``.
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
