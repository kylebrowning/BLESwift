//
//  PeripheralManaging.swift
//  BLESwiftCore
//

import Foundation

/// This is BLESwift's peripheral-role backend implementation seam — the `CBPeripheralManager`
/// counterpart to ``CentralManaging``. BLESwift ships two conformances: CoreBluetooth (the
/// `BLESwift` module) and a scriptable fake (`BLESwiftTestSupport`). Conforming your own type
/// is possible but unsupported: the semantic contract (event ordering, queue confinement,
/// delivery asynchrony) is documented here on a best-effort basis and may gain requirements
/// in any release.
///
/// A protocol seam over `CBPeripheralManager`, mirroring only the API surface BLESwift's
/// peripheral role uses, speaking exclusively in BLESwift-owned (never CoreBluetooth) value
/// types. `CBPeripheralManager` cannot be instantiated or scripted in tests, so
/// `PeripheralHost` (in the `BLESwift` module) is written entirely against this protocol;
/// `CBPeripheralManager` conforms retroactively, and `FakePeripheralManager` conforms for
/// tests.
///
/// - Important: Every ``eventHandler`` delivery must happen **asynchronously**, on the
///   single serial `DispatchSerialQueue` the owning `PeripheralHost` was constructed with —
///   never deliver inline from within a method call on this protocol.
///
/// - Note: ``radioState``/``bluetoothAuthorization`` are named to avoid colliding with
///   `CBPeripheralManager`'s/`CBManager`'s own identically-named `state`/`authorization`
///   members (a same-name, different-type member cannot be added via retroactive extension),
///   exactly as on ``CentralManaging``.
public protocol PeripheralManaging: AnyObject {

    /// Receives every `PeripheralHostEvent` this backend produces. Set by `PeripheralHost`
    /// at creation time; assigning `nil` detaches event delivery. See the delivery contract
    /// on the protocol's doc comment.
    var eventHandler: ((PeripheralHostEvent) -> Void)? { get set }

    /// The current state of the Bluetooth radio. Mirrors `CBPeripheralManager.state`
    /// (reusing ``CentralState``, which is the shared radio-state type for both manager
    /// roles).
    var radioState: CentralState { get }

    /// Whether the peripheral is currently advertising. Mirrors
    /// `CBPeripheralManager.isAdvertising`.
    var isAdvertising: Bool { get }

    /// The app's Bluetooth authorization status. Mirrors the `CBManager.authorization`
    /// class property.
    static var bluetoothAuthorization: BluetoothAuthorization { get }

    /// Begins advertising. Mirrors `CBPeripheralManager.startAdvertising(_:)`; completion
    /// arrives as `PeripheralHostEvent/didStartAdvertising(error:)`.
    func startAdvertising(_ advertisement: PeripheralAdvertisement)

    /// Stops advertising. Mirrors `CBPeripheralManager.stopAdvertising()`.
    func stopAdvertising()

    /// Publishes a service (and its characteristics) into the local GATT database. Mirrors
    /// `CBPeripheralManager.add(_:)`, which takes a `CBMutableService` — the conformance
    /// compiles ``GATTService`` into one at the CoreBluetooth seam. Completion arrives as
    /// `PeripheralHostEvent/didAddService(_:error:)`.
    func add(_ service: GATTService)

    /// Removes every published service from the local GATT database. Mirrors
    /// `CBPeripheralManager.removeAllServices()` (named distinctly to avoid an
    /// identical-signature clash with that native method in the retroactive conformance).
    func removeAllHostedServices()

    /// Answers a read or write request previously surfaced as ``ReadRequest``/
    /// ``WriteRequest``, identified by its `token`. Mirrors
    /// `CBPeripheralManager.respond(to:withResult:)`: `error == nil` responds success (with
    /// `value` as the read result, ignored for writes); a non-`nil` `error` responds with
    /// that ATT failure code. A no-op if `token` is unknown (already answered, or minted by
    /// a different manager).
    func respond(to token: RequestToken, value: Data?, error: ATTError?)

    /// Pushes `value` as a notification/indication for `characteristic` to `centrals`
    /// (or every subscribed central when `nil`). Mirrors
    /// `CBPeripheralManager.updateValue(_:for:onSubscribedCentrals:)`, including its
    /// back-pressure contract: returns `false` when the underlying transmit queue is full,
    /// in which case the caller must wait for
    /// `PeripheralHostEvent/readyToUpdateSubscribers` and retry.
    ///
    /// - Returns: `true` if the update was queued for transmission, `false` if the transmit
    ///   queue was full.
    func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool
}
