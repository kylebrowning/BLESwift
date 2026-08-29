//
//  VirtualDevice.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Foundation

/// The static description of one virtual BLE device: its identity, advertisement, and the
/// GATT database it hosts.
///
/// A descriptor is the *data* half of a ``VirtualDevice``; the ``VirtualDeviceHandler``
/// paired with it is the *behavior* half, answering reads and writes for characteristics
/// whose `GATTCharacteristic.value` is `nil`.
public struct VirtualDeviceDescriptor: Sendable {

    /// A stable identifier for this device, used as the peripheral identifier every
    /// ``VirtualCentralBackend`` reports for it.
    public var identifier: UUID

    /// The device's name, reported on discovery and connection.
    public var name: String?

    /// The advertisement this device broadcasts while advertising.
    public var advertisement: AdvertisementData

    /// The GATT services this device hosts.
    public var services: [GATTService]

    /// Creates a descriptor.
    ///
    /// - Parameters:
    ///   - identifier: A stable identifier for this device. Defaults to a fresh `UUID`.
    ///   - name: The device's name. Defaults to `nil`.
    ///   - advertisement: The advertisement to broadcast.
    ///   - services: The GATT services to host. Defaults to none.
    public init(
        identifier: UUID = UUID(),
        name: String? = nil,
        advertisement: AdvertisementData,
        services: [GATTService] = []
    ) {
        self.identifier = identifier
        self.name = name
        self.advertisement = advertisement
        self.services = services
    }
}

/// The behavior half of a ``VirtualDevice``: the code that answers GATT traffic the radio
/// cannot answer from the device's static database.
///
/// A characteristic with a non-`nil` `GATTCharacteristic.value` is *static*
/// and is answered by ``VirtualRadio`` itself, exactly as CoreBluetooth answers a static
/// `CBMutableCharacteristic`; every other read, and every write, reaches the handler.
public protocol VirtualDeviceHandler: Sendable {

    /// Answers a read of a dynamic characteristic.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic being read.
    ///   - offset: The byte offset the read begins at.
    ///   - central: The remote central issuing the read.
    /// - Returns: The value on success, or the `ATTError` to fail the read with.
    func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError>

    /// Applies a batch of writes, all-or-nothing.
    ///
    /// - Parameters:
    ///   - entries: The writes in the batch, in arrival order.
    ///   - central: The remote central issuing the writes.
    /// - Returns: `.success` to apply the whole batch, or the `ATTError` to reject it with.
    func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError>

    /// Reports that a central subscribed to, or unsubscribed from, a characteristic.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic whose subscription changed.
    ///   - central: The remote central whose subscription changed.
    ///   - isSubscribed: `true` when the central subscribed, `false` when it unsubscribed.
    func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async
}

/// A virtual BLE device: a ``VirtualDeviceDescriptor`` paired with the
/// ``VirtualDeviceHandler`` that serves its dynamic GATT traffic.
///
/// Register one with ``VirtualRadio/register(_:advertising:)`` to make it visible to every
/// ``VirtualCentralBackend`` served by that radio.
public struct VirtualDevice: Sendable {

    /// The device's identity, advertisement, and GATT database.
    public var descriptor: VirtualDeviceDescriptor

    /// The handler serving this device's dynamic reads and writes.
    public var handler: any VirtualDeviceHandler

    /// Creates a virtual device.
    ///
    /// - Parameters:
    ///   - descriptor: The device's identity, advertisement, and GATT database.
    ///   - handler: The handler serving its dynamic reads and writes.
    public init(descriptor: VirtualDeviceDescriptor, handler: any VirtualDeviceHandler) {
        self.descriptor = descriptor
        self.handler = handler
    }
}

/// The control handle ``VirtualRadio/register(_:advertising:)`` returns, letting the code
/// behind a virtual device push notifications and mutate its own database after
/// registration.
///
/// Every method hops onto the owning actor; the handle itself holds no mutable state, so
/// it is freely `Sendable`.
public final class VirtualDeviceHandle: Sendable {

    /// The registered device's identifier.
    public let identifier: UUID

    /// The radio hosting the device.
    private let radio: VirtualRadio

    /// Creates a handle bound to `radio`.
    init(identifier: UUID, radio: VirtualRadio) {
        self.identifier = identifier
        self.radio = radio
    }

    /// Pushes a notification for `characteristic` to every connected central currently
    /// subscribed to it.
    ///
    /// - Parameters:
    ///   - value: The notified value.
    ///   - characteristic: The characteristic the value belongs to.
    ///   - centrals: Restricts delivery to these centrals; `nil` notifies every subscriber.
    public func notify(_ value: Data, for characteristic: CharacteristicIdentifier, to centrals: [Subscriber]?) async {
        await radio.notify(device: identifier, characteristic: characteristic, value: value, to: centrals)
    }

    /// Starts or stops advertising this device. Starting advertising reports one sighting
    /// to every active scanner whose service filter it matches.
    ///
    /// - Parameter advertising: Whether the device advertises from now on.
    public func setAdvertising(_ advertising: Bool) async {
        await radio.setAdvertising(advertising, device: identifier)
    }

    /// Replaces the advertisement the device broadcasts. Takes effect for every sighting
    /// reported from now on; already-reported sightings are not revised.
    ///
    /// - Parameter advertisement: The device's new advertisement.
    public func setAdvertisement(_ advertisement: AdvertisementData) async {
        await radio.setAdvertisement(advertisement, device: identifier)
    }

    /// Replaces the device's GATT database — including the static values the radio answers
    /// reads from. Already-discovered centrals keep their discovery cache; this is a
    /// database update, not a service-change indication.
    ///
    /// - Parameter services: The device's new services.
    public func setServices(_ services: [GATTService]) async {
        await radio.setServices(services, device: identifier)
    }

    /// Removes the device from the radio. Every central currently connected to it is
    /// disconnected with ``VirtualRadio/deviceRemovedError``, and later connection attempts
    /// fail with ``VirtualRadio/unknownDeviceError``.
    public func remove() async {
        await radio.remove(device: identifier)
    }
}
#endif
