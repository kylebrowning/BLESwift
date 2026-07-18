//
//  GATTService.swift
//  BLESwiftCore
//

/// A value-type definition of one service in a hosted GATT database.
///
/// Build a service (with its ``GATTCharacteristic``s) and hand it to
/// `PeripheralHost/add(_:)`; it is compiled to a `CBMutableService` (and
/// `CBMutableCharacteristic`s) **inside the actor's CoreBluetooth seam**, never here.
public struct GATTService: Sendable, Hashable {

    /// The service's identifier.
    public let identifier: ServiceIdentifier

    /// Whether this is a primary service (`true`) or a secondary service included by
    /// another (`false`).
    public let isPrimary: Bool

    /// The characteristics this service hosts.
    public let characteristics: [GATTCharacteristic]

    /// Creates a service definition.
    ///
    /// - Parameters:
    ///   - identifier: The service's identifier.
    ///   - isPrimary: Whether this is a primary service. Defaults to `true`.
    ///   - characteristics: The characteristics this service hosts. Defaults to `[]`.
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
