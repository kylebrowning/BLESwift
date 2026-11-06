//
//  ServiceIdentifier.swift
//  BLESwiftCore
//

/// A type-safe identifier for a Bluetooth GATT service.
///
/// It wraps a normalized UUID string, so CoreBluetooth types never appear in this seam. The
/// `CBUUID` bridge (`init(cbuuid:)` and `cbuuid`) is an extension in the `BLESwift` module that
/// uses this type's public members.
public struct ServiceIdentifier: Sendable, CustomStringConvertible {

    /// The canonical string form of this service's UUID. It is the short form for a 16/32-bit
    /// Bluetooth SIG UUID (for example `"180D"`), and the full 128-bit form with dashes for any
    /// other UUID. It matches the normalization of `CBUUID.uuidString` exactly.
    public let uuidString: String

    /// Creates a `ServiceIdentifier` from a UUID string.
    ///
    /// It accepts a full 128-bit UUID (36 characters, with dashes) or a 16/32-bit shorthand UUID (4
    /// or 8 characters), such as `"180D"` for the Heart Rate service. Hex digits can be uppercase
    /// or lowercase. The stored form is always uppercase.
    ///
    /// - Parameter uuid: A valid UUID string.
    /// - Warning: If `uuid` is not a valid hex UUID string of 4, 8, or 36 characters, this
    ///   initializer traps. `CBUUID(string:)` does the same.
    public init(uuid: String) {
        self.uuidString = normalizedUUIDString(uuid)
    }

    /// A human-readable description of this service identifier.
    public var description: String {
        "Service(\(uuidString))"
    }
}

extension ServiceIdentifier: Hashable {}
