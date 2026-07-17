//
//  PeripheralEvent.swift
//  BLESwiftCore
//

import Foundation

/// This is part of BLESwift's backend implementation seam (see ``PeripheralRemote``).
/// Conforming your own backend is possible but unsupported: the semantic contract (event
/// ordering, queue confinement, delivery asynchrony) is documented on ``PeripheralRemote``
/// on a best-effort basis and may gain requirements in any release.
///
/// A `Sendable` representation of a `CBPeripheralDelegate` callback, speaking exclusively
/// in BLESwift-owned (never CoreBluetooth) types.
///
/// See ``CentralEvent`` for why errors are typed `NSError?` rather than `any Error`.
public enum PeripheralEvent: Sendable {

    /// Service discovery completed (successfully or not). Mirrors
    /// `peripheral(_:didDiscoverServices:)`.
    case didDiscoverServices(error: NSError?)

    /// Characteristic discovery for `service` completed (successfully or not). Mirrors
    /// `peripheral(_:didDiscoverCharacteristicsFor:error:)`.
    case didDiscoverCharacteristics(service: ServiceIdentifier, error: NSError?)

    /// A write to `characteristic` completed (successfully or not). Mirrors
    /// `peripheral(_:didWriteValueFor:error:)`.
    case didWriteValue(characteristic: CharacteristicIdentifier, error: NSError?)

    /// `characteristic`'s value was read or a notification was received. Mirrors
    /// `peripheral(_:didUpdateValueFor:error:)`.
    case didUpdateValue(characteristic: CharacteristicIdentifier, value: Data?, error: NSError?)

    /// The notification (listening) state of `characteristic` changed. Mirrors
    /// `peripheral(_:didUpdateNotificationStateFor:error:)`.
    case didUpdateNotificationState(characteristic: CharacteristicIdentifier, isNotifying: Bool, error: NSError?)

    /// An RSSI read completed (successfully or not). Mirrors
    /// `peripheral(_:didReadRSSI:error:)`.
    case didReadRSSI(Int, error: NSError?)

    /// Services were added or removed. Mirrors `peripheral(_:didModifyServices:)`.
    case didModifyServices([ServiceIdentifier])

    /// The peripheral is ready to accept another `.withoutResponse` write after
    /// previously signaling back-pressure. Mirrors
    /// `peripheralIsReady(toSendWriteWithoutResponse:)`.
    case isReadyToSendWriteWithoutResponse
}
