//
//  CharacteristicIdentifier.swift
//  BLESwiftCore
//

/// A type-safe identifier for a Bluetooth GATT characteristic, scoped to the service it
/// belongs to.
///
/// Wraps a normalized UUID string so that CoreBluetooth types never appear in this seam;
/// the `CBUUID` bridge (`init(cbuuid:service:)`/`cbuuid`) lives in the `BLESwift` module,
/// as an extension built on this type's public members.
public struct CharacteristicIdentifier: Sendable, CustomStringConvertible {

    /// The service this characteristic belongs to.
    public let service: ServiceIdentifier

    /// The canonical string form of this characteristic's UUID — matching
    /// `CBUUID.uuidString`'s own normalization exactly.
    public let uuidString: String

    /// Creates a `CharacteristicIdentifier` from a UUID string and its owning service.
    ///
    /// Accepts a full 128-bit (36-character, dashed) UUID, or a 16/32-bit (4- or
    /// 8-character) shorthand UUID. Hex digits may be upper- or lowercase; the stored form
    /// is always uppercase.
    ///
    /// - Parameters:
    ///   - uuid: A valid UUID string.
    ///   - service: The service this characteristic belongs to.
    /// - Warning: If `uuid` is not a valid 4-, 8-, or 36-character hex UUID string, this
    ///   traps, mirroring `CBUUID(string:)`'s own behavior.
    public init(uuid: String, service: ServiceIdentifier) {
        self.uuidString = normalizedUUIDString(uuid)
        self.service = service
    }

    /// A human-readable description including both the characteristic and its service.
    public var description: String {
        "Characteristic(\(uuidString)), Service(\(service.uuidString))"
    }
}

extension CharacteristicIdentifier: Hashable {}
