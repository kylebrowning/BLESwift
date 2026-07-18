//
//  DescriptorIdentifier.swift
//  BLESwiftCore
//

/// A type-safe identifier for a Bluetooth GATT characteristic descriptor, scoped to the
/// characteristic it belongs to.
///
/// Descriptors describe a characteristic's value or configure its behavior — the
/// Characteristic User Description, Presentation Format, and vendor-specific descriptors,
/// among others. (The Client Characteristic Configuration descriptor — the notify/indicate
/// toggle — is handled implicitly by BLESwift's notification API and is not addressed
/// through this type.)
///
/// Wraps a normalized UUID string so that CoreBluetooth types never appear in this seam;
/// the `CBUUID` bridge (`init(cbuuid:characteristic:)`/`cbuuid`) lives in the `BLESwift`
/// module, as an extension built on this type's public members — mirroring
/// ``ServiceIdentifier``/``CharacteristicIdentifier``.
public struct DescriptorIdentifier: Sendable, CustomStringConvertible {

    /// The characteristic this descriptor belongs to.
    public let characteristic: CharacteristicIdentifier

    /// The canonical string form of this descriptor's UUID — matching `CBUUID.uuidString`'s
    /// own normalization exactly.
    public let uuidString: String

    /// Creates a `DescriptorIdentifier` from a UUID string and its owning characteristic.
    ///
    /// Accepts a full 128-bit (36-character, dashed) UUID, or a 16/32-bit (4- or
    /// 8-character) shorthand UUID. Hex digits may be upper- or lowercase; the stored form
    /// is always uppercase.
    ///
    /// - Parameters:
    ///   - uuid: A valid UUID string.
    ///   - characteristic: The characteristic this descriptor belongs to.
    /// - Warning: If `uuid` is not a valid 4-, 8-, or 36-character hex UUID string, this
    ///   traps, mirroring `CBUUID(string:)`'s own behavior.
    public init(uuid: String, characteristic: CharacteristicIdentifier) {
        self.uuidString = normalizedUUIDString(uuid)
        self.characteristic = characteristic
    }

    /// A human-readable description including the descriptor, its characteristic, and its
    /// service.
    public var description: String {
        "Descriptor(\(uuidString)), Characteristic(\(characteristic.uuidString)), Service(\(characteristic.service.uuidString))"
    }
}

extension DescriptorIdentifier: Hashable {}
