//
//  CharacteristicIdentifier.swift
//  BLESwift
//

import CoreBluetooth

/// A type-safe identifier for a Bluetooth GATT characteristic, scoped to the service it
/// belongs to.
///
/// Wraps a `CBUUID` as a plain `String` so that CoreBluetooth types do not appear in
/// BLESwift's public API surface; the `CBUUID` bridge is available internally for the
/// CoreBluetooth abstraction layer.
public struct CharacteristicIdentifier: Sendable, CustomStringConvertible {

    /// The service this characteristic belongs to.
    public let service: ServiceIdentifier

    /// The canonical string form of this characteristic's UUID, as produced by
    /// `CBUUID.uuidString`.
    public let uuidString: String

    /// Creates a `CharacteristicIdentifier` from a UUID string and its owning service.
    ///
    /// Accepts a full 128-bit UUID, or a 16/32-bit shorthand UUID.
    ///
    /// - Parameters:
    ///   - uuid: A valid UUID string, as accepted by `CBUUID(string:)`.
    ///   - service: The service this characteristic belongs to.
    /// - Warning: If `uuid` cannot be converted to a `CBUUID`, this traps, mirroring
    ///   `CBUUID(string:)`'s own behavior.
    public init(uuid: String, service: ServiceIdentifier) {
        self.uuidString = CBUUID(string: uuid).uuidString
        self.service = service
    }

    /// Creates a `CharacteristicIdentifier` from a `CBUUID` and its owning service
    /// (internal CoreBluetooth bridging).
    init(cbuuid: CBUUID, service: ServiceIdentifier) {
        self.uuidString = cbuuid.uuidString
        self.service = service
    }

    /// The `CBUUID` representation of this identifier, for internal CoreBluetooth bridging.
    var cbuuid: CBUUID {
        CBUUID(string: uuidString)
    }

    /// A human-readable description including both the characteristic and its service.
    public var description: String {
        "Characteristic(\(uuidString)), Service(\(service.uuidString))"
    }
}

extension CharacteristicIdentifier: Hashable {}
