//
//  AttributePermissions.swift
//  BLESwiftCore
//

/// The read/write access permissions of a hosted characteristic (or its descriptors) —
/// distinct from ``CharacteristicProperties`` (which advertises *what operations exist*);
/// permissions gate *who may perform them* and whether an encrypted link is required.
///
/// A `Sendable`, value-type mirror of CoreBluetooth's `CBAttributePermissions` option set.
/// The raw values match `CBAttributePermissions`' exactly, so the `BLESwift` module bridges
/// the two by raw value at the CoreBluetooth seam.
public struct AttributePermissions: OptionSet, Sendable, Hashable {

    /// The raw bitmask, matching `CBAttributePermissions.rawValue`.
    public let rawValue: UInt

    /// Creates a permission set from a raw bitmask.
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The attribute's value can be read.
    public static let readable = AttributePermissions(rawValue: 0x01)
    /// The attribute's value can be written.
    public static let writeable = AttributePermissions(rawValue: 0x02)
    /// The attribute's value can only be read on an encrypted link.
    public static let readEncryptionRequired = AttributePermissions(rawValue: 0x04)
    /// The attribute's value can only be written on an encrypted link.
    public static let writeEncryptionRequired = AttributePermissions(rawValue: 0x08)
}
