//
//  GATTCharacteristic.swift
//  BLESwiftCore
//

import Foundation

/// A value-type definition of one characteristic in a hosted GATT service.
///
/// Compiled to a `CBMutableCharacteristic` **inside the `PeripheralHost` actor's
/// CoreBluetooth seam** (never here) when the owning ``GATTService`` is added; this type
/// stays CoreBluetooth-free.
public struct GATTCharacteristic: Sendable, Hashable {

    /// The characteristic's identifier, scoped to its owning service.
    public let identifier: CharacteristicIdentifier

    /// The operations this characteristic advertises (read, write, notify, …).
    public let properties: CharacteristicProperties

    /// The access permissions gating this characteristic's value.
    public let permissions: AttributePermissions

    /// The characteristic's cached value, or `nil` for a *dynamic* characteristic whose
    /// value is served on demand.
    ///
    /// A non-`nil` value makes this a **static** (cached) characteristic: CoreBluetooth
    /// answers reads itself from this constant value, and the characteristic must be
    /// read-only (no `.write`/`.writeWithoutResponse`/`.notify`/`.indicate`), mirroring
    /// `CBMutableCharacteristic`'s own rule. `nil` makes it **dynamic**: reads and writes
    /// surface on `PeripheralHost/readRequests()`/`PeripheralHost/writeRequests()` for
    /// your code to answer, and you push updates with
    /// `PeripheralHost/updateValue(_:for:onSubscribed:)`.
    public let value: Data?

    /// Creates a characteristic definition.
    ///
    /// - Parameters:
    ///   - identifier: The characteristic's identifier, scoped to its owning service.
    ///   - properties: The operations this characteristic advertises. Defaults to `[.read]`.
    ///   - permissions: The access permissions gating the value. Defaults to `[.readable]`.
    ///   - value: A cached value for a static (read-only) characteristic, or `nil` (the
    ///     default) for a dynamic characteristic answered on demand.
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
