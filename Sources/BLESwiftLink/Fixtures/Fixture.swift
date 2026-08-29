//
//  Fixture.swift
//  BLESwiftLink
//

import BLESwiftCore
import Foundation

/// A declarative document describing one or more virtual BLE devices, loaded by the
/// host-side simulator provider via `--fixture`.
///
/// The JSON shape mirrors ``FixtureDevice``, ``FixtureService``, and
/// ``FixtureCharacteristic`` directly; there is no separate wire format.
public struct FixtureDocument: Codable, Sendable, Equatable {

    /// The virtual devices this fixture describes.
    public var devices: [FixtureDevice]

    /// Creates a fixture document from its devices.
    public init(devices: [FixtureDevice]) {
        self.devices = devices
    }

    /// Reads and parses a fixture document from a JSON file on disk.
    ///
    /// - Parameter url: The file URL of the fixture's JSON document.
    /// - Throws: An error if the file cannot be read, or if its contents are not a valid
    ///   fixture document (see ``parse(_:)``).
    public static func load(from url: URL) throws -> FixtureDocument {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    /// Parses a fixture document from JSON data.
    ///
    /// - Parameter data: The document's JSON bytes.
    /// - Throws: `DecodingError` if `data` is not a valid fixture document — including an
    ///   unrecognized ``FixtureProperty`` or ``FixturePermission`` case name, or a UUID
    ///   string BLESwift's identifiers could not hold.
    public static func parse(_ data: Data) throws -> FixtureDocument {
        try JSONDecoder().decode(FixtureDocument.self, from: data)
    }
}

/// Rejects a fixture UUID string BLESwift's identifiers could not hold.
///
/// `ServiceIdentifier` and `CharacteristicIdentifier` **trap** on a string they cannot
/// normalize, so a typo in a hand-written fixture — `"zzzz"` where `"180D"` was meant — would
/// take `bleswift-provider` down at load rather than telling its author what is wrong. Every
/// UUID a fixture carries is therefore checked while decoding, against the same rule the wire
/// boundary applies (``WireIdentifierValidation``), and a bad one becomes a `DecodingError`
/// naming the key it sits under — which the CLI prints before exiting `66`.
///
/// - Parameters:
///   - uuid: The candidate UUID string, as written in the fixture.
///   - key: The key `uuid` was decoded from, for the error's coding path.
///   - container: The container `key` belongs to, for the error's coding path.
///   - index: The element's position, when `key` holds an array of UUID strings.
/// - Throws: `DecodingError.dataCorrupted` if `uuid` is not a UUID string BLESwift accepts.
private func validateFixtureUUID<Key: CodingKey>(
    _ uuid: String,
    forKey key: Key,
    in container: KeyedDecodingContainer<Key>,
    index: Int? = nil
) throws {
    guard !WireIdentifierValidation.isValid(uuid) else { return }
    let position = index.map { " at index \($0)" } ?? ""
    throw DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: """
            "\(uuid)"\(position) is not a BLE UUID: expected 4 or 8 hex digits, or a dashed \
            36-character UUID (for example "180D" or "6BA7B810-9DAD-11D1-80B4-00C04FD430C8").
            """
    )
}

/// One virtual peripheral described by a ``FixtureDocument``: its advertisement and the
/// GATT database it hosts.
public struct FixtureDevice: Codable, Sendable, Equatable {

    /// A stable identifier for this virtual device, distinct from any GATT identifier.
    public var id: UUID

    /// The device's advertised local name, mirrored into ``advertisement``'s `localName`.
    public var name: String?

    /// The service UUIDs to advertise, mirrored into ``advertisement``'s `serviceUUIDs`.
    public var advertisedServices: [String]

    /// Manufacturer-specific advertisement data, base64-encoded in the fixture's JSON.
    public var manufacturerData: Data?

    /// The GATT services this device hosts, mirrored into ``gattServices``.
    public var services: [FixtureService]

    /// Creates a fixture device.
    public init(
        id: UUID,
        name: String? = nil,
        advertisedServices: [String] = [],
        manufacturerData: Data? = nil,
        services: [FixtureService] = []
    ) {
        self.id = id
        self.name = name
        self.advertisedServices = advertisedServices
        self.manufacturerData = manufacturerData
        self.services = services
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, advertisedServices, manufacturerData, services
    }

    /// Decodes a fixture device, rejecting an ``advertisedServices`` entry BLESwift's
    /// identifiers could not hold rather than trapping on it later in ``advertisement``.
    ///
    /// Only `id` is required. An absent ``advertisedServices`` or ``services`` decodes as
    /// empty, matching this type's memberwise defaults, so the smallest device a fixture can
    /// describe is `{ "id": "…" }`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        advertisedServices = try container.decodeIfPresent([String].self, forKey: .advertisedServices) ?? []
        for (index, uuid) in advertisedServices.enumerated() {
            try validateFixtureUUID(uuid, forKey: .advertisedServices, in: container, index: index)
        }
        manufacturerData = try container.decodeIfPresent(Data.self, forKey: .manufacturerData)
        services = try container.decodeIfPresent([FixtureService].self, forKey: .services) ?? []
    }

    /// Encodes a fixture device, in the shape ``init(from:)`` reads.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(advertisedServices, forKey: .advertisedServices)
        try container.encodeIfPresent(manufacturerData, forKey: .manufacturerData)
        try container.encode(services, forKey: .services)
    }

    /// This device's advertisement, derived from ``name``, ``advertisedServices``, and
    /// ``manufacturerData``. Always advertises as connectable; every other
    /// `AdvertisementData` field is left `nil`.
    public var advertisement: AdvertisementData {
        AdvertisementData(
            localName: name,
            serviceUUIDs: advertisedServices.map(ServiceIdentifier.init(uuid:)),
            manufacturerData: manufacturerData,
            isConnectable: true
        )
    }

    /// This device's GATT services, derived from ``services``.
    public var gattServices: [GATTService] {
        services.map(\.gattService)
    }
}

/// One GATT service described by a ``FixtureDevice``.
public struct FixtureService: Codable, Sendable, Equatable {

    /// The service's UUID, as a full 128-bit or 16/32-bit shorthand string.
    public var uuid: String

    /// Whether this is a primary service. Defaults to `true` when absent from the JSON.
    public var isPrimary: Bool

    /// The characteristics this service hosts.
    public var characteristics: [FixtureCharacteristic]

    /// Creates a fixture service.
    public init(uuid: String, isPrimary: Bool = true, characteristics: [FixtureCharacteristic] = []) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, isPrimary, characteristics
    }

    /// Decodes a fixture service, rejecting a ``uuid`` BLESwift's identifiers could not hold
    /// rather than trapping on it later in ``gattService``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        try validateFixtureUUID(uuid, forKey: .uuid, in: container)
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? true
        characteristics = try container.decode([FixtureCharacteristic].self, forKey: .characteristics)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(characteristics, forKey: .characteristics)
    }

    /// This service, converted to a `GATTService`.
    public var gattService: GATTService {
        let identifier = ServiceIdentifier(uuid: uuid)
        return GATTService(
            identifier: identifier,
            isPrimary: isPrimary,
            characteristics: characteristics.map { $0.gattCharacteristic(service: identifier) }
        )
    }
}

/// One GATT characteristic described by a ``FixtureService``.
public struct FixtureCharacteristic: Codable, Sendable, Equatable {

    /// The characteristic's UUID, as a full 128-bit or 16/32-bit shorthand string.
    public var uuid: String

    /// The operations this characteristic advertises support for.
    public var properties: [FixtureProperty]

    /// The access permissions gating this characteristic's value.
    ///
    /// When absent from the JSON, permissions are derived from ``properties`` at decode
    /// time (`readable` if `read`, `notify`, or `indicate` is present; `writeable` if
    /// `write` or `writeWithoutResponse` is present) and stored back into this property, so
    /// a decoded characteristic's `permissions` always reflects what was actually applied.
    public var permissions: [FixturePermission]?

    /// The characteristic's cached value, base64-encoded in the fixture's JSON. `nil` makes
    /// this a dynamic characteristic whose value is served on demand.
    public var value: Data?

    /// Creates a fixture characteristic.
    public init(
        uuid: String,
        properties: [FixtureProperty] = [],
        permissions: [FixturePermission]? = nil,
        value: Data? = nil
    ) {
        self.uuid = uuid
        self.properties = properties
        self.permissions = permissions
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, properties, permissions, value
    }

    /// Decodes a fixture characteristic, rejecting a ``uuid`` BLESwift's identifiers could
    /// not hold rather than trapping on it later in `gattCharacteristic(service:)`.
    ///
    /// Only `uuid` is required. An absent ``properties`` decodes as empty, matching this
    /// type's memberwise default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        try validateFixtureUUID(uuid, forKey: .uuid, in: container)
        properties = try container.decodeIfPresent([FixtureProperty].self, forKey: .properties) ?? []
        value = try container.decodeIfPresent(Data.self, forKey: .value)
        if let explicit = try container.decodeIfPresent([FixturePermission].self, forKey: .permissions) {
            permissions = explicit
        } else {
            permissions = Self.derivedPermissions(for: properties)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(properties, forKey: .properties)
        try container.encodeIfPresent(permissions, forKey: .permissions)
        try container.encodeIfPresent(value, forKey: .value)
    }

    /// Derives permissions from a characteristic's properties, per the documented rule.
    private static func derivedPermissions(for properties: [FixtureProperty]) -> [FixturePermission] {
        var derived: [FixturePermission] = []
        if properties.contains(.read) || properties.contains(.notify) || properties.contains(.indicate) {
            derived.append(.readable)
        }
        if properties.contains(.write) || properties.contains(.writeWithoutResponse) {
            derived.append(.writeable)
        }
        return derived
    }

    /// This characteristic, converted to a ``BLESwiftCore/GATTCharacteristic``.
    fileprivate func gattCharacteristic(service: ServiceIdentifier) -> GATTCharacteristic {
        let effectivePermissions = permissions ?? Self.derivedPermissions(for: properties)
        return GATTCharacteristic(
            identifier: CharacteristicIdentifier(uuid: uuid, service: service),
            properties: CharacteristicProperties(properties.map(\.characteristicProperty)),
            permissions: AttributePermissions(effectivePermissions.map(\.attributePermission)),
            value: value
        )
    }
}

/// One operation a fixture characteristic advertises support for, mirroring
/// `CharacteristicProperties`.
public enum FixtureProperty: String, Codable, Sendable, CaseIterable {

    /// The characteristic's value can be read.
    case read

    /// The characteristic's value can be written with a response.
    case write

    /// The characteristic's value can be written without a response.
    case writeWithoutResponse

    /// The characteristic supports notifications.
    case notify

    /// The characteristic supports indications.
    case indicate

    /// The characteristic's value can be broadcast.
    case broadcast

    /// The characteristic supports signed writes without a response.
    case authenticatedSignedWrites

    /// The characteristic has an Extended Properties descriptor.
    case extendedProperties

    /// This fixture property, converted to its `CharacteristicProperties`
    /// member.
    public var characteristicProperty: CharacteristicProperties {
        switch self {
        case .read: .read
        case .write: .write
        case .writeWithoutResponse: .writeWithoutResponse
        case .notify: .notify
        case .indicate: .indicate
        case .broadcast: .broadcast
        case .authenticatedSignedWrites: .authenticatedSignedWrites
        case .extendedProperties: .extendedProperties
        }
    }
}

/// One access permission gating a fixture characteristic's value, mirroring
/// `AttributePermissions`.
public enum FixturePermission: String, Codable, Sendable, CaseIterable {

    /// The attribute's value can be read.
    case readable

    /// The attribute's value can be written.
    case writeable

    /// The attribute's value can only be read on an encrypted link.
    case readEncryptionRequired

    /// The attribute's value can only be written on an encrypted link.
    case writeEncryptionRequired

    /// This fixture permission, converted to its `AttributePermissions`
    /// member.
    public var attributePermission: AttributePermissions {
        switch self {
        case .readable: .readable
        case .writeable: .writeable
        case .readEncryptionRequired: .readEncryptionRequired
        case .writeEncryptionRequired: .writeEncryptionRequired
        }
    }
}
