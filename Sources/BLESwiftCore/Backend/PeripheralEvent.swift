//
//  PeripheralEvent.swift
//  BLESwiftCore
//

import Foundation

/// A `Sendable` representation of a `CBPeripheralDelegate` callback, speaking exclusively
/// in BLESwift-owned types. See ``PeripheralRemote`` for the delivery contract, and
/// ``CentralEvent`` for why errors are typed `NSError?` rather than `any Error`.
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

    /// Descriptor discovery for `characteristic` completed (successfully or not). Mirrors
    /// `peripheral(_:didDiscoverDescriptorsFor:error:)`.
    case didDiscoverDescriptors(characteristic: CharacteristicIdentifier, error: NSError?)

    /// `descriptor`'s value was read. Mirrors `peripheral(_:didUpdateValueFor:error:)` for a
    /// `CBDescriptor`. CoreBluetooth's untyped `Any?` value is converted to `Data` eagerly,
    /// at the proxy boundary, so it never crosses into the actor.
    case didUpdateValueForDescriptor(descriptor: DescriptorIdentifier, value: Data?, error: NSError?)

    /// A write to `descriptor` completed (successfully or not). Mirrors
    /// `peripheral(_:didWriteValueFor:error:)` for a `CBDescriptor`.
    case didWriteValueForDescriptor(descriptor: DescriptorIdentifier, error: NSError?)

    /// An RSSI read completed (successfully or not). Mirrors
    /// `peripheral(_:didReadRSSI:error:)`.
    case didReadRSSI(Int, error: NSError?)

    /// Services were added or removed. Mirrors `peripheral(_:didModifyServices:)`.
    case didModifyServices([ServiceIdentifier])

    /// The peripheral is ready to accept another `.withoutResponse` write after
    /// previously signaling back-pressure. Mirrors
    /// `peripheralIsReady(toSendWriteWithoutResponse:)`.
    case isReadyToSendWriteWithoutResponse

    /// An L2CAP channel-open attempt completed. Mirrors `peripheral(_:didOpen:error:)`.
    /// On success `channel` is the opened transport and `error` is `nil`; on failure
    /// `channel` is `nil` and `error` describes the failure.
    case didOpenL2CAPChannel(channel: (any L2CAPChannelRemote)?, error: NSError?)
}
