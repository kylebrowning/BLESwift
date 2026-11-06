//
//  PeripheralHostEvent.swift
//  BLESwiftCore
//

import Foundation

/// A `Sendable` representation of a `CBPeripheralManagerDelegate` callback. It uses only types that
/// BLESwift owns. It is the `CBPeripheralManagerDelegate` counterpart of ``CentralEvent``. See
/// ``PeripheralManaging`` for the delivery contract.
public enum PeripheralHostEvent: Sendable {

    /// The state of the Bluetooth radio changed. Mirrors `peripheralManagerDidUpdateState(_:)`.
    case didUpdateState(CentralState)

    /// Advertising started, or it failed to start. Mirrors
    /// `peripheralManagerDidStartAdvertising(_:error:)`.
    case didStartAdvertising(error: NSError?)

    /// Adding a service to the local GATT database finished or failed. Mirrors
    /// `peripheralManager(_:didAdd:error:)`.
    case didAddService(ServiceIdentifier, error: NSError?)

    /// A remote central sent a read request. Mirrors `peripheralManager(_:didReceiveRead:)`. At the
    /// seam, the request's ``RequestToken`` holds the `CBATTRequest`.
    case didReceiveRead(ReadRequest)

    /// A remote central sent a batch of write requests. Mirrors
    /// `peripheralManager(_:didReceiveWrite:)`.
    case didReceiveWrite(WriteRequest)

    /// A remote central subscribed to a characteristic's notifications. Mirrors
    /// `peripheralManager(_:central:didSubscribeTo:)`.
    case didSubscribe(central: Subscriber, characteristic: CharacteristicIdentifier)

    /// A remote central unsubscribed from a characteristic's notifications. Mirrors
    /// `peripheralManager(_:central:didUnsubscribeFrom:)`.
    case didUnsubscribe(central: Subscriber, characteristic: CharacteristicIdentifier)

    /// The transmit queue drained after a full
    /// ``PeripheralManaging/updateValue(_:for:onSubscribed:)``. You can retry pending notification
    /// pushes. Mirrors `peripheralManagerIsReady(toUpdateSubscribers:)`.
    case readyToUpdateSubscribers

    /// CoreBluetooth restored preserved peripheral-role state after a background relaunch (iOS).
    /// Mirrors `peripheralManager(_:willRestoreState:)`. The proxy has already converted the state
    /// to the `Sendable` ``RestoredPeripheralState``.
    case willRestoreState(RestoredPeripheralState)
}
