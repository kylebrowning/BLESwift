//
//  ServiceIdentifier.swift
//  BLESwiftCore
//

/// A type-safe identifier for a Bluetooth GATT service.
///
/// Wraps a normalized UUID string so that CoreBluetooth types never appear in this seam;
/// the `CBUUID` bridge (`init(cbuuid:)`/`cbuuid`) lives in the `BLESwift` module, as an
/// extension built on this type's public members.
public struct ServiceIdentifier: Sendable, CustomStringConvertible {

    /// The canonical string form of this service's UUID: the short form (e.g. `"180D"`)
    /// for well-known 16/32-bit Bluetooth SIG UUIDs, or the full 128-bit dashed form
    /// otherwise — matching `CBUUID.uuidString`'s own normalization exactly.
    public let uuidString: String

    /// Creates a `ServiceIdentifier` from a UUID string.
    ///
    /// Accepts a full 128-bit (36-character, dashed) UUID, or a 16/32-bit (4- or
    /// 8-character) shorthand UUID (e.g. `"180D"` for the Heart Rate service). Hex digits
    /// may be upper- or lowercase; the stored form is always uppercase.
    ///
    /// - Parameter uuid: A valid UUID string.
    /// - Warning: If `uuid` is not a valid 4-, 8-, or 36-character hex UUID string, this
    ///   traps, mirroring `CBUUID(string:)`'s own behavior.
    public init(uuid: String) {
        self.uuidString = normalizedUUIDString(uuid)
    }

    /// A human-readable description of this service identifier.
    public var description: String {
        "Service(\(uuidString))"
    }
}

extension ServiceIdentifier: Hashable {}
