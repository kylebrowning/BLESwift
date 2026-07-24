//
//  PeripheralIdentifier.swift
//  BLESwiftCore
//

import Foundation

/// Uniquely identifies a peripheral to the current device's CoreBluetooth stack.
///
/// The underlying `UUID` is assigned per device pairing and is **not** the peripheral's
/// hardware address; the same physical peripheral will have a different
/// ``PeripheralIdentifier/uuid`` on different host devices.
public struct PeripheralIdentifier: Sendable, CustomStringConvertible {

    /// The UUID CoreBluetooth uses to identify this peripheral on the current device.
    public let uuid: UUID

    /// The peripheral's advertised or cached name, or `"No Name"` if none was provided.
    public let name: String

    /// Creates a `PeripheralIdentifier`. `name` defaults to `"No Name"` when `nil`.
    public init(uuid: UUID, name: String?) {
        self.uuid = uuid
        self.name = name ?? "No Name"
    }

    /// A human-readable description combining the name and UUID.
    public var description: String {
        "Peripheral(\(name), \(uuid))"
    }
}

extension PeripheralIdentifier: Hashable {
    /// Two `PeripheralIdentifier`s are equal when their UUIDs match, regardless of
    /// (possibly stale) cached name.
    public static func == (lhs: PeripheralIdentifier, rhs: PeripheralIdentifier) -> Bool {
        lhs.uuid == rhs.uuid
    }

    /// Hashes only the UUID, consistent with the identity-based `==` above.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
    }
}
