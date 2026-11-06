//
//  GATTService.swift
//  BLESwiftCore
//

/// A value-type definition of one service in a hosted GATT database.
///
/// Build a service (with its ``GATTCharacteristic`` values) and pass it to
/// `PeripheralHost/add(_:)`. The actor compiles it to a `CBMutableService` (and
/// `CBMutableCharacteristic` values) inside its CoreBluetooth seam, never here.
public struct GATTService: Sendable, Hashable {

    /// The service's identifier.
    public let identifier: ServiceIdentifier

    /// Whether this is a primary service (`true`) or a secondary service that another service
    /// includes (`false`).
    public let isPrimary: Bool

    /// The characteristics this service hosts.
    public let characteristics: [GATTCharacteristic]

    /// Creates a service definition.
    public init(
        identifier: ServiceIdentifier,
        isPrimary: Bool = true,
        characteristics: [GATTCharacteristic] = []
    ) {
        self.identifier = identifier
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }
}
