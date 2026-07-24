//
//  PeripheralManaging.swift
//  BLESwiftCore
//

import Foundation

/// A protocol seam over `CBPeripheralManager` — the peripheral-role counterpart to
/// ``CentralManaging``. Conformances: CoreBluetooth (`BLESwift`) and a scriptable fake
/// (`BLESwiftTestSupport`); conforming your own type is possible but unsupported.
///
/// - Important: Every ``eventHandler`` delivery must happen asynchronously, on the serial
///   queue the owning `PeripheralHost` was constructed with — never deliver inline.
/// - Note: ``radioState``/``bluetoothAuthorization`` are renamed to avoid clashing with
///   `CBPeripheralManager`/`CBManager`'s identically-named members, exactly as on
///   ``CentralManaging``.
public protocol PeripheralManaging: AnyObject {

    /// Receives every `PeripheralHostEvent` this backend produces; `nil` detaches delivery.
    var eventHandler: ((PeripheralHostEvent) -> Void)? { get set }

    /// The current state of the Bluetooth radio. Mirrors `CBPeripheralManager.state`.
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
    /// `CBPeripheralManager.add(_:)`. Completion arrives as
    /// `PeripheralHostEvent/didAddService(_:error:)`.
    func add(_ service: GATTService)

    /// Removes every published service from the local GATT database. Mirrors
    /// `CBPeripheralManager.removeAllServices()` (named distinctly to avoid an
    /// identical-signature clash with that native method in the retroactive conformance).
    func removeAllHostedServices()

    /// Answers a read or write request previously surfaced as ``ReadRequest``/
    /// ``WriteRequest``, identified by its `token`. Mirrors
    /// `CBPeripheralManager.respond(to:withResult:)`. A no-op if `token` is unknown.
    func respond(to token: RequestToken, value: Data?, error: ATTError?)

    /// Pushes `value` as a notification/indication for `characteristic` to `centrals`
    /// (or every subscribed central when `nil`). Mirrors
    /// `CBPeripheralManager.updateValue(_:for:onSubscribedCentrals:)`.
    ///
    /// - Returns: `true` if queued for transmission, `false` if the transmit queue was
    ///   full — wait for `PeripheralHostEvent/readyToUpdateSubscribers` and retry.
    func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool
}
