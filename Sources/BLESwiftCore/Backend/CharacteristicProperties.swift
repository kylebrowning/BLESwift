//
//  CharacteristicProperties.swift
//  BLESwiftCore
//

/// The operations that a GATT characteristic supports, such as read, write, and notify. A
/// `Sendable` `OptionSet` that mirrors `CBCharacteristicProperties`.
///
/// The bit layout is BLESwift's own and can differ from `CBCharacteristicProperties`' raw values.
/// Always construct this type from named members.
public struct CharacteristicProperties: OptionSet, Sendable, Hashable {

    /// The raw bitmask of this option set. It is BLESwift's own, not `CBCharacteristicProperties`'
    /// raw value.
    public let rawValue: UInt

    /// Creates a `CharacteristicProperties` from a raw bitmask of its own members.
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// A client can read the characteristic's value. Mirrors
    /// `CBCharacteristicProperties.read`.
    public static let read = CharacteristicProperties(rawValue: 1 << 0)

    /// A client can write the characteristic's value with a response. Mirrors
    /// `CBCharacteristicProperties.write`.
    public static let write = CharacteristicProperties(rawValue: 1 << 1)

    /// A client can write the characteristic's value without a response. Mirrors
    /// `CBCharacteristicProperties.writeWithoutResponse`.
    public static let writeWithoutResponse = CharacteristicProperties(rawValue: 1 << 2)

    /// The characteristic supports notifications (value updates without acknowledgement). Mirrors
    /// `CBCharacteristicProperties.notify`.
    public static let notify = CharacteristicProperties(rawValue: 1 << 3)

    /// The characteristic supports indications (value updates *with* acknowledgement). Mirrors
    /// `CBCharacteristicProperties.indicate`.
    public static let indicate = CharacteristicProperties(rawValue: 1 << 4)

    /// The characteristic supports signed writes without a response. Mirrors
    /// `CBCharacteristicProperties.authenticatedSignedWrites`.
    public static let authenticatedSignedWrites = CharacteristicProperties(rawValue: 1 << 5)

    /// The characteristic has an Extended Properties descriptor. Mirrors
    /// `CBCharacteristicProperties.extendedProperties`.
    public static let extendedProperties = CharacteristicProperties(rawValue: 1 << 6)

    /// A server can broadcast the characteristic's value, using a Server Characteristic
    /// Configuration descriptor. Mirrors `CBCharacteristicProperties.broadcast`.
    public static let broadcast = CharacteristicProperties(rawValue: 1 << 7)
}
