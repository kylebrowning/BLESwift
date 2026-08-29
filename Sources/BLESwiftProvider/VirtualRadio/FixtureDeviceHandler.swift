//
//  FixtureDeviceHandler.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Foundation

/// The ``VirtualDeviceHandler`` behind a device declared in a fixture document: a
/// read/write store seeded from the fixture's characteristics, with notifications pushed
/// automatically on every accepted write.
///
/// Fixture devices have no code of their own, so this handler supplies the only behavior
/// they get — enough to exercise a real client end to end: reads return what was last
/// written, writes are permission-checked against the declared properties, and a write to a
/// notifying characteristic is echoed to every subscriber.
public actor FixtureDeviceHandler: VirtualDeviceHandler {

    /// The current value of every characteristic, seeded from the fixture.
    private var values: [CharacteristicIdentifier: Data] = [:]

    /// The properties every characteristic declares, for permission checks.
    private var properties: [CharacteristicIdentifier: CharacteristicProperties] = [:]

    /// The device's GATT database, republished to the radio whenever a write changes a
    /// static characteristic's value.
    private var services: [GATTService]

    /// The handle this device was registered under, once ``attach(_:)`` has been called.
    private var handle: VirtualDeviceHandle?

    /// Creates a handler serving `device`'s declared GATT database.
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

    /// Attaches the handle returned by ``VirtualRadio/register(_:advertising:)``, so writes
    /// can notify subscribers and refresh static values. Until this is called, an accepted
    /// write is stored but neither notified nor republished.
    ///
    /// - Parameter handle: The registered device's handle.
    public func attach(_ handle: VirtualDeviceHandle) {
        self.handle = handle
    }

    /// Answers a read from the store.
    ///
    /// - Returns: The stored value (empty `Data` if the characteristic has never held one),
    ///   or `ATTError.readNotPermitted` if the fixture declares no such
    ///   characteristic.
    public func read(
        _ characteristic: CharacteristicIdentifier,
        offset: Int,
        from central: Subscriber
    ) async -> Result<Data, ATTError> {
        guard properties[characteristic] != nil else { return .failure(.readNotPermitted) }
        return .success(values[characteristic] ?? Data())
    }

    /// Applies a batch of writes, all-or-nothing: every entry is permission-checked first,
    /// and the batch is rejected outright if any characteristic is unknown or declares
    /// neither `write` nor `writeWithoutResponse`.
    ///
    /// A stored write to a *static* characteristic (one the fixture gave a value, which the
    /// radio answers reads from itself) is also republished with
    /// ``VirtualDeviceHandle/setServices(_:)``, so later reads see it. A write to a
    /// characteristic declaring `notify` or `indicate` is then pushed to every subscriber.
    public func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
        for entry in entries {
            guard let declared = properties[entry.characteristic] else { return .failure(.writeNotPermitted) }
            guard declared.contains(.write) || declared.contains(.writeWithoutResponse) else {
                return .failure(.writeNotPermitted)
            }
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

    /// A no-op — a fixture device has no behavior to start or stop when a central
    /// subscribes; ``write(_:from:)`` notifies whoever is listening at the time.
    public func subscriptionChanged(
        _ characteristic: CharacteristicIdentifier,
        central: Subscriber,
        isSubscribed: Bool
    ) async {}

    /// Rewrites ``services`` so every *static* characteristic among `written` carries its
    /// newly stored value. Dynamic characteristics (declared with no value) stay dynamic.
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

    /// Builds a virtual device from a fixture declaration, paired with the
    /// ``FixtureDeviceHandler`` serving it.
    ///
    /// Register the device, then hand the returned handle to the handler:
    ///
    /// ```swift
    /// let (device, handler) = VirtualDevice.fixture(fixtureDevice)
    /// await handler.attach(radio.register(device))
    /// ```
    ///
    /// - Parameter device: The fixture device to realize.
    /// - Returns: The virtual device, and the handler that serves it.
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
    fileprivate var isNotifiable: Bool {
        contains(.notify) || contains(.indicate)
    }
}
#endif
