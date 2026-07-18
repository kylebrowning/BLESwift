//
//  Identifier+Name.swift
//  BLESwiftCore
//

// Lightweight, additive convenience accessors delegating to ``GATTAssignedNumbers``. These
// change nothing about identifier equality, hashing, or storage — they only offer a shorter
// spelling of the corresponding `GATTAssignedNumbers.name(for:)` lookup.

extension ServiceIdentifier {

    /// The human-readable Bluetooth SIG (or well-known vendor) name of this service, if one
    /// is assigned; otherwise `nil`.
    ///
    /// A convenience for ``GATTAssignedNumbers/name(for:)-(ServiceIdentifier)``.
    public var name: String? {
        GATTAssignedNumbers.name(for: self)
    }
}

extension CharacteristicIdentifier {

    /// The human-readable Bluetooth SIG (or well-known vendor) name of this characteristic,
    /// if one is assigned; otherwise `nil`.
    ///
    /// A convenience for ``GATTAssignedNumbers/name(for:)-(CharacteristicIdentifier)``.
    public var name: String? {
        GATTAssignedNumbers.name(for: self)
    }
}

extension DescriptorIdentifier {

    /// The human-readable Bluetooth SIG name of this descriptor, if one is assigned;
    /// otherwise `nil`.
    ///
    /// A convenience for ``GATTAssignedNumbers/name(for:)-(DescriptorIdentifier)``.
    public var name: String? {
        GATTAssignedNumbers.name(for: self)
    }
}
