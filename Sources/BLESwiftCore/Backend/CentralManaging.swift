//
//  CentralManaging.swift
//  BLESwiftCore
//

import Foundation

/// This is BLESwift's backend implementation seam. BLESwift ships two conformances —
/// CoreBluetooth (the `BLESwift` module) and scriptable fakes (`BLESwiftTestSupport`).
/// Conforming your own types is possible but unsupported: the semantic contract (event
/// ordering, queue confinement, delivery asynchrony) is documented here on a best-effort
/// basis and may gain requirements in any release.
///
/// A protocol seam over `CBCentralManager`, mirroring only the API surface BLESwift uses,
/// speaking exclusively in BLESwift-owned (never CoreBluetooth) types.
///
/// `CBCentralManager` cannot be instantiated or subclassed in tests (see
/// ``PeripheralRemote`` for the equivalent `CBPeripheral` constraint), so `Central` (in the
/// `BLESwift` module) is written entirely against this protocol instead of the concrete
/// CoreBluetooth type. `CBCentralManager` conforms retroactively (`BLESwift`'s
/// `CBCentralManager+CentralManaging.swift`); `BLESwiftTestSupport`'s `FakeCentral` conforms
/// for tests, standing in for hardware.
///
/// - Important: Every ``eventHandler`` delivery must happen **asynchronously**, on the
///   single serial `DispatchSerialQueue` the owning `Central` was constructed with — never
///   deliver inline from within a method call on this protocol.
///
/// - Note: ``radioState``/``bluetoothAuthorization`` are named to avoid colliding with
///   `CBCentralManager`'s/`CBManager`'s own identically-named `state`/`authorization`
///   properties — a same-name, different-type member cannot be added to those types via
///   retroactive extension (Swift treats it as an invalid override/redeclaration). This is
///   a seam-only rename; `Central`'s own public `state`/`authorization` API is unaffected.
public protocol CentralManaging: AnyObject {

    /// Receives every ``CentralEvent`` this backend produces. Set by `Central` at
    /// creation/adoption time; assigning `nil` detaches event delivery. See the delivery
    /// contract on the protocol's doc comment.
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
