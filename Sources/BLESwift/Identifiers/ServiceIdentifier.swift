//
//  ServiceIdentifier.swift
//  BLESwift
//

import CoreBluetooth

/// A type-safe identifier for a Bluetooth GATT service.
///
/// Wraps a `CBUUID` as a plain `String` so that CoreBluetooth types do not appear in
/// BLESwift's public API surface; the `CBUUID` bridge is available internally for the
/// CoreBluetooth abstraction layer.
public struct ServiceIdentifier: Sendable, CustomStringConvertible {

    /// The canonical string form of this service's UUID, as produced by
    /// `CBUUID.uuidString`: the short form (e.g. `"180D"`) for well-known 16/32-bit
    /// Bluetooth SIG UUIDs, or the full 128-bit form otherwise.
    public let uuidString: String

    /// Creates a `ServiceIdentifier` from a UUID string.
    ///
    /// Accepts a full 128-bit UUID, or a 16/32-bit shorthand UUID (e.g. `"180D"` for the
    /// Heart Rate service).
    ///
    /// - Parameter uuid: A valid UUID string, as accepted by `CBUUID(string:)`.
    /// - Warning: If `uuid` cannot be converted to a `CBUUID`, this traps, mirroring
    ///   `CBUUID(string:)`'s own behavior.
    public init(uuid: String) {
        self.uuidString = CBUUID(string: uuid).uuidString
    }

    /// Creates a `ServiceIdentifier` from a `CBUUID` (internal CoreBluetooth bridging).
    init(cbuuid: CBUUID) {
        self.uuidString = cbuuid.uuidString
    }

    /// The `CBUUID` representation of this identifier, for internal CoreBluetooth bridging.
    var cbuuid: CBUUID {
        CBUUID(string: uuidString)
    }

    /// A human-readable description of this service identifier.
    public var description: String {
        "Service(\(uuidString))"
    }
}

extension ServiceIdentifier: Hashable {}
