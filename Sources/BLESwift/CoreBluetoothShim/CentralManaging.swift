//
//  CentralManaging.swift
//  BLESwift
//

import CoreBluetooth

/// A protocol seam over `CBCentralManager`, mirroring only the API surface BLESwift uses.
///
/// `CBCentralManager` cannot be instantiated or subclassed in tests (see
/// ``PeripheralRemote`` for the equivalent `CBPeripheral` constraint), so the actor core
/// (`Central`, added in a later phase) is written entirely against this protocol instead
/// of the concrete CoreBluetooth type. `CBCentralManager` conforms retroactively (see
/// `CBCentralManager+CentralManaging.swift`); a scriptable `FakeCentral` conforms for
/// tests, standing in for hardware.
protocol CentralManaging: AnyObject {

    /// The current state of the Bluetooth radio. Mirrors `CBCentralManager.state`.
    var state: CBManagerState { get }

    /// The app's Bluetooth authorization status. Mirrors the `CBManager.authorization`
    /// class property (the *instance* property of the same name is deprecated).
    static var authorization: CBManagerAuthorization { get }

    /// Begins scanning for peripherals. Mirrors
    /// `CBCentralManager.scanForPeripherals(withServices:options:)`.
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?)

    /// Stops any active scan. Mirrors `CBCentralManager.stopScan()`.
    func stopScan()

    /// Initiates a connection to `peripheral`. Mirrors
    /// `CBCentralManager.connect(_:options:)`.
    ///
    /// `peripheral` is typed as an existential (rather than an associated type) so
    /// `Central` can hold this protocol itself as `any CentralManaging` — an
    /// associated-type requirement would make these calls uncompilable on the
    /// existential. Conformances that mirror concrete CoreBluetooth types (e.g.
    /// `CBCentralManager`, whose real methods take `CBPeripheral`) downcast internally,
    /// silently ignoring `peripheral` values from a mismatched shim family (e.g. a
    /// `FakePeripheral` passed to `CBCentralManager`) rather than trapping — mixing shim
    /// families is a programmer error, not a runtime condition to crash on.
    func connect(_ peripheral: any PeripheralRemote, options: [String: Any]?)

    /// Cancels an active or pending connection to `peripheral`. Mirrors
    /// `CBCentralManager.cancelPeripheralConnection(_:)`. See ``connect(_:options:)`` for
    /// why `peripheral` is an existential and how mismatched shim families are handled.
    func cancelPeripheralConnection(_ peripheral: any PeripheralRemote)

    /// Looks up previously-seen peripherals by identifier. Mirrors
    /// `CBCentralManager.retrievePeripherals(withIdentifiers:)`.
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote]
}
