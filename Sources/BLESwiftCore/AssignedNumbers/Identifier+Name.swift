//
//  Identifier+Name.swift
//  BLESwiftCore
//

// Convenience accessors that delegate to ``GATTAssignedNumbers``. They are shorthand for the
// `GATTAssignedNumbers.name(for:)` lookup and do not change identifier equality, hashing, or
// storage.

extension ServiceIdentifier {

    /// The human-readable Bluetooth SIG (or well-known vendor) name of this service, if one is
    /// assigned. Otherwise `nil`. A convenience for
    /// ``GATTAssignedNumbers/name(for:)-(ServiceIdentifier)``.
    public var name: String? {
        GATTAssignedNumbers.name(for: self)
    }
}

extension CharacteristicIdentifier {

    /// The human-readable Bluetooth SIG (or well-known vendor) name of this characteristic, if one
    /// is assigned. Otherwise `nil`. A convenience for
    /// ``GATTAssignedNumbers/name(for:)-(CharacteristicIdentifier)``.
    public var name: String? {
        GATTAssignedNumbers.name(for: self)
    }
}

extension DescriptorIdentifier {

    /// The human-readable Bluetooth SIG name of this descriptor, if one is assigned. Otherwise
    /// `nil`. A convenience for ``GATTAssignedNumbers/name(for:)-(DescriptorIdentifier)``.
    public var name: String? {
        GATTAssignedNumbers.name(for: self)
    }
}
