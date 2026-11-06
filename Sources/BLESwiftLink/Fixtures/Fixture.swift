//
//  Fixture.swift
//  BLESwiftLink
//

import BLESwiftCore
import Foundation

/// A declarative document that describes one or more virtual BLE devices. The provider loads it
/// with `--fixture`.
///
/// The JSON shape mirrors ``FixtureDevice``, ``FixtureService``, and ``FixtureCharacteristic``
/// directly. There is no separate wire format.
public struct FixtureDocument: Codable, Sendable, Equatable {

    /// The virtual devices that this fixture describes.
    public var devices: [FixtureDevice]

    /// Creates a fixture document from its devices.
    public init(devices: [FixtureDevice]) {
        self.devices = devices
    }

    /// Reads a fixture document from a JSON file on disk and parses it.
    ///
    /// - Parameter url: The file URL of the fixture's JSON document.
    /// - Throws: An error if the file cannot be read or its contents are not a valid fixture
    ///   document (see ``parse(_:)``).
    public static func load(from url: URL) throws -> FixtureDocument {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    /// Parses a fixture document from JSON data.
    ///
    /// - Parameter data: The JSON bytes of the document.
    /// - Throws: `DecodingError` if `data` is not a valid fixture document. This includes:
    ///   - An unrecognized ``FixtureProperty`` or ``FixturePermission`` case name.
    ///   - A UUID string that BLESwift identifiers cannot hold.
    public static func parse(_ data: Data) throws -> FixtureDocument {
        try JSONDecoder().decode(FixtureDocument.self, from: data)
    }
}

/// Rejects a fixture UUID string that BLESwift identifiers cannot hold.
///
/// `ServiceIdentifier` and `CharacteristicIdentifier` **trap** on a string that they cannot
/// normalize. A hand-written fixture with a typo, for example `"zzzz"` for `"180D"`, would stop
/// `bleswift-provider` at load with no explanation.
///
/// Thus the decoder checks every UUID in a fixture with the rule of the wire boundary
/// (``WireIdentifierValidation``). A bad UUID becomes a `DecodingError` that names the UUID's
/// key. The CLI prints this error before it exits with `66`.
///
/// - Parameters:
///   - uuid: The candidate UUID string, as written in the fixture.
///   - key: The key from which the decoder read `uuid`, for the error's coding path.
///   - container: The container that `key` belongs to, for the error's coding path.
///   - index: The element's position, when `key` holds an array of UUID strings.
/// - Throws: `DecodingError.dataCorrupted` if `uuid` is not a UUID string that BLESwift accepts.
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

/// One virtual peripheral that a ``FixtureDocument`` describes. It has an advertisement and
/// the GATT database that it hosts.
public struct FixtureDevice: Codable, Sendable, Equatable {

    /// A stable identifier for this virtual device. It is different from any GATT identifier.
    public var id: UUID

    /// The advertised local name. It becomes the `localName` of ``advertisement``.
    public var name: String?

    /// The service UUIDs to advertise. They become the `serviceUUIDs` of ``advertisement``.
    public var advertisedServices: [String]

    /// Manufacturer-specific advertisement data. The fixture's JSON stores it as base64.
    public var manufacturerData: Data?

    /// The GATT services that this device hosts. They become ``gattServices``.
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

    /// Decodes a fixture device. The decoder rejects an ``advertisedServices`` entry that BLESwift
    /// identifiers cannot hold, so ``advertisement`` cannot trap on it later.
    ///
    /// Only `id` is required. An absent ``advertisedServices`` or ``services`` decodes as empty,
    /// as in the memberwise defaults. Thus the smallest device is `{ "id": "…" }`.
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

    /// Encodes a fixture device in the shape that ``init(from:)`` reads.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(advertisedServices, forKey: .advertisedServices)
        try container.encodeIfPresent(manufacturerData, forKey: .manufacturerData)
        try container.encode(services, forKey: .services)
    }

    /// The advertisement of this device, from ``name``, ``advertisedServices``, and
    /// ``manufacturerData``. The device is always connectable. Every other `AdvertisementData`
    /// field is `nil`.
    public var advertisement: AdvertisementData {
        AdvertisementData(
            localName: name,
            serviceUUIDs: advertisedServices.map(ServiceIdentifier.init(uuid:)),
            manufacturerData: manufacturerData,
            isConnectable: true
        )
    }

    /// The GATT services of this device, from ``services``.
    public var gattServices: [GATTService] {
        services.map(\.gattService)
    }
}

/// One GATT service that a ``FixtureDevice`` describes.
public struct FixtureService: Codable, Sendable, Equatable {

    /// The service's UUID: a full 128-bit string or a 16-bit or 32-bit short string.
    public var uuid: String

    /// Whether this is a primary service. The default is `true` if the JSON omits the field.
    public var isPrimary: Bool

    /// The characteristics that this service hosts.
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

    /// Decodes a fixture service. The decoder rejects a ``uuid`` that BLESwift identifiers cannot
    /// hold, so ``gattService`` cannot trap on it later.
    ///
    /// Only `uuid` is required. An absent ``characteristics`` decodes as empty, as in the
    /// memberwise default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        try validateFixtureUUID(uuid, forKey: .uuid, in: container)
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? true
        characteristics = try container.decodeIfPresent([FixtureCharacteristic].self, forKey: .characteristics) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(characteristics, forKey: .characteristics)
    }

    /// This service as a `GATTService`.
    public var gattService: GATTService {
        let identifier = ServiceIdentifier(uuid: uuid)
        return GATTService(
            identifier: identifier,
            isPrimary: isPrimary,
            characteristics: characteristics.map { $0.gattCharacteristic(service: identifier) }
        )
    }
}

/// One GATT characteristic that a ``FixtureService`` describes.
public struct FixtureCharacteristic: Codable, Sendable, Equatable {

    /// The characteristic's UUID: a full 128-bit string or a 16-bit or 32-bit short string.
    public var uuid: String

    /// The operations that this characteristic advertises as supported.
    public var properties: [FixtureProperty]

    /// The access permissions for this characteristic's value.
    ///
    /// If the JSON omits this field, the decoder derives the permissions from ``properties`` and
    /// stores the result here:
    ///
    /// - `readable` if `read`, `notify`, or `indicate` is present.
    /// - `writeable` if `write` or `writeWithoutResponse` is present.
    public var permissions: [FixturePermission]?

    /// The cached value. The fixture's JSON stores it as base64. If the value is `nil`, the
    /// characteristic is dynamic and the provider serves its value on demand.
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

    /// Decodes a fixture characteristic. The decoder rejects a ``uuid`` that BLESwift identifiers
    /// cannot hold, so `gattCharacteristic(service:)` cannot trap on it later.
    ///
    /// Only `uuid` is required. An absent ``properties`` decodes as empty, as in the memberwise
    /// default.
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

    /// Derives permissions from a characteristic's properties, with the rule of ``permissions``.
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

    /// This characteristic as a ``BLESwiftCore/GATTCharacteristic``.
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

/// One operation that a fixture characteristic advertises as supported. It mirrors
/// `CharacteristicProperties`.
public enum FixtureProperty: String, Codable, Sendable, CaseIterable {

    /// A client can read the characteristic's value.
    case read

    /// A client can write the characteristic's value with a response.
    case write

    /// A client can write the characteristic's value without a response.
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

    /// This fixture property as its `CharacteristicProperties` member.
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

/// One access permission for a fixture characteristic's value. It mirrors
/// `AttributePermissions`.
public enum FixturePermission: String, Codable, Sendable, CaseIterable {

    /// A client can read the attribute's value.
    case readable

    /// A client can write the attribute's value.
    case writeable

    /// A client can read the attribute's value only on an encrypted link.
    case readEncryptionRequired

    /// A client can write the attribute's value only on an encrypted link.
    case writeEncryptionRequired

    /// This fixture permission as its `AttributePermissions` member.
    public var attributePermission: AttributePermissions {
        switch self {
        case .readable: .readable
        case .writeable: .writeable
        case .readEncryptionRequired: .readEncryptionRequired
        case .writeEncryptionRequired: .writeEncryptionRequired
        }
    }
}
