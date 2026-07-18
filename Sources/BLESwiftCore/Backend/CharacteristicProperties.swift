//
//  CharacteristicProperties.swift
//  BLESwiftCore
//

/// The set of operations a GATT characteristic advertises support for — read, write,
/// notify, and so on.
///
/// A `Sendable` `OptionSet` mirroring `CBCharacteristicProperties`, letting callers ask
/// "is this characteristic writable / notifiable / readable?" before attempting an
/// operation, rather than discovering capabilities via errors.
///
/// BLESwift-owned; the backend's native `CBCharacteristicProperties` mapping lives in the
/// `BLESwift` module (see `CharacteristicProperties+CB.swift`) — this type never exposes a
/// CoreBluetooth type in its own public API. Its bit layout is BLESwift's own and is not
/// guaranteed to match `CBCharacteristicProperties`'s raw values; always construct it from
/// named members, never from a CoreBluetooth raw value.
public struct CharacteristicProperties: OptionSet, Sendable, Hashable {

    /// The raw bitmask backing this option set. BLESwift-owned — not
    /// `CBCharacteristicProperties`'s raw value.
    public let rawValue: UInt

    /// Creates a `CharacteristicProperties` from a raw bitmask of its own members.
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The characteristic's value can be read. Mirrors `CBCharacteristicProperties.read`.
    public static let read = CharacteristicProperties(rawValue: 1 << 0)

    /// The characteristic's value can be written with a response. Mirrors
    /// `CBCharacteristicProperties.write`.
    public static let write = CharacteristicProperties(rawValue: 1 << 1)

    /// The characteristic's value can be written without a response. Mirrors
    /// `CBCharacteristicProperties.writeWithoutResponse`.
    public static let writeWithoutResponse = CharacteristicProperties(rawValue: 1 << 2)

    /// The characteristic supports notifications (value updates without acknowledgement).
    /// Mirrors `CBCharacteristicProperties.notify`.
    public static let notify = CharacteristicProperties(rawValue: 1 << 3)

    /// The characteristic supports indications (value updates *with* acknowledgement).
    /// Mirrors `CBCharacteristicProperties.indicate`.
    public static let indicate = CharacteristicProperties(rawValue: 1 << 4)

    /// The characteristic supports signed writes without a response. Mirrors
    /// `CBCharacteristicProperties.authenticatedSignedWrites`.
    public static let authenticatedSignedWrites = CharacteristicProperties(rawValue: 1 << 5)

    /// The characteristic has an Extended Properties descriptor. Mirrors
    /// `CBCharacteristicProperties.extendedProperties`.
    public static let extendedProperties = CharacteristicProperties(rawValue: 1 << 6)

    /// The characteristic's value can be broadcast using a Server Characteristic
    /// Configuration descriptor. Mirrors `CBCharacteristicProperties.broadcast`.
    public static let broadcast = CharacteristicProperties(rawValue: 1 << 7)
}
