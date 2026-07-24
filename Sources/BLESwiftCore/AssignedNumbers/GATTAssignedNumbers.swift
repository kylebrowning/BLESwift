//
//  GATTAssignedNumbers.swift
//  BLESwiftCore
//

/// A read-only lookup of the Bluetooth SIG's *assigned numbers* — the human-readable names
/// for standard GATT services, characteristics, and descriptors (e.g. `"180D"` →
/// `"Heart Rate"`).
///
/// Both 16-bit and 128-bit forms of a SIG UUID resolve to the same name. Tables are
/// generated from the Bluetooth SIG's dataset (see `Scripts/generate-assigned-numbers.md`),
/// plus a small set of vendor UUIDs with no 16-bit form. An unrecognized UUID returns `nil`.
///
/// - Note: Reference data for display only — it names an attribute, not its value layout.
public enum GATTAssignedNumbers {

    // MARK: - Services

    /// The human-readable name of a standard Bluetooth service, if one is assigned.
    ///
    /// - Parameter service: The service to name.
    /// - Returns: The SIG-assigned (or well-known vendor) name, or `nil` if the UUID is not a
    ///   recognized assigned number.
    public static func name(for service: ServiceIdentifier) -> String? {
        name(forNormalizedUUID: service.uuidString, in: serviceNames, vendor: vendorServiceNames)
    }

    // MARK: - Characteristics

    /// The human-readable name of a standard Bluetooth characteristic, if one is assigned.
    ///
    /// - Parameter characteristic: The characteristic to name.
    /// - Returns: The SIG-assigned (or well-known vendor) name, or `nil` if the UUID is not a
    ///   recognized assigned number.
    public static func name(for characteristic: CharacteristicIdentifier) -> String? {
        name(
            forNormalizedUUID: characteristic.uuidString,
            in: characteristicNames,
            vendor: vendorCharacteristicNames
        )
    }

    // MARK: - Descriptors

    /// The human-readable name of a standard Bluetooth characteristic descriptor, if one is
    /// assigned.
    ///
    /// - Parameter descriptor: The descriptor to name.
    /// - Returns: The SIG-assigned name, or `nil` if the UUID is not a recognized assigned
    ///   number.
    public static func name(for descriptor: DescriptorIdentifier) -> String? {
        name(forNormalizedUUID: descriptor.uuidString, in: descriptorNames, vendor: [:])
    }

    // MARK: - Lookup

    /// Resolves a name from a normalized UUID string, trying the 16-bit SIG table first and
    /// the full-UUID vendor table second.
    private static func name(
        forNormalizedUUID uuid: String,
        in sig: [UInt16: String],
        vendor: [String: String]
    ) -> String? {
        if let assigned = assignedNumber(forNormalizedUUID: uuid), let name = sig[assigned] {
            return name
        }
        return vendor[uuid]
    }

    /// Extracts the 16-bit Bluetooth SIG assigned number from an already-normalized UUID
    /// string (4-char shorthand, zero-high 8-char shorthand, or full Bluetooth Base UUID),
    /// or `nil` if the UUID is not a SIG short UUID.
    static func assignedNumber(forNormalizedUUID uuid: String) -> UInt16? {
        switch uuid.count {
        case 4:
            return UInt16(uuid, radix: 16)

        case 8:
            guard uuid.hasPrefix("0000") else { return nil }
            return UInt16(uuid.suffix(4), radix: 16)

        case 36:
            // The Bluetooth Base UUID, minus its leading 16-bit field.
            guard
                uuid.hasPrefix("0000"),
                uuid.hasSuffix("-0000-1000-8000-00805F9B34FB")
            else { return nil }
            let start = uuid.index(uuid.startIndex, offsetBy: 4)
            let end = uuid.index(uuid.startIndex, offsetBy: 8)
            return UInt16(uuid[start..<end], radix: 16)

        default:
            return nil
        }
    }
}
