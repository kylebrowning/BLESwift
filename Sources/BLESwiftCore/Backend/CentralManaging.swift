//
//  CentralManaging.swift
//  BLESwiftCore
//

import Foundation

/// A protocol seam over `CBCentralManager`, speaking exclusively in BLESwift-owned types.
/// Conformances: CoreBluetooth (`BLESwift`) and scriptable fakes (`BLESwiftTestSupport`);
/// conforming your own type is possible but unsupported.
///
/// - Important: Every ``eventHandler`` delivery must happen asynchronously, on the serial
///   queue the owning `Central` was constructed with — never deliver inline.
/// - Note: ``radioState``/``bluetoothAuthorization`` are renamed to avoid clashing with
///   `CBCentralManager`/`CBManager`'s identically-named members.
public protocol CentralManaging: AnyObject {

    /// Receives every ``CentralEvent`` this backend produces; `nil` detaches delivery.
    var eventHandler: ((CentralEvent) -> Void)? { get set }

    /// The current state of the Bluetooth radio. Mirrors `CBCentralManager.state`.
    var radioState: CentralState { get }

    /// The app's Bluetooth authorization status. Mirrors the `CBManager.authorization`
    /// class property (the *instance* property of the same name is deprecated).
    static var bluetoothAuthorization: BluetoothAuthorization { get }

    /// Begins scanning for peripherals. Mirrors
    /// `CBCentralManager.scanForPeripherals(withServices:options:)`.
    func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions)

    /// Stops any active scan. Mirrors `CBCentralManager.stopScan()`.
    func stopScan()

    /// Initiates a connection to `peripheral`. Mirrors `CBCentralManager.connect(_:options:)`,
    /// with `requiresANCS` mapping to `CBConnectPeripheralOptionRequiresANCS` (applied on
    /// iOS only; conformances ignore it elsewhere).
    ///
    /// `peripheral` is an existential (not an associated type) so `Central` can hold this
    /// protocol as `any CentralManaging`. Conformances downcast internally; `peripheral`
    /// values from a mismatched shim family are silently ignored rather than trapped.
    func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool)

    /// Cancels an active or pending connection to `peripheral`. Mirrors
    /// `CBCentralManager.cancelPeripheralConnection(_:)`. See ``connect(_:options:)`` for
    /// how mismatched shim families are handled.
    func cancelPeripheralConnection(_ peripheral: any PeripheralRemote)

    /// Looks up previously-seen peripherals by identifier. Mirrors
    /// `CBCentralManager.retrievePeripherals(withIdentifiers:)`.
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote]

    /// Looks up peripherals currently connected to the system (by any app) that expose at
    /// least one of the given services. Mirrors
    /// `CBCentralManager.retrieveConnectedPeripherals(withServices:)`.
    func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote]

    /// Registers for system connection events matching `services`/`peripherals` (any-of;
    /// both `nil` matches nothing, per CoreBluetooth). Mirrors
    /// `CBCentralManager.registerForConnectionEvents(options:)`. A no-op on macOS, where
    /// the underlying API does not exist.
    func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?)

    /// Cancels a prior ``registerForConnectionEvents(services:peripherals:)``. Mirrors
    /// `CBCentralManager.registerForConnectionEvents(options:)` with `nil` options. A
    /// no-op on macOS.
    func unregisterForConnectionEvents()
}

extension CentralManaging {

    /// ``connect(_:options:requiresANCS:)`` with `requiresANCS: false` — kept so existing
    /// two-argument call sites read unchanged.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?) {
        connect(peripheral, options: options, requiresANCS: false)
    }
}
