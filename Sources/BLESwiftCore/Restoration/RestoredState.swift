//
//  RestoredState.swift
//  BLESwiftCore
//

// NOTE — unconditionally public (Orchestrator amendment A3.1, plans/03-core-split-and-
// testsupport.md): these three types were originally dual-declared (public on iOS, a
// `package` mirror elsewhere) to keep restoration out of the non-iOS public API surface,
// back when `CentralEvent` itself was `package`. Now that `CentralEvent` is public
// everywhere (T2) and its `willRestoreState(RestoredState)` case must carry a type at
// least as accessible as the enum, the dual-access split is no longer viable (a public
// enum case cannot carry a `package` payload type) — and, per A3.1, no longer desirable
// either: these are pure value types in a CB-free module, and the public-seam architecture
// (any `CentralManaging` conformance, including a replay/test backend on any platform, can
// legitimately construct a `RestoredState`) supersedes the original minimal-surface
// rationale. The BEHAVIORAL restoration surface — `RestorationConfiguration`,
// `Configuration.restoration`, `Central.restorationEvents()` (all in the `BLESwift` module)
// — stays iOS-gated as before; only these inert value types widen.

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
