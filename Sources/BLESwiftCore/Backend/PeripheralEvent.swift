//
//  PeripheralEvent.swift
//  BLESwiftCore
//

import Foundation

/// A `Sendable` representation of a `CBPeripheralDelegate` callback. It uses only types that
/// BLESwift owns. See ``PeripheralRemote`` for the delivery contract. See ``CentralEvent`` for why
/// errors are `NSError?` and not `any Error`.
public enum PeripheralEvent: Sendable {

    /// Service discovery completed (with or without success). Mirrors
    /// `peripheral(_:didDiscoverServices:)`.
    case didDiscoverServices(error: NSError?)

    /// Characteristic discovery for `service` completed (with or without success). Mirrors
    /// `peripheral(_:didDiscoverCharacteristicsFor:error:)`.
    case didDiscoverCharacteristics(service: ServiceIdentifier, error: NSError?)

    /// A write to `characteristic` completed (with or without success). Mirrors
    /// `peripheral(_:didWriteValueFor:error:)`.
    case didWriteValue(characteristic: CharacteristicIdentifier, error: NSError?)

    /// `characteristic`'s value was read, or a notification arrived. Mirrors
    /// `peripheral(_:didUpdateValueFor:error:)`.
    case didUpdateValue(characteristic: CharacteristicIdentifier, value: Data?, error: NSError?)

    /// The notification state of `characteristic` changed. Mirrors
    /// `peripheral(_:didUpdateNotificationStateFor:error:)`.
    case didUpdateNotificationState(characteristic: CharacteristicIdentifier, isNotifying: Bool, error: NSError?)

    /// Descriptor discovery for `characteristic` completed (with or without success). Mirrors
    /// `peripheral(_:didDiscoverDescriptorsFor:error:)`.
    case didDiscoverDescriptors(characteristic: CharacteristicIdentifier, error: NSError?)

    /// The value of `descriptor` was read. Mirrors `peripheral(_:didUpdateValueFor:error:)` for a
    /// `CBDescriptor`. The proxy boundary converts CoreBluetooth's untyped `Any?` value to `Data`
    /// immediately, so the untyped value never crosses into the actor.
    case didUpdateValueForDescriptor(descriptor: DescriptorIdentifier, value: Data?, error: NSError?)

    /// A write to `descriptor` completed (with or without success). Mirrors
    /// `peripheral(_:didWriteValueFor:error:)` for a `CBDescriptor`.
    case didWriteValueForDescriptor(descriptor: DescriptorIdentifier, error: NSError?)

    /// An RSSI read completed (with or without success). Mirrors
    /// `peripheral(_:didReadRSSI:error:)`.
    case didReadRSSI(Int, error: NSError?)

    /// Services were added or removed. Mirrors `peripheral(_:didModifyServices:)`.
    case didModifyServices([ServiceIdentifier])

    /// The peripheral can accept another `.withoutResponse` write after it signaled back-pressure.
    /// Mirrors `peripheralIsReady(toSendWriteWithoutResponse:)`.
    case isReadyToSendWriteWithoutResponse

    /// An L2CAP channel-open attempt completed. Mirrors `peripheral(_:didOpen:error:)`. If the
    /// attempt succeeds, `channel` is the opened transport and `error` is `nil`. If the attempt
    /// fails, `channel` is `nil` and `error` describes the failure.
    case didOpenL2CAPChannel(channel: (any L2CAPChannelRemote)?, error: NSError?)
}
