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

    /// The peripheral's advertised or cached name exactly as CoreBluetooth reported it, or
    /// `nil` when the peripheral has none. Use this, not ``name``, to tell unnamed peripherals
    /// apart from named ones.
    public let cachedName: String?

    /// A display name: ``cachedName``, or `"No Name"` when the peripheral has none.
    public var name: String {
        cachedName ?? "No Name"
    }

    /// Creates a `PeripheralIdentifier`. `name` is kept as-is in ``cachedName``.
    public init(uuid: UUID, name: String?) {
        self.uuid = uuid
        self.cachedName = name
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
