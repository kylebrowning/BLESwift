//
//  CentralManaging.swift
//  BLESwiftCore
//

import Foundation

/// A protocol seam over `CBCentralManager`, mirroring only the API surface BLESwift uses,
/// speaking exclusively in BLESwift-owned (never CoreBluetooth) types.
///
/// `CBCentralManager` cannot be instantiated or subclassed in tests (see
/// ``PeripheralRemote`` for the equivalent `CBPeripheral` constraint), so `Central` (in the
/// `BLESwift` module) is written entirely against this protocol instead of the concrete
/// CoreBluetooth type. `CBCentralManager` conforms retroactively (`BLESwift`'s
/// `CBCentralManager+CentralManaging.swift`); a scriptable fake conforms for tests,
/// standing in for hardware.
///
/// `package`, not `public`, this phase: this is BLESwift's backend implementation seam,
/// not yet part of the supported public API (publicized in a later phase alongside a real
/// event route).
///
/// - Note: ``radioState``/``bluetoothAuthorization`` are named to avoid colliding with
///   `CBCentralManager`'s/`CBManager`'s own identically-named `state`/`authorization`
///   properties — a same-name, different-type member cannot be added to those types via
///   retroactive extension (Swift treats it as an invalid override/redeclaration). This is
///   a seam-only rename; `Central`'s own public `state`/`authorization` API is unaffected.
package protocol CentralManaging: AnyObject {

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

    /// Initiates a connection to `peripheral`. Mirrors
    /// `CBCentralManager.connect(_:options:)`.
    ///
    /// `peripheral` is typed as an existential (rather than an associated type) so
    /// `Central` can hold this protocol itself as `any CentralManaging` — an
    /// associated-type requirement would make these calls uncompilable on the
    /// existential. Conformances that mirror concrete CoreBluetooth types (e.g.
    /// `CBCentralManager`, whose real methods take `CBPeripheral`) downcast internally,
    /// silently ignoring `peripheral` values from a mismatched shim family (e.g. a
    /// fake peripheral passed to `CBCentralManager`) rather than trapping — mixing shim
    /// families is a programmer error, not a runtime condition to crash on.
    func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?)

    /// Cancels an active or pending connection to `peripheral`. Mirrors
    /// `CBCentralManager.cancelPeripheralConnection(_:)`. See ``connect(_:options:)`` for
    /// why `peripheral` is an existential and how mismatched shim families are handled.
    func cancelPeripheralConnection(_ peripheral: any PeripheralRemote)

    /// Looks up previously-seen peripherals by identifier. Mirrors
    /// `CBCentralManager.retrievePeripherals(withIdentifiers:)`.
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote]
}
