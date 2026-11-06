//
//  GATTCharacteristic.swift
//  BLESwiftCore
//

import Foundation

/// A value-type definition of one characteristic in a hosted GATT service.
///
/// When you add the owning ``GATTService``, the `PeripheralHost` actor compiles this type to a
/// `CBMutableCharacteristic` inside its CoreBluetooth seam. This type stays free of CoreBluetooth.
public struct GATTCharacteristic: Sendable, Hashable {

    /// The characteristic's identifier. Its scope is the owning service.
    public let identifier: CharacteristicIdentifier

    /// The operations that this characteristic advertises (read, write, notify, and others).
    public let properties: CharacteristicProperties

    /// The access permissions for this characteristic's value.
    public let permissions: AttributePermissions

    /// The cached value of the characteristic.
    ///
    /// A value that is not `nil` makes this a **static** characteristic. CoreBluetooth answers the
    /// reads itself, and the characteristic must be read-only, as for `CBMutableCharacteristic`. A
    /// `nil` value makes it **dynamic**: reads and writes appear on `PeripheralHost/readRequests()`
    /// and `PeripheralHost/writeRequests()`, and you serve the value on demand.
    public let value: Data?

    /// Creates a characteristic definition.
    public init(
        identifier: CharacteristicIdentifier,
        properties: CharacteristicProperties = [.read],
        permissions: AttributePermissions = [.readable],
        value: Data? = nil
    ) {
        self.identifier = identifier
        self.properties = properties
        self.permissions = permissions
        self.value = value
    }
}
