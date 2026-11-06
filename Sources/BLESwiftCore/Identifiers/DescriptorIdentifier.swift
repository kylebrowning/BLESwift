//
//  DescriptorIdentifier.swift
//  BLESwiftCore
//

/// A type-safe identifier for a Bluetooth GATT characteristic descriptor. Its scope is the
/// characteristic that the descriptor belongs to.
///
/// BLESwift's notification API handles the Client Characteristic Configuration descriptor (the
/// notify and indicate toggle) implicitly, so you do not address it through this type. This type
/// wraps a normalized UUID string, so CoreBluetooth types never appear in this seam.
public struct DescriptorIdentifier: Sendable, CustomStringConvertible {

    /// The characteristic that this descriptor belongs to.
    public let characteristic: CharacteristicIdentifier

    /// The canonical string form of this descriptor's UUID. It matches the normalization of
    /// `CBUUID.uuidString` exactly.
    public let uuidString: String

    /// Creates a `DescriptorIdentifier` from a UUID string and its owning characteristic.
    ///
    /// It accepts a full 128-bit UUID (36 characters, with dashes) or a 16/32-bit shorthand UUID (4
    /// or 8 characters). Hex digits can be uppercase or lowercase. The stored form is always
    /// uppercase.
    ///
    /// - Warning: If `uuid` is not a valid hex UUID string of 4, 8, or 36 characters, this
    ///   initializer traps. `CBUUID(string:)` does the same.
    public init(uuid: String, characteristic: CharacteristicIdentifier) {
        self.uuidString = normalizedUUIDString(uuid)
        self.characteristic = characteristic
    }

    /// A human-readable description that includes the descriptor, its characteristic, and its
    /// service.
    public var description: String {
        "Descriptor(\(uuidString)), Characteristic(\(characteristic.uuidString)), Service(\(characteristic.service.uuidString))"
    }
}

extension DescriptorIdentifier: Hashable {}
