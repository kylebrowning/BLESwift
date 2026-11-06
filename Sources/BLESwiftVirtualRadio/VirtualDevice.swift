//
//  VirtualDevice.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import Foundation

/// The static description of one virtual BLE device: its identity, advertisement, and GATT
/// database.
///
/// A descriptor is the *data* half of a ``VirtualDevice``. The ``VirtualDeviceHandler`` paired with
/// it is the *behavior* half. The handler answers reads and writes for characteristics whose
/// `GATTCharacteristic.value` is `nil`.
public struct VirtualDeviceDescriptor: Sendable {

    /// A stable identifier for this device. Every ``VirtualCentralBackend`` reports it as the
    /// device's peripheral identifier.
    public var identifier: UUID

    /// The device's name, reported on discovery and on connection.
    public var name: String?

    /// The advertisement that this device broadcasts while it advertises.
    public var advertisement: AdvertisementData

    /// The GATT services that this device hosts.
    public var services: [GATTService]

    /// The length ceiling that this device negotiates for one ATT packet.
    /// A connected central gets this length from `maximumWriteValueLength(for: .withoutResponse)`.
    /// The device drops a longer `.withoutResponse` write and truncates a longer notification.
    ///
    /// The value must be in `20...512`: the minimum ATT_MTU of 23 less the three-byte header, and
    /// the maximum attribute length. ``VirtualRadio/register(_:advertising:)`` traps on a value
    /// outside this range.
    ///
    /// The default is ``VirtualRadio/maximumWriteWithoutResponseLength``, the iOS ATT_MTU less the
    /// header. Set another value to test code that sizes its chunks from the reported length, such
    /// as a DFU or a file transfer.
    ///
    /// A `.withResponse` write is not affected. ATT long writes reach
    /// ``VirtualRadio/maximumValueLength`` for any MTU.
    public var maximumWriteWithoutResponseLength: Int

    /// How long this device takes to answer each kind of request, on the radio's
    /// ``VirtualRadio/clock``. The default is ``VirtualLatency/none``. Change the latency after
    /// registration with ``VirtualDeviceHandle/setLatency(_:)``.
    public var latency: VirtualLatency

    /// Creates a descriptor.
    ///
    /// - Parameters:
    ///   - identifier: A stable identifier for this device. The default is a new `UUID`.
    ///   - name: The device's name. The default is `nil`.
    ///   - advertisement: The advertisement to broadcast.
    ///   - services: The GATT services to host. The default is none.
    ///   - maximumWriteWithoutResponseLength: The one-packet length ceiling that this device
    ///     reports and enforces. The default is ``VirtualRadio/maximumWriteWithoutResponseLength``.
    ///   - latency: How long each kind of request takes to answer. The default is
    ///     ``VirtualLatency/none``.
    public init(
        identifier: UUID = UUID(),
        name: String? = nil,
        advertisement: AdvertisementData,
        services: [GATTService] = [],
        maximumWriteWithoutResponseLength: Int = VirtualRadio.maximumWriteWithoutResponseLength,
        latency: VirtualLatency = .none
    ) {
        self.identifier = identifier
        self.name = name
        self.advertisement = advertisement
        self.services = services
        self.maximumWriteWithoutResponseLength = maximumWriteWithoutResponseLength
        self.latency = latency
    }
}

/// The behavior half of a ``VirtualDevice``. It answers the GATT traffic that the radio cannot
/// answer from the device's static database.
///
/// A characteristic with a non-`nil` `GATTCharacteristic.value` is *static*. ``VirtualRadio``
/// answers its reads, as CoreBluetooth does for a static `CBMutableCharacteristic`. Every other
/// read reaches the handler. Every write also reaches the handler.
public protocol VirtualDeviceHandler: Sendable {

    /// Answers a read of a dynamic characteristic.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic that the central reads.
    ///   - offset: The byte offset where the read begins.
    ///   - central: The remote central that issues the read.
    /// - Returns: The value on success, or the `ATTError` that fails the read.
    func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError>

    /// Applies a batch of writes, all-or-nothing.
    ///
    /// - Parameters:
    ///   - entries: The writes in the batch, in the order that they arrived.
    ///   - central: The remote central that issues the writes.
    /// - Returns: `.success` to apply the whole batch, or the `ATTError` that rejects it.
    func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError>

    /// Reports that a central subscribed to a characteristic, or unsubscribed from it.
    ///
    /// A device's reports arrive in the order that the radio applied the changes, one at a time.
    /// The radio does not deliver the next report until this call returns.
    ///
    /// A handler can call back into the radio from here. Examples are:
    ///
    /// - ``VirtualDeviceHandle/setServices(_:)``
    /// - ``VirtualDeviceHandle/disconnect(_:error:)``
    /// - ``VirtualDeviceHandle/remove()``
    /// - a new ``VirtualRadio/register(_:advertising:)``
    ///
    /// The handler gets the result of its call before the radio delivers the reports that the call
    /// caused. Those reports follow after this call returns.
    ///
    /// **A report that never returns blocks every later report for the device.** This also blocks
    /// every call that waits on those reports:
    ///
    /// - another central's `setNotifyValue`
    /// - a disconnect or cancel that drops a subscription
    /// - `remove()`
    /// - `setServices(_:)`
    /// - a new `register`
    /// - the detach of a backend
    ///
    /// Return promptly. Hand long work to a task.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic whose subscription changed.
    ///   - central: The remote central whose subscription changed.
    ///   - isSubscribed: `true` when the central subscribed, and `false` when it unsubscribed.
    func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async
}

/// A virtual BLE device. It is a ``VirtualDeviceDescriptor`` paired with the
/// ``VirtualDeviceHandler`` that serves its dynamic GATT traffic.
///
/// Register one with ``VirtualRadio/register(_:advertising:)`` to make it visible to every
/// ``VirtualCentralBackend`` that the radio serves.
public struct VirtualDevice: Sendable {

    /// The identity, the advertisement, and the GATT database of the device.
    public var descriptor: VirtualDeviceDescriptor

    /// The handler that serves the dynamic reads and writes of this device.
    public var handler: any VirtualDeviceHandler

    /// Creates a virtual device.
    ///
    /// - Parameters:
    ///   - descriptor: The identity, the advertisement, and the GATT database of the device.
    ///   - handler: The handler that serves its dynamic reads and writes.
    public init(descriptor: VirtualDeviceDescriptor, handler: any VirtualDeviceHandler) {
        self.descriptor = descriptor
        self.handler = handler
    }
}

/// The control handle that ``VirtualRadio/register(_:advertising:)`` returns. The code behind a
/// virtual device uses it to push notifications and to change the device after registration.
///
/// Every method hops onto the radio's actor. The handle has no mutable state, so it is `Sendable`.
///
/// The handle holds its radio *weakly*, so a handler that keeps its handle (as
/// ``FixtureDeviceHandler`` does) cannot keep the radio alive. When the last external reference to
/// the radio drops, every method below does nothing. The same is true for a removed device.
public final class VirtualDeviceHandle: Sendable {

    /// The registered device's identifier.
    public let identifier: UUID

    /// Which registration of ``identifier`` this handle belongs to.
    ///
    /// If code registers the same identifier again (a link client that redials with a stable
    /// `hostIdentifier` does), the radio replaces the device and creates a newer generation. Every
    /// method below sends this generation. The radio applies the change only while it is the
    /// current registration. Thus the asynchronous teardown of an old session cannot remove,
    /// unadvertise, or empty the device that its successor registered.
    let generation: UInt64

    /// The radio that hosts the device. The reference is weak, because the radio's device table
    /// holds the handler and the handler can hold this handle. A strong reference would make a
    /// cycle.
    ///
    /// `nonisolated(unsafe)` is necessary because a `weak` reference cannot be a `let`. `init`
    /// writes it once. Weak loads are thread-safe, so readers see the radio or `nil`.
    nonisolated(unsafe) weak var radio: VirtualRadio?

    /// Creates a handle bound to `radio`, for the registration that `generation` identifies.
    init(identifier: UUID, generation: UInt64, radio: VirtualRadio) {
        self.identifier = identifier
        self.generation = generation
        self.radio = radio
    }

    /// Pushes a notification for `characteristic` to every connected central that is subscribed to
    /// it.
    ///
    /// - Parameters:
    ///   - value: The notified value.
    ///   - characteristic: The characteristic the value belongs to.
    ///   - centrals: Restricts delivery to these centrals. `nil` notifies every subscriber.
    public func notify(_ value: Data, for characteristic: CharacteristicIdentifier, to centrals: [Subscriber]?) async {
        await radio?.notify(
            device: identifier,
            characteristic: characteristic,
            value: value,
            to: centrals,
            generation: generation
        )
    }

    /// Starts or stops advertising. When advertising starts, the device reports one sighting to
    /// every active scanner whose service filter it matches.
    ///
    /// - Parameter advertising: Whether the device advertises from now on.
    public func setAdvertising(_ advertising: Bool) async {
        await radio?.setAdvertising(advertising, device: identifier, generation: generation)
    }

    /// Replaces the advertisement that the device broadcasts. The change applies to later sightings
    /// only.
    ///
    /// - Parameter advertisement: The device's new advertisement.
    public func setAdvertisement(_ advertisement: AdvertisementData) async {
        await radio?.setAdvertisement(advertisement, device: identifier, generation: generation)
    }

    /// Replaces the device's GATT database, including the static values that the radio answers
    /// reads from.
    ///
    /// If the new database drops a service, the radio reports `PeripheralEvent.didModifyServices`
    /// to every connected central. The radio also drops every subscription held under that service
    /// and reports each one to this device's handler as an unsubscribe. A change that only adds
    /// services invalidates nothing and is reported to nobody.
    ///
    /// This method returns after the radio delivers those unsubscribes, in order, behind every
    /// report already in flight for the device. If you call it from inside a subscription report,
    /// it returns before the radio delivers them. The call can come from the handler's
    /// `subscriptionChanged`, or from a task that it started there. The method does not wait,
    /// because it would wait on the report that made the call.
    ///
    /// - Parameter services: The device's new services.
    public func setServices(_ services: [GATTService]) async {
        await radio?.setServices(services, device: identifier, generation: generation)
    }

    /// Replaces how long the device takes to answer each kind of request. The change applies to
    /// operations that start later. An operation that is already delayed keeps its delay.
    ///
    /// - Parameter latency: The device's new latency.
    public func setLatency(_ latency: VirtualLatency) async {
        await radio?.setLatency(latency, device: identifier, generation: generation)
    }

    /// Removes the device from the radio. The radio disconnects every connected central with
    /// ``VirtualRadio/deviceRemovedError``. Later connection attempts fail with
    /// ``VirtualRadio/unknownDeviceError``.
    ///
    /// This method returns after the radio reports each dropped subscription to the handler and
    /// delivers each `didDisconnect`: first the unsubscribes, then the `didDisconnect` events,
    /// behind every report already in flight for the device. If you call it from inside a
    /// subscription report, it returns before the radio delivers them. The call can come from the
    /// handler's `subscriptionChanged`, or from a task that it started there. The method does not
    /// wait, because it would wait on the report that made the call.
    ///
    /// This method does nothing after the code registers the identifier again. See `generation`.
    public func remove() async {
        await radio?.remove(device: identifier, generation: generation)
    }
}
