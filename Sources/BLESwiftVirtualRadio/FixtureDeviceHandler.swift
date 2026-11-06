//
//  FixtureDeviceHandler.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import BLESwiftLink
import Foundation

/// The ``VirtualDeviceHandler`` for a device that a fixture document declares.
/// It is a read/write store. The fixture's characteristics give the first values.
///
/// - A read returns the value that was last written.
/// - A write is checked against the declared properties.
/// - A write to a notifying characteristic goes to every subscriber.
public actor FixtureDeviceHandler: VirtualDeviceHandler {

    /// The current value of every characteristic. The fixture gives the first values.
    private var values: [CharacteristicIdentifier: Data] = [:]

    /// The properties that each characteristic declares, for permission checks.
    private var properties: [CharacteristicIdentifier: CharacteristicProperties] = [:]

    /// The device's GATT database. The handler republishes it each time a write changes a static
    /// characteristic.
    private var services: [GATTService]

    /// The handle of the registered device. It is `nil` until ``attach(_:)`` runs.
    private var handle: VirtualDeviceHandle?

    /// Creates a handler that serves the GATT database that `device` declares.
    ///
    /// - Parameter device: The fixture device to serve.
    public init(device: FixtureDevice) {
        self.services = device.gattServices
        for service in services {
            for characteristic in service.characteristics {
                properties[characteristic.identifier] = characteristic.properties
                if let value = characteristic.value {
                    values[characteristic.identifier] = value
                }
            }
        }
    }

    /// Attaches the handle that ``VirtualRadio/register(_:advertising:)`` returns. With the handle,
    /// a write can notify subscribers and refresh static values. Without it, the handler stores an
    /// accepted write but does not notify or republish.
    ///
    /// The handle does not keep the radio alive, because ``VirtualDeviceHandle`` refers to the
    /// radio weakly. The code that registered the device must keep a reference to the radio. After
    /// the radio is gone, the handler stores an accepted write but does not notify or republish.
    ///
    /// - Parameter handle: The registered device's handle.
    public func attach(_ handle: VirtualDeviceHandle) {
        self.handle = handle
    }

    /// Answers a read from the store.
    ///
    /// - Returns: The stored value from `offset` to the end, or a failure.
    ///   - If the characteristic never held a value, the stored value is empty `Data`.
    ///   - `ATTError.attributeNotFound`: the fixture declares no such characteristic.
    ///   - `ATTError.readNotPermitted`: the characteristic is neither readable nor notifiable.
    ///   - `ATTError.invalidOffset`: `offset` is negative or is after the end of the stored value.
    public func read(
        _ characteristic: CharacteristicIdentifier,
        offset: Int,
        from central: Subscriber
    ) async -> Result<Data, ATTError> {
        guard let declared = properties[characteristic] else { return .failure(.attributeNotFound) }
        guard declared.contains(.read) || declared.isNotifiable else { return .failure(.readNotPermitted) }
        let value = values[characteristic] ?? Data()
        // An offset *at* the end is legal and gives empty data. A long read uses it to find the
        // end.
        guard offset >= 0, offset <= value.count else { return .failure(.invalidOffset) }
        return .success(Data(value.dropFirst(offset)))
    }

    /// Applies a batch of writes, all-or-nothing. The handler checks every entry first. It rejects
    /// the whole batch if any characteristic is unknown, or declares neither `write` nor
    /// `writeWithoutResponse`.
    ///
    /// A static characteristic is one that the fixture gave a value. The radio answers its reads.
    /// After a write to a static characteristic, the handler republishes the services with
    /// ``VirtualDeviceHandle/setServices(_:)``, so later reads see the write. The handler then
    /// pushes a write to a characteristic that declares `notify` or `indicate` to every subscriber.
    public func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
        for entry in entries {
            guard let declared = properties[entry.characteristic] else { return .failure(.writeNotPermitted) }
            guard declared.isWritable else { return .failure(.writeNotPermitted) }
        }

        for entry in entries {
            values[entry.characteristic] = entry.value
        }

        refreshStaticValues(for: entries.map(\.characteristic))
        if let handle {
            await handle.setServices(services)
            for entry in entries where properties[entry.characteristic]?.isNotifiable == true {
                await handle.notify(entry.value, for: entry.characteristic, to: nil)
            }
        }
        return .success(())
    }

    /// Does nothing. ``write(_:from:)`` notifies the subscribers that exist at the time of the
    /// write.
    public func subscriptionChanged(
        _ characteristic: CharacteristicIdentifier,
        central: Subscriber,
        isSubscribed: Bool
    ) async {}

    /// Rewrites ``services`` so that every *static* characteristic in `written` has its new stored
    /// value. A dynamic characteristic (declared with no value) stays dynamic.
    private func refreshStaticValues(for written: [CharacteristicIdentifier]) {
        let changed = Set(written)
        services = services.map { service in
            GATTService(
                identifier: service.identifier,
                isPrimary: service.isPrimary,
                characteristics: service.characteristics.map { characteristic in
                    guard characteristic.value != nil, changed.contains(characteristic.identifier) else {
                        return characteristic
                    }
                    return GATTCharacteristic(
                        identifier: characteristic.identifier,
                        properties: characteristic.properties,
                        permissions: characteristic.permissions,
                        value: values[characteristic.identifier]
                    )
                }
            )
        }
    }
}

extension VirtualDevice {

    /// Builds a virtual device from a fixture declaration, with the ``FixtureDeviceHandler`` that
    /// serves it. Register the device, then give the returned handle to the handler:
    ///
    /// ```swift
    /// let (device, handler) = VirtualDevice.fixture(fixtureDevice)
    /// await handler.attach(radio.register(device))
    /// ```
    ///
    /// - Parameter device: The fixture device to build a virtual device from.
    /// - Returns: The virtual device and the handler that serves it.
    public static func fixture(_ device: FixtureDevice) -> (VirtualDevice, FixtureDeviceHandler) {
        let handler = FixtureDeviceHandler(device: device)
        let descriptor = VirtualDeviceDescriptor(
            identifier: device.id,
            name: device.name,
            advertisement: device.advertisement,
            services: device.gattServices
        )
        return (VirtualDevice(descriptor: descriptor, handler: handler), handler)
    }
}

extension CharacteristicProperties {

    /// Whether these properties allow the peripheral to push the value to a subscriber.
    ///
    /// ``VirtualRadio/read(device:characteristic:offset:session:)`` uses the same read rule for a
    /// static value.
    var isNotifiable: Bool {
        contains(.notify) || contains(.indicate)
    }

    /// Whether these properties allow a central to write the value.
    ///
    /// ``VirtualRadio/write(device:characteristic:value:session:)`` uses the same rule at the ATT
    /// layer, before a write reaches any device's handler.
    var isWritable: Bool {
        contains(.write) || contains(.writeWithoutResponse)
    }
}
