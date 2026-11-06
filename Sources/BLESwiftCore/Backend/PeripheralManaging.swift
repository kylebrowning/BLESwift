//
//  PeripheralManaging.swift
//  BLESwiftCore
//

import Foundation

/// A protocol seam over `CBPeripheralManager`. It is the peripheral-role counterpart of
/// ``CentralManaging``. The conformances are CoreBluetooth (`BLESwift`) and a scriptable fake
/// (`BLESwiftTestSupport`). You can conform your own type, but this is not supported.
///
/// - Important: Every ``eventHandler`` delivery must happen asynchronously, on the serial queue
///   that the owning `PeripheralHost` was created with. Never deliver inline.
/// - Note: ``radioState`` and ``bluetoothAuthorization`` are renamed to avoid a clash with the
///   same-named members of `CBPeripheralManager` and `CBManager`, as on ``CentralManaging``.
public protocol PeripheralManaging: AnyObject {

    /// Receives every `PeripheralHostEvent` that this backend produces. `nil` stops the delivery.
    var eventHandler: ((PeripheralHostEvent) -> Void)? { get set }

    /// The current state of the Bluetooth radio. Mirrors `CBPeripheralManager.state`.
    var radioState: CentralState { get }

    /// Whether the peripheral is advertising. Mirrors `CBPeripheralManager.isAdvertising`.
    var isAdvertising: Bool { get }

    /// The Bluetooth authorization status of the app. Mirrors the `CBManager.authorization` class
    /// property.
    static var bluetoothAuthorization: BluetoothAuthorization { get }

    /// Starts advertising. Mirrors `CBPeripheralManager.startAdvertising(_:)`. The completion
    /// arrives as `PeripheralHostEvent/didStartAdvertising(error:)`.
    func startAdvertising(_ advertisement: PeripheralAdvertisement)

    /// Stops advertising. Mirrors `CBPeripheralManager.stopAdvertising()`.
    func stopAdvertising()

    /// Publishes a service (and its characteristics) in the local GATT database. Mirrors
    /// `CBPeripheralManager.add(_:)`. The completion arrives as
    /// `PeripheralHostEvent/didAddService(_:error:)`.
    func add(_ service: GATTService)

    /// Removes each published service from the local GATT database. Mirrors
    /// `CBPeripheralManager.removeAllServices()`. It has a different name so that it does not clash
    /// with that native method, which has an identical signature, in the retroactive conformance.
    func removeAllHostedServices()

    /// Answers a request that the backend delivered earlier as a ``ReadRequest`` or
    /// ``WriteRequest``. The `token` identifies the request. Mirrors
    /// `CBPeripheralManager.respond(to:withResult:)`. If `token` is unknown, this function does
    /// nothing.
    func respond(to token: RequestToken, value: Data?, error: ATTError?)

    /// Pushes `value` as a notification or indication for `characteristic` to `centrals`. If
    /// `centrals` is `nil`, it pushes to every subscribed central. Mirrors
    /// `CBPeripheralManager.updateValue(_:for:onSubscribedCentrals:)`.
    ///
    /// - Returns: `true` if the value is queued for transmission. `false` if the transmit queue is
    ///   full. In that case, wait for `PeripheralHostEvent/readyToUpdateSubscribers` and retry.
    func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool
}
