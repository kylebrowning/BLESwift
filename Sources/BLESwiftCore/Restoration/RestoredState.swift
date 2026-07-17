//
//  RestoredState.swift
//  BLESwiftCore
//

// NOTE — dual-access declarations: see the note in `RestorationConfiguration.swift`
// (`BLESwift` module). Each type here is declared twice — public on iOS, a `package`
// mirror elsewhere — so the restoration logic stays compiled (and testable under
// `swift test` on macOS) without restoration appearing in the non-iOS public API
// surface. `package`, not `internal`, on non-iOS specifically so `BLESwift`,
// `BLESwiftTestSupport`, and their tests (separate modules within this package) can
// still reach these types off-iOS. **Keep the two declarations in sync.**

#if os(iOS)

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
/// converted eagerly (in the `BLESwift` module's delegate proxy — the only place raw
/// `[String: Any]` dictionaries are touched) into `Sendable` BLESwift value types.
///
/// Delivered as `RestorationEvent.willRestore(_:)` on `Central.restorationEvents()`,
/// which buffers every restoration event until the first consumer arrives — so state
/// restored before your app finished wiring its consumers is never lost.
public struct RestoredState: Sendable, Hashable {

    /// The peripherals CoreBluetooth preserved (`CBCentralManagerRestoredStatePeripheralsKey`).
    /// In practice at most one (BLESwift enforces single-peripheral connection
    /// discipline).
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

#else

/// `package` mirror of the iOS-only public `RestoredPeripheral` — see the dual-access
/// note at the top of this file.
package struct RestoredPeripheral: Sendable, Hashable {
    package let identifier: PeripheralIdentifier
    package let state: PeripheralConnectionState

    package init(identifier: PeripheralIdentifier, state: PeripheralConnectionState) {
        self.identifier = identifier
        self.state = state
    }
}

/// `package` mirror of the iOS-only public `RestoredScanOptions` — see the dual-access
/// note at the top of this file.
package struct RestoredScanOptions: Sendable, Hashable {
    package let allowDuplicates: Bool
    package let solicitedServices: [ServiceIdentifier]

    package init(allowDuplicates: Bool, solicitedServices: [ServiceIdentifier] = []) {
        self.allowDuplicates = allowDuplicates
        self.solicitedServices = solicitedServices
    }
}

/// `package` mirror of the iOS-only public `RestoredState` — see the dual-access note at
/// the top of this file.
package struct RestoredState: Sendable, Hashable {
    package let peripherals: [RestoredPeripheral]
    package let scanServices: [ServiceIdentifier]
    package let scanOptions: RestoredScanOptions?

    package init(
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
