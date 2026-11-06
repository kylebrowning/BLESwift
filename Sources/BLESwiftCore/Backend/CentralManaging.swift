//
//  CentralManaging.swift
//  BLESwiftCore
//

import Foundation

/// A protocol seam over `CBCentralManager`. It uses only types that BLESwift owns. The conformances
/// are CoreBluetooth (`BLESwift`) and scriptable fakes (`BLESwiftTestSupport`). You can conform
/// your own type, but this is not supported.
///
/// - Important: Every ``eventHandler`` delivery must happen asynchronously, on the serial queue
///   that the owning `Central` was created with. Never deliver inline.
/// - Note: ``radioState`` and ``bluetoothAuthorization`` are renamed to avoid a clash with the
///   same-named members of `CBCentralManager` and `CBManager`.
public protocol CentralManaging: AnyObject {

    /// Receives every ``CentralEvent`` that this backend produces. `nil` stops the delivery.
    var eventHandler: ((CentralEvent) -> Void)? { get set }

    /// The current state of the Bluetooth radio. Mirrors `CBCentralManager.state`.
    var radioState: CentralState { get }

    /// The Bluetooth authorization status of the app. Mirrors the `CBManager.authorization` class
    /// property. The *instance* property with the same name is deprecated.
    static var bluetoothAuthorization: BluetoothAuthorization { get }

    /// Starts a scan for peripherals. Mirrors
    /// `CBCentralManager.scanForPeripherals(withServices:options:)`.
    func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions)

    /// Stops each active scan. Mirrors `CBCentralManager.stopScan()`.
    func stopScan()

    /// Starts a connection to `peripheral`. Mirrors `CBCentralManager.connect(_:options:)`.
    /// `requiresANCS` maps to `CBConnectPeripheralOptionRequiresANCS`. It applies on iOS only, and
    /// conformances ignore it on other platforms.
    ///
    /// `peripheral` is an existential and not an associated type, so `Central` can hold this
    /// protocol as `any CentralManaging`. Conformances downcast internally. A `peripheral` from a
    /// mismatched shim family is silently ignored and does not trap.
    func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool)

    /// Cancels an active or pending connection to `peripheral`. Mirrors
    /// `CBCentralManager.cancelPeripheralConnection(_:)`. For mismatched shim families, see
    /// ``connect(_:options:)``.
    func cancelPeripheralConnection(_ peripheral: any PeripheralRemote)

    /// Looks up peripherals that the system saw before, by identifier. Mirrors
    /// `CBCentralManager.retrievePeripherals(withIdentifiers:)`.
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote]

    /// Looks up peripherals that are connected to the system (by any app) and that have at least
    /// one of the given services. Mirrors
    /// `CBCentralManager.retrieveConnectedPeripherals(withServices:)`.
    func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote]

    /// Registers for system connection events that match `services` or `peripherals` (any of them).
    /// If both are `nil`, nothing matches, as in CoreBluetooth. Mirrors
    /// `CBCentralManager.registerForConnectionEvents(options:)`. On macOS, the underlying API does
    /// not exist and this function does nothing.
    func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?)

    /// Cancels an earlier ``registerForConnectionEvents(services:peripherals:)``. Mirrors
    /// `CBCentralManager.registerForConnectionEvents(options:)` with `nil` options. On macOS, this
    /// function does nothing.
    func unregisterForConnectionEvents()
}

extension CentralManaging {

    /// The same as ``connect(_:options:requiresANCS:)`` with `requiresANCS: false`. Existing
    /// two-argument call sites keep working.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?) {
        connect(peripheral, options: options, requiresANCS: false)
    }
}
