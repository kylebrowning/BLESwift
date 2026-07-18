//
//  PeripheralHostEvent.swift
//  BLESwiftCore
//

import Foundation

/// This is part of BLESwift's peripheral-role backend implementation seam (see
/// ``PeripheralManaging``). The `CBPeripheralManagerDelegate` counterpart to
/// ``CentralEvent``.
///
/// A `Sendable` representation of a `CBPeripheralManagerDelegate` callback, speaking
/// exclusively in BLESwift-owned (never CoreBluetooth) value types. The delegate proxy that
/// bridges real CoreBluetooth callbacks into these events lives in the `BLESwift` module.
/// Error payloads are typed `NSError?` (unconditionally `Sendable`), bridged with
/// `as NSError?` where emitted.
public enum PeripheralHostEvent: Sendable {

    /// The Bluetooth radio's state changed. Mirrors
    /// `peripheralManagerDidUpdateState(_:)`.
    case didUpdateState(CentralState)

    /// Advertising started (or failed to start). Mirrors
    /// `peripheralManagerDidStartAdvertising(_:error:)`.
    case didStartAdvertising(error: NSError?)

    /// A service finished being added to the local GATT database (or failed). Mirrors
    /// `peripheralManager(_:didAdd:error:)`.
    case didAddService(ServiceIdentifier, error: NSError?)

    /// A remote central issued a read request. Mirrors
    /// `peripheralManager(_:didReceiveRead:)`, with the `CBATTRequest` captured behind the
    /// request's ``RequestToken`` at the seam.
    case didReceiveRead(ReadRequest)

    /// A remote central issued a batch of write requests. Mirrors
    /// `peripheralManager(_:didReceiveWrite:)`.
    case didReceiveWrite(WriteRequest)

    /// A remote central subscribed to a characteristic's notifications. Mirrors
    /// `peripheralManager(_:central:didSubscribeTo:)`.
    case didSubscribe(central: Subscriber, characteristic: CharacteristicIdentifier)

    /// A remote central unsubscribed from a characteristic's notifications. Mirrors
    /// `peripheralManager(_:central:didUnsubscribeFrom:)`.
    case didUnsubscribe(central: Subscriber, characteristic: CharacteristicIdentifier)

    /// The transmit queue drained after a full ``PeripheralManaging/updateValue(_:for:onSubscribed:)``
    /// — pending notification pushes may be retried. Mirrors
    /// `peripheralManagerIsReady(toUpdateSubscribers:)`.
    case readyToUpdateSubscribers

    /// CoreBluetooth restored preserved peripheral-role state after a background relaunch
    /// (iOS). Mirrors `peripheralManager(_:willRestoreState:)`, converted eagerly to the
    /// `Sendable` ``RestoredPeripheralState`` by the proxy (buffered behind a `Mutex` and
    /// forwarded just before the first `didUpdateState`, same timing hazard as the
    /// central-side `willRestoreState`).
    ///
    /// Compiled on every platform so `PeripheralHost`'s restoration routing stays testable
    /// under `swift test` on macOS; only the iOS proxy produces it from a real callback.
    case willRestoreState(RestoredPeripheralState)
}
