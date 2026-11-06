//
//  CharacteristicIdentifier.swift
//  BLESwiftCore
//

/// A type-safe identifier for a Bluetooth GATT characteristic. Its scope is the service that the
/// characteristic belongs to.
///
/// It wraps a normalized UUID string, so CoreBluetooth types never appear in this seam. The
/// `CBUUID` bridge (`init(cbuuid:service:)` and `cbuuid`) is an extension in the `BLESwift` module
/// that uses this type's public members.
public struct CharacteristicIdentifier: Sendable, CustomStringConvertible {

    /// The service that this characteristic belongs to.
    public let service: ServiceIdentifier

    /// The canonical string form of this characteristic's UUID. It matches the normalization of
    /// `CBUUID.uuidString` exactly.
    public let uuidString: String

    /// Creates a `CharacteristicIdentifier` from a UUID string and its owning service.
    ///
    /// It accepts a full 128-bit UUID (36 characters, with dashes) or a 16/32-bit shorthand UUID (4
    /// or 8 characters). Hex digits can be uppercase or lowercase. The stored form is always
    /// uppercase.
    ///
    /// - Warning: If `uuid` is not a valid hex UUID string of 4, 8, or 36 characters, this
    ///   initializer traps. `CBUUID(string:)` does the same.
    public init(uuid: String, service: ServiceIdentifier) {
        self.uuidString = normalizedUUIDString(uuid)
        self.service = service
    }

    /// A human-readable description that includes the characteristic and its service.
    public var description: String {
        "Characteristic(\(uuidString)), Service(\(service.uuidString))"
    }
}

extension CharacteristicIdentifier: Hashable {}
