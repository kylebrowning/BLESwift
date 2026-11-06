//
//  PeripheralIdentifier.swift
//  BLESwiftCore
//

import Foundation

/// Identifies a peripheral to the current device's CoreBluetooth stack. The identifier is unique.
///
/// The underlying `UUID` is assigned for each device pairing. It is **not** the peripheral's
/// hardware address. The same physical peripheral has a different ``PeripheralIdentifier/uuid`` on
/// different host devices.
public struct PeripheralIdentifier: Sendable, CustomStringConvertible {

    /// The UUID that CoreBluetooth uses to identify this peripheral on the current device.
    public let uuid: UUID

    /// The peripheral's advertised or cached name, exactly as CoreBluetooth reported it. It is
    /// `nil` when the peripheral has no name. Use this property, and not ``name``, to tell unnamed
    /// peripherals from named ones.
    public let cachedName: String?

    /// A display name. It is ``cachedName``, or `"No Name"` when the peripheral has no name.
    public var name: String {
        cachedName ?? "No Name"
    }

    /// Creates a `PeripheralIdentifier`. ``cachedName`` keeps `name` unchanged, including `nil`.
    public init(uuid: UUID, name: String?) {
        self.uuid = uuid
        self.cachedName = name
    }

    /// A human-readable description with the name and the UUID.
    public var description: String {
        "Peripheral(\(name), \(uuid))"
    }
}

extension PeripheralIdentifier: Hashable {
    /// Two `PeripheralIdentifier` values are equal when their UUIDs match. The cached name, which
    /// can be stale, has no effect.
    public static func == (lhs: PeripheralIdentifier, rhs: PeripheralIdentifier) -> Bool {
        lhs.uuid == rhs.uuid
    }

    /// Hashes only the UUID, consistent with `==`.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
    }
}
