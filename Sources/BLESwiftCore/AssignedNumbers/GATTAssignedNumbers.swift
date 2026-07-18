//
//  GATTAssignedNumbers.swift
//  BLESwiftCore
//

/// A read-only lookup of the Bluetooth SIG's *assigned numbers* — the human-readable names
/// for standard GATT services, characteristics, and descriptors.
///
/// BLESwift speaks purely in UUIDs. This namespace pairs with the GATT enumeration API so a
/// browser (or a log line, or a capability-driven UI) can turn an otherwise opaque
/// ``ServiceIdentifier``/``CharacteristicIdentifier``/``DescriptorIdentifier`` into a name a
/// human can read — `"180D"` becomes `"Heart Rate"`, `"2A37"` becomes
/// `"Heart Rate Measurement"`, `"2902"` becomes `"Client Characteristic Configuration"`.
///
/// ```swift
/// let heartRate = ServiceIdentifier(uuid: "180D")
/// GATTAssignedNumbers.name(for: heartRate)   // "Heart Rate"
/// heartRate.name                             // "Heart Rate" (convenience accessor)
/// ```
///
/// ## 16-bit and 128-bit both resolve
///
/// 16-bit SIG UUIDs are the common case, but a peripheral may report a well-known attribute
/// as its full 128-bit form. Any UUID that is really a SIG short UUID — i.e. one matching the
/// Bluetooth Base UUID `0000XXXX-0000-1000-8000-00805F9B34FB` — resolves to the same name as
/// its 16-bit shorthand. A `"0000180D-…"` and a `"180D"` both name `"Heart Rate"`.
///
/// ## Coverage
///
/// The tables are generated from the Bluetooth SIG's public *assigned numbers* dataset (see
/// `Scripts/generate-assigned-numbers.md` for the source and regeneration procedure), plus a
/// small set of widely-deployed vendor UUIDs that have no 16-bit form (e.g. the Nordic UART
/// Service). A UUID with no known name returns `nil` — an unknown or vendor-private attribute
/// is never an error.
///
/// - Note: This is reference data for *display*. It is not a GATT field parser: it names an
///   attribute, it does not describe the layout of its value.
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

    /// Extracts the 16-bit Bluetooth SIG assigned number from an already-normalized
    /// (uppercase, canonically-shaped) UUID string, or `nil` if the UUID is not a SIG short
    /// UUID.
    ///
    /// Recognizes all three normalized shapes ``ServiceIdentifier`` and friends can store:
    /// - a 4-character 16-bit shorthand (`"180D"`) — the value itself;
    /// - an 8-character 32-bit shorthand whose high half is zero (`"0000180D"`) — the low
    ///   half (a genuine non-zero-high 32-bit UUID has no 16-bit assigned number and yields
    ///   `nil`);
    /// - a 36-character 128-bit UUID matching the Bluetooth Base UUID
    ///   `0000XXXX-0000-1000-8000-00805F9B34FB` — the `XXXX` field.
    ///
    /// - Parameter uuid: A normalized UUID string, as stored by the identifier types.
    /// - Returns: The 16-bit assigned number, or `nil` if `uuid` is not a SIG short UUID.
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
