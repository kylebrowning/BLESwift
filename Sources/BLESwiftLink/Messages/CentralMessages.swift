//
//  CentralMessages.swift
//  BLESwiftLink
//

import Foundation

/// A request sent from a `Central`-role client to the provider, driving a remote
/// `Central`.
public enum CentralRequest: Codable, Sendable, Equatable {

    /// Start scanning for peripherals advertising `services` (or any peripheral, if
    /// `nil`), optionally reporting duplicate advertisements.
    case scan(services: [String]?, allowDuplicates: Bool)

    /// Stop an in-progress scan.
    case stopScan

    /// Connect to `peripheral`, with optional connection `options` and ANCS
    /// authorization requirement.
    case connect(peripheral: UUID, options: WireConnectOptions?, requiresANCS: Bool)

    /// Cancel an in-progress or established connection to `peripheral`.
    case cancelConnection(peripheral: UUID)

    /// Register to receive `connectionEventDidOccur` events for `services` and/or
    /// `peripherals`.
    case registerForConnectionEvents(services: [String]?, peripherals: [UUID]?)

    /// Stop receiving `connectionEventDidOccur` events.
    case unregisterForConnectionEvents

    /// Discover `services` (or all services, if `nil`) on `peripheral`.
    case discoverServices(peripheral: UUID, services: [String]?)

    /// Discover `characteristics` (or all characteristics, if `nil`) of `service` on
    /// `peripheral`.
    case discoverCharacteristics(peripheral: UUID, service: String, characteristics: [String]?)

    /// Read the current value of `characteristic` on `peripheral`.
    case readValue(peripheral: UUID, characteristic: WireCharacteristicRef)

    /// Write `value` to `characteristic` on `peripheral`, of the given `type`, tagged
    /// with `sequence` for correlating a `writeWithoutResponseAccepted` acknowledgement.
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

    /// Open an L2CAP channel to `peripheral` at `psm`, identified locally by `channel`.
    case openL2CAPChannel(peripheral: UUID, psm: UInt16, channel: UInt32)

    /// Send `data` over the L2CAP `channel`.
    case l2capData(channel: UInt32, data: Data)

    /// Grant `bytes` of flow-control credit to the L2CAP `channel`.
    case l2capCredit(channel: UInt32, bytes: Int)

    /// Close the L2CAP `channel`.
    case l2capClose(channel: UInt32)
}

/// An event sent from the provider to a `Central`-role client, reporting activity from a
/// remote `Central`.
public enum CentralWireEvent: Codable, Sendable, Equatable {

    /// The central's Bluetooth state changed.
    case didUpdateState(WireCentralState)

    /// A peripheral advertisement was received.
    case didDiscover(peripheral: UUID, name: String?, advertisement: WireAdvertisement, rssi: Int)

    /// `peripheral` connected, with its negotiated maximum write lengths.
    case didConnect(peripheral: UUID, name: String?, maximumWriteWithResponse: Int, maximumWriteWithoutResponse: Int)

    /// Connecting to `peripheral` failed.
    case didFailToConnect(peripheral: UUID, error: WireError?)

    /// `peripheral` disconnected.
    case didDisconnect(peripheral: UUID, error: WireError?)

    /// A registered connection event occurred for `peripheral`.
    case connectionEventDidOccur(peripheral: UUID, connected: Bool)

    /// `peripheral`'s ANCS authorization changed.
    case didUpdateANCSAuthorization(peripheral: UUID, authorized: Bool)

    /// Service discovery on `peripheral` completed, yielding `services` (or failed with
    /// `error`).
    case didDiscoverServices(peripheral: UUID, services: [String], error: WireError?)

    /// Characteristic discovery for `service` on `peripheral` completed, yielding
    /// `characteristics` (or failed with `error`).
    case didDiscoverCharacteristics(peripheral: UUID, service: String, characteristics: [WireDiscoveredCharacteristic], error: WireError?)

    /// A write with response to `characteristic` on `peripheral` completed (or failed
    /// with `error`).
    case didWriteValue(peripheral: UUID, characteristic: WireCharacteristicRef, error: WireError?)

    /// The peripheral is ready to accept another write without response, tagged with the
    /// `sequence` from the originating `writeValue` request.
    ///
    /// The client matches `sequence` against the writes it still has outstanding for
    /// `peripheral` and reopens the window only for one it recognizes: a sequence it never
    /// sent, one it has already been acknowledged for, or one belonging to a connection that
    /// has since been reset is ignored, so a late or duplicated acknowledgement cannot open
    /// the *next* connection's window early.
    case writeWithoutResponseAccepted(peripheral: UUID, sequence: UInt64)

    /// `characteristic` on `peripheral` was read, or a notification delivered a new
    /// `value` (or the update failed with `error`).
    case didUpdateValue(peripheral: UUID, characteristic: WireCharacteristicRef, value: Data?, error: WireError?)

    /// Notification state for `characteristic` on `peripheral` changed to `isNotifying`
    /// (or the change failed with `error`).
    case didUpdateNotificationState(peripheral: UUID, characteristic: WireCharacteristicRef, isNotifying: Bool, error: WireError?)

    /// Descriptor discovery for `characteristic` on `peripheral` completed, yielding
    /// `descriptors` (or failed with `error`).
    case didDiscoverDescriptors(peripheral: UUID, characteristic: WireCharacteristicRef, descriptors: [String], error: WireError?)

    /// `descriptor` on `peripheral` was read (or the read failed with `error`).
    case didUpdateValueForDescriptor(peripheral: UUID, descriptor: WireDescriptorRef, value: Data?, error: WireError?)

    /// A write to `descriptor` on `peripheral` completed (or failed with `error`).
    case didWriteValueForDescriptor(peripheral: UUID, descriptor: WireDescriptorRef, error: WireError?)

    /// `peripheral`'s RSSI was read (or the read failed with `error`).
    case didReadRSSI(peripheral: UUID, rssi: Int, error: WireError?)

    /// `peripheral`'s GATT database changed; `invalidated` service UUIDs must be
    /// rediscovered.
    case didModifyServices(peripheral: UUID, invalidated: [String])

    /// An L2CAP channel to `peripheral` opened (or failed to open with `error`),
    /// identified locally by `channel`.
    case didOpenL2CAPChannel(peripheral: UUID, channel: UInt32, psm: UInt16, error: WireError?)

    /// `data` arrived on the L2CAP `channel`.
    case l2capData(channel: UInt32, data: Data)

    /// `bytes` of flow-control credit were granted to the L2CAP `channel`.
    case l2capCredit(channel: UInt32, bytes: Int)

    /// The L2CAP `channel` closed (or failed with `error`).
    case l2capClosed(channel: UInt32, error: WireError?)
}
