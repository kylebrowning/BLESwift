//
//  CentralMessages.swift
//  BLESwiftLink
//

import Foundation

/// A request that a `Central`-role client sends to the provider. The request controls a
/// remote `Central`.
public enum CentralRequest: Codable, Sendable, Equatable {

    /// Start a scan for peripherals that advertise `services`. If `services` is `nil`, scan for
    /// any peripheral. The scan can also report duplicate advertisements.
    case scan(services: [String]?, allowDuplicates: Bool)

    /// Stop a scan that is in progress.
    case stopScan

    /// Connect to `peripheral`. The request has optional connection `options` and an optional
    /// ANCS authorization requirement.
    case connect(peripheral: UUID, options: WireConnectOptions?, requiresANCS: Bool)

    /// Cancel a connection to `peripheral`. The connection can be in progress or established.
    case cancelConnection(peripheral: UUID)

    /// Register to receive `connectionEventDidOccur` events for `services`, `peripherals`, or
    /// both.
    case registerForConnectionEvents(services: [String]?, peripherals: [UUID]?)

    /// Stop the `connectionEventDidOccur` events.
    case unregisterForConnectionEvents

    /// Discover `services` on `peripheral`. If `services` is `nil`, discover all services.
    case discoverServices(peripheral: UUID, services: [String]?)

    /// Discover `characteristics` of `service` on `peripheral`. If `characteristics` is `nil`,
    /// discover all characteristics.
    case discoverCharacteristics(peripheral: UUID, service: String, characteristics: [String]?)

    /// Read the current value of `characteristic` on `peripheral`.
    case readValue(peripheral: UUID, characteristic: WireCharacteristicRef)

    /// Write `value` to `characteristic` on `peripheral`, with the given `type`. The request has
    /// a `sequence` tag. The client uses the tag to match a `writeWithoutResponseAccepted`
    /// acknowledgement.
    case writeValue(peripheral: UUID, characteristic: WireCharacteristicRef, value: Data, type: WireWriteType, sequence: UInt64)

    /// Enable or disable notifications for `characteristic` on `peripheral`.
    case setNotifyValue(peripheral: UUID, characteristic: WireCharacteristicRef, enabled: Bool)

    /// Discover the descriptors of `characteristic` on `peripheral`.
    case discoverDescriptors(peripheral: UUID, characteristic: WireCharacteristicRef)

    /// Read the current value of `descriptor` on `peripheral`.
    case readDescriptor(peripheral: UUID, descriptor: WireDescriptorRef)

    /// Write `value` to `descriptor` on `peripheral`.
    case writeDescriptor(peripheral: UUID, descriptor: WireDescriptorRef, value: Data)

    /// Read the current RSSI of `peripheral`.
    case readRSSI(peripheral: UUID)

    /// Open an L2CAP channel to `peripheral` at `psm`. The client identifies the channel with
    /// `channel`.
    case openL2CAPChannel(peripheral: UUID, psm: UInt16, channel: UInt32)

    /// Send `data` over the L2CAP `channel`.
    case l2capData(channel: UInt32, data: Data)

    /// Grant `bytes` of flow-control credit to the L2CAP `channel`.
    case l2capCredit(channel: UInt32, bytes: Int)

    /// Close the L2CAP `channel`.
    case l2capClose(channel: UInt32)
}

/// An event that the provider sends to a `Central`-role client. The event reports activity of
/// a remote `Central`.
public enum CentralWireEvent: Codable, Sendable, Equatable {

    /// The Bluetooth state of the central changed.
    case didUpdateState(WireCentralState)

    /// The central received a peripheral advertisement.
    case didDiscover(peripheral: UUID, name: String?, advertisement: WireAdvertisement, rssi: Int)

    /// `peripheral` connected. The event includes the negotiated maximum write lengths.
    case didConnect(peripheral: UUID, name: String?, maximumWriteWithResponse: Int, maximumWriteWithoutResponse: Int)

    /// The connection to `peripheral` failed.
    case didFailToConnect(peripheral: UUID, error: WireError?)

    /// `peripheral` disconnected.
    case didDisconnect(peripheral: UUID, error: WireError?)

    /// A registered connection event occurred for `peripheral`.
    case connectionEventDidOccur(peripheral: UUID, connected: Bool)

    /// The ANCS authorization of `peripheral` changed.
    case didUpdateANCSAuthorization(peripheral: UUID, authorized: Bool)

    /// Service discovery on `peripheral` completed and gives `services`. If the discovery
    /// failed, the event gives `error`.
    case didDiscoverServices(peripheral: UUID, services: [String], error: WireError?)

    /// Characteristic discovery for `service` on `peripheral` completed and gives
    /// `characteristics`. If the discovery failed, the event gives `error`.
    case didDiscoverCharacteristics(peripheral: UUID, service: String, characteristics: [WireDiscoveredCharacteristic], error: WireError?)

    /// A write with response to `characteristic` on `peripheral` completed. If the write failed,
    /// the event gives `error`.
    case didWriteValue(peripheral: UUID, characteristic: WireCharacteristicRef, error: WireError?)

    /// The peripheral is ready to accept one more write without response. The event has the
    /// `sequence` tag from the `writeValue` request that started the write.
    ///
    /// The client matches `sequence` against its outstanding writes for `peripheral`. It opens
    /// the window again only for a sequence that it recognizes. The client ignores a sequence if:
    ///
    /// - The client never sent the sequence.
    /// - The client already got an acknowledgement for the sequence.
    /// - The sequence belongs to a connection that the client has since reset.
    ///
    /// Thus a late or duplicated acknowledgement cannot open the *next* connection's window too
    /// early.
    case writeWithoutResponseAccepted(peripheral: UUID, sequence: UInt64)

    /// The client read `characteristic` on `peripheral`, or a notification delivered a new
    /// `value`. If the update failed, the event gives `error`.
    case didUpdateValue(peripheral: UUID, characteristic: WireCharacteristicRef, value: Data?, error: WireError?)

    /// The notification state of `characteristic` on `peripheral` changed to `isNotifying`.
    /// If the change failed, the event gives `error`.
    case didUpdateNotificationState(peripheral: UUID, characteristic: WireCharacteristicRef, isNotifying: Bool, error: WireError?)

    /// Descriptor discovery for `characteristic` on `peripheral` completed and gives
    /// `descriptors`. If the discovery failed, the event gives `error`.
    case didDiscoverDescriptors(peripheral: UUID, characteristic: WireCharacteristicRef, descriptors: [String], error: WireError?)

    /// The client read `descriptor` on `peripheral`. If the read failed, the event gives
    /// `error`.
    case didUpdateValueForDescriptor(peripheral: UUID, descriptor: WireDescriptorRef, value: Data?, error: WireError?)

    /// A write to `descriptor` on `peripheral` completed. If the write failed, the event gives
    /// `error`.
    case didWriteValueForDescriptor(peripheral: UUID, descriptor: WireDescriptorRef, error: WireError?)

    /// The client read the RSSI of `peripheral`. If the read failed, the event gives `error`.
    case didReadRSSI(peripheral: UUID, rssi: Int, error: WireError?)

    /// The GATT database of `peripheral` changed. The client must discover the services with the
    /// `invalidated` UUIDs again.
    case didModifyServices(peripheral: UUID, invalidated: [String])

    /// An L2CAP channel to `peripheral` opened. The client identifies the channel with
    /// `channel`. If the open failed, the event gives `error`.
    case didOpenL2CAPChannel(peripheral: UUID, channel: UInt32, psm: UInt16, error: WireError?)

    /// `data` arrived on the L2CAP `channel`.
    case l2capData(channel: UInt32, data: Data)

    /// The provider granted `bytes` of flow-control credit to the L2CAP `channel`.
    case l2capCredit(channel: UInt32, bytes: Int)

    /// The L2CAP `channel` closed. If it closed because of a failure, the event gives `error`.
    case l2capClosed(channel: UInt32, error: WireError?)
}
