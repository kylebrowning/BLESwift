//
//  WireTypes.swift
//  BLESwiftLink
//

import BLESwiftCore
import Foundation

/// A `Codable` mirror of `NSError` that is safe to send on the wire. It has only the fields
/// that survive serialization: `domain`, `code`, and a rendered `description`.
///
/// `BLESwiftCore` types never conform to `Codable`. `WireError` is the DTO that crosses the wire
/// in their place, wherever an `Error` would otherwise appear.
public struct WireError: Codable, Sendable, Equatable {

    /// Mirrors `NSError.domain`.
    public var domain: String

    /// Mirrors `NSError.code`.
    public var code: Int

    /// Mirrors `NSError.localizedDescription`.
    public var description: String

    /// Creates a `WireError` directly from its three fields.
    public init(domain: String, code: Int, description: String) {
        self.domain = domain
        self.code = code
        self.description = description
    }

    /// Creates a `WireError` from an `NSError`. The initializer copies the domain, the code, and
    /// the localized description.
    public init(_ error: NSError) {
        self.domain = error.domain
        self.code = error.code
        self.description = error.localizedDescription
    }

    /// Rebuilds an `NSError` from this `WireError`. The `description` becomes
    /// `NSLocalizedDescriptionKey`.
    public var nsError: NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

extension Optional where Wrapped == NSError {
    /// Converts an optional `NSError` to an optional `WireError`. A `nil` stays `nil`.
    public var wire: WireError? {
        map(WireError.init)
    }
}

/// A `Codable` mirror of `CentralState`.
public enum WireCentralState: String, Codable, Sendable, Equatable, CaseIterable {
    /// Mirrors `CentralState.unknown`.
    case unknown
    /// Mirrors `CentralState.resetting`.
    case resetting
    /// Mirrors `CentralState.unsupported`.
    case unsupported
    /// Mirrors `CentralState.unauthorized`.
    case unauthorized
    /// Mirrors `CentralState.poweredOff`.
    case poweredOff
    /// Mirrors `CentralState.poweredOn`.
    case poweredOn

    /// Creates a `WireCentralState` from a `CentralState`.
    public init(_ state: CentralState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        }
    }

    /// Converts back to `CentralState`.
    public var state: CentralState {
        switch self {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .poweredOn: return .poweredOn
        }
    }
}

/// A `Codable` mirror of `WriteType`.
public enum WireWriteType: String, Codable, Sendable, Equatable, CaseIterable {
    /// Mirrors `WriteType.withResponse`.
    case withResponse
    /// Mirrors `WriteType.withoutResponse`.
    case withoutResponse

    /// Creates a `WireWriteType` from a `WriteType`.
    public init(_ type: WriteType) {
        switch type {
        case .withResponse: self = .withResponse
        case .withoutResponse: self = .withoutResponse
        }
    }

    /// Converts back to `WriteType`.
    public var writeType: WriteType {
        switch self {
        case .withResponse: return .withResponse
        case .withoutResponse: return .withoutResponse
        }
    }
}

/// A `Codable` mirror of `CharacteristicIdentifier`. It has the characteristic's UUID and the
/// owning service's UUID. Each UUID is a canonical string.
public struct WireCharacteristicRef: Codable, Sendable, Equatable {

    /// The UUID string of the owning service.
    public var service: String

    /// The UUID string of the characteristic.
    public var uuid: String

    /// Creates a `WireCharacteristicRef` directly from its two UUID strings.
    public init(service: String, uuid: String) {
        self.service = service
        self.uuid = uuid
    }

    /// Creates a `WireCharacteristicRef` from a `CharacteristicIdentifier`.
    public init(_ id: CharacteristicIdentifier) {
        self.service = id.service.uuidString
        self.uuid = id.uuidString
    }

    /// Converts back to a `CharacteristicIdentifier`.
    ///
    /// - Throws: ``WireDecodingError/invalidIdentifier(_:)``. See
    ///   ``WireIdentifierValidation``.
    public var identifier: CharacteristicIdentifier {
        get throws {
            try WireIdentifierValidation.validated(service)
            try WireIdentifierValidation.validated(uuid)
            return CharacteristicIdentifier(uuid: uuid, service: ServiceIdentifier(uuid: service))
        }
    }
}

/// A `Codable` mirror of `DescriptorIdentifier`. It has the descriptor's UUID, the owning
/// characteristic's UUID, and the owning service's UUID. Each UUID is a canonical string.
public struct WireDescriptorRef: Codable, Sendable, Equatable {

    /// The UUID string of the owning service.
    public var service: String

    /// The UUID string of the owning characteristic.
    public var characteristic: String

    /// The UUID string of the descriptor.
    public var uuid: String

    /// Creates a `WireDescriptorRef` directly from its three UUID strings.
    public init(service: String, characteristic: String, uuid: String) {
        self.service = service
        self.characteristic = characteristic
        self.uuid = uuid
    }

    /// Creates a `WireDescriptorRef` from a `DescriptorIdentifier`.
    public init(_ id: DescriptorIdentifier) {
        self.service = id.characteristic.service.uuidString
        self.characteristic = id.characteristic.uuidString
        self.uuid = id.uuidString
    }

    /// Converts back to a `DescriptorIdentifier`.
    ///
    /// - Throws: ``WireDecodingError/invalidIdentifier(_:)``. See
    ///   ``WireIdentifierValidation``.
    public var identifier: DescriptorIdentifier {
        get throws {
            try WireIdentifierValidation.validated(service)
            try WireIdentifierValidation.validated(characteristic)
            try WireIdentifierValidation.validated(uuid)
            return DescriptorIdentifier(
                uuid: uuid,
                characteristic: CharacteristicIdentifier(uuid: characteristic, service: ServiceIdentifier(uuid: service))
            )
        }
    }
}

/// A `Codable` mirror of `AdvertisementData`. The service UUIDs are strings.
public struct WireAdvertisement: Codable, Sendable, Equatable {

    /// Mirrors `AdvertisementData.localName`.
    public var localName: String?

    /// Mirrors `AdvertisementData.serviceUUIDs`, as UUID strings.
    public var serviceUUIDs: [String]?

    /// Mirrors `AdvertisementData.manufacturerData`.
    public var manufacturerData: Data?

    /// Mirrors `AdvertisementData.serviceData`, keyed by service UUID string.
    public var serviceData: [String: Data]?

    /// Mirrors `AdvertisementData.txPowerLevel`.
    public var txPowerLevel: Int?

    /// Mirrors `AdvertisementData.isConnectable`.
    public var isConnectable: Bool?

    /// Mirrors `AdvertisementData.overflowServiceUUIDs`, as UUID strings.
    public var overflowServiceUUIDs: [String]?

    /// Mirrors `AdvertisementData.solicitedServiceUUIDs`, as UUID strings.
    public var solicitedServiceUUIDs: [String]?

    /// Creates a `WireAdvertisement` directly from its fields.
    public init(
        localName: String?,
        serviceUUIDs: [String]?,
        manufacturerData: Data?,
        serviceData: [String: Data]?,
        txPowerLevel: Int?,
        isConnectable: Bool?,
        overflowServiceUUIDs: [String]?,
        solicitedServiceUUIDs: [String]?
    ) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
        self.txPowerLevel = txPowerLevel
        self.isConnectable = isConnectable
        self.overflowServiceUUIDs = overflowServiceUUIDs
        self.solicitedServiceUUIDs = solicitedServiceUUIDs
    }

    /// Creates a `WireAdvertisement` from `AdvertisementData`.
    public init(_ data: AdvertisementData) {
        self.localName = data.localName
        self.serviceUUIDs = data.serviceUUIDs?.map(\.uuidString)
        self.manufacturerData = data.manufacturerData
        self.serviceData = data.serviceData.map { serviceData in
            Dictionary(uniqueKeysWithValues: serviceData.map { ($0.key.uuidString, $0.value) })
        }
        self.txPowerLevel = data.txPowerLevel
        self.isConnectable = data.isConnectable
        self.overflowServiceUUIDs = data.overflowServiceUUIDs?.map(\.uuidString)
        self.solicitedServiceUUIDs = data.solicitedServiceUUIDs?.map(\.uuidString)
    }

    /// Converts back to `AdvertisementData`. The function rejects these two kinds of input:
    ///
    /// - A service UUID string that a `ServiceIdentifier` cannot represent.
    /// - Two ``serviceData`` keys that name the same service after normalization.
    ///
    /// `ServiceIdentifier` normalizes case, so `"180d"` and `"180D"` are two keys on the wire and
    /// one key here. A dictionary that is built from colliding keys would trap, so the function
    /// refuses a collision as a protocol violation.
    ///
    /// - Throws: ``WireDecodingError/invalidIdentifier(_:)`` (see ``WireIdentifierValidation``),
    ///   or ``WireDecodingError/duplicateIdentifier(_:)``.
    public var advertisementData: AdvertisementData {
        get throws {
            try serviceUUIDs?.forEach { try WireIdentifierValidation.validated($0) }
            try overflowServiceUUIDs?.forEach { try WireIdentifierValidation.validated($0) }
            try solicitedServiceUUIDs?.forEach { try WireIdentifierValidation.validated($0) }
            var convertedServiceData: [ServiceIdentifier: Data]?
            if let serviceData {
                var table: [ServiceIdentifier: Data] = [:]
                table.reserveCapacity(serviceData.count)
                for (uuid, value) in serviceData {
                    let identifier = ServiceIdentifier(uuid: try WireIdentifierValidation.validated(uuid))
                    guard table.updateValue(value, forKey: identifier) == nil else {
                        throw WireDecodingError.duplicateIdentifier(identifier.uuidString)
                    }
                }
                convertedServiceData = table
            }
            return AdvertisementData(
                localName: localName,
                serviceUUIDs: serviceUUIDs?.map { ServiceIdentifier(uuid: $0) },
                manufacturerData: manufacturerData,
                serviceData: convertedServiceData,
                txPowerLevel: txPowerLevel,
                isConnectable: isConnectable,
                overflowServiceUUIDs: overflowServiceUUIDs?.map { ServiceIdentifier(uuid: $0) },
                solicitedServiceUUIDs: solicitedServiceUUIDs?.map { ServiceIdentifier(uuid: $0) }
            )
        }
    }
}

/// A `Codable` summary of one characteristic that a `discoverCharacteristics` request found.
/// It has the UUID and the raw `CharacteristicProperties` bitmask.
public struct WireDiscoveredCharacteristic: Codable, Sendable, Equatable {

    /// The UUID string of the characteristic.
    public var uuid: String

    /// The raw `CharacteristicProperties.rawValue` bitmask.
    public var properties: UInt

    /// Creates a `WireDiscoveredCharacteristic`.
    public init(uuid: String, properties: UInt) {
        self.uuid = uuid
        self.properties = properties
    }
}

/// A `Codable` mirror of `GATTCharacteristic`. The properties and permissions are raw
/// bitmasks.
public struct WireGATTCharacteristic: Codable, Sendable, Equatable {

    /// The UUID string of the characteristic.
    public var uuid: String

    /// The raw `CharacteristicProperties.rawValue` bitmask.
    public var properties: UInt

    /// The raw `AttributePermissions.rawValue` bitmask.
    public var permissions: UInt

    /// Mirrors `GATTCharacteristic.value`.
    public var value: Data?

    /// Creates a `WireGATTCharacteristic` directly from its fields.
    public init(uuid: String, properties: UInt, permissions: UInt, value: Data?) {
        self.uuid = uuid
        self.properties = properties
        self.permissions = permissions
        self.value = value
    }

    /// Creates a `WireGATTCharacteristic` from a `GATTCharacteristic`.
    public init(_ characteristic: GATTCharacteristic) {
        self.uuid = characteristic.identifier.uuidString
        self.properties = characteristic.properties.rawValue
        self.permissions = characteristic.permissions.rawValue
        self.value = characteristic.value
    }

    /// Converts back to a `GATTCharacteristic`, scoped to `service`.
    ///
    /// - Throws: ``WireDecodingError/invalidIdentifier(_:)`` if a `CharacteristicIdentifier`
    ///   cannot represent ``uuid``.
    public func gattCharacteristic(service: ServiceIdentifier) throws -> GATTCharacteristic {
        try WireIdentifierValidation.validated(uuid)
        return GATTCharacteristic(
            identifier: CharacteristicIdentifier(uuid: uuid, service: service),
            properties: CharacteristicProperties(rawValue: properties),
            permissions: AttributePermissions(rawValue: permissions),
            value: value
        )
    }
}

/// A `Codable` mirror of `GATTService`.
public struct WireGATTService: Codable, Sendable, Equatable {

    /// The UUID string of the service.
    public var uuid: String

    /// Mirrors `GATTService.isPrimary`.
    public var isPrimary: Bool

    /// The service's characteristics.
    public var characteristics: [WireGATTCharacteristic]

    /// Creates a `WireGATTService` directly from its fields.
    public init(uuid: String, isPrimary: Bool, characteristics: [WireGATTCharacteristic]) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }

    /// Creates a `WireGATTService` from a `GATTService`.
    public init(_ service: GATTService) {
        self.uuid = service.identifier.uuidString
        self.isPrimary = service.isPrimary
        self.characteristics = service.characteristics.map(WireGATTCharacteristic.init)
    }

    /// Converts back to a `GATTService`.
    ///
    /// - Throws: ``WireDecodingError/invalidIdentifier(_:)``. See
    ///   ``WireIdentifierValidation``.
    public var gattService: GATTService {
        get throws {
            try WireIdentifierValidation.validated(uuid)
            let identifier = ServiceIdentifier(uuid: uuid)
            return GATTService(
                identifier: identifier,
                isPrimary: isPrimary,
                characteristics: try characteristics.map { try $0.gattCharacteristic(service: identifier) }
            )
        }
    }
}

/// A `Codable` mirror of `Subscriber`.
public struct WireSubscriber: Codable, Sendable, Equatable {

    /// Mirrors `Subscriber.id`.
    public var id: UUID

    /// Mirrors `Subscriber.maximumUpdateValueLength`.
    public var maximumUpdateValueLength: Int

    /// Creates a `WireSubscriber` directly from its fields.
    public init(id: UUID, maximumUpdateValueLength: Int) {
        self.id = id
        self.maximumUpdateValueLength = maximumUpdateValueLength
    }

    /// Creates a `WireSubscriber` from a `Subscriber`.
    public init(_ subscriber: Subscriber) {
        self.id = subscriber.id
        self.maximumUpdateValueLength = subscriber.maximumUpdateValueLength
    }

    /// Converts back to a `Subscriber`.
    ///
    /// - Throws: ``WireDecodingError/invalidMaximumLength(_:)`` if ``maximumUpdateValueLength`` is
    ///   zero or negative. See ``WireLengthValidation``.
    public var subscriber: Subscriber {
        get throws {
            Subscriber(
                id: id,
                maximumUpdateValueLength: try WireLengthValidation.validated(maximumUpdateValueLength)
            )
        }
    }
}

/// A `Codable` mirror of `ReadRequest`.
public struct WireReadRequest: Codable, Sendable, Equatable {

    /// The `RequestToken.rawValue` that identifies this request.
    public var token: UUID

    /// The remote central that sent the request.
    public var central: WireSubscriber

    /// The characteristic that the central reads.
    public var characteristic: WireCharacteristicRef

    /// Mirrors `ReadRequest.offset`.
    public var offset: Int

    /// Creates a `WireReadRequest` directly from its fields.
    public init(token: UUID, central: WireSubscriber, characteristic: WireCharacteristicRef, offset: Int) {
        self.token = token
        self.central = central
        self.characteristic = characteristic
        self.offset = offset
    }

    /// Creates a `WireReadRequest` from a `ReadRequest`.
    public init(_ request: ReadRequest) {
        self.token = request.token.rawValue
        self.central = WireSubscriber(request.central)
        self.characteristic = WireCharacteristicRef(request.characteristic)
        self.offset = request.offset
    }

    /// Converts back to a `ReadRequest`.
    ///
    /// - Throws:
    ///   - ``WireDecodingError/invalidIdentifier(_:)`` if BLESwift identifiers cannot represent
    ///     the request's characteristic.
    ///   - ``WireDecodingError/invalidMaximumLength(_:)`` if the central's update length is
    ///     unusable.
    ///   - ``WireDecodingError/invalidOffset(_:)`` if ``offset`` is negative.
    public var readRequest: ReadRequest {
        get throws {
            ReadRequest(
                token: RequestToken(rawValue: token),
                central: try central.subscriber,
                characteristic: try characteristic.identifier,
                offset: try WireLengthValidation.validatedOffset(offset)
            )
        }
    }
}

/// A `Codable` mirror of one `WriteRequest.Entry`.
public struct WireWriteEntry: Codable, Sendable, Equatable {

    /// The remote central that sent the write.
    public var central: WireSubscriber

    /// The characteristic that the central writes.
    public var characteristic: WireCharacteristicRef

    /// Mirrors `WriteRequest.Entry.offset`.
    public var offset: Int

    /// Mirrors `WriteRequest.Entry.value`.
    public var value: Data

    /// Creates a `WireWriteEntry` directly from its fields.
    public init(central: WireSubscriber, characteristic: WireCharacteristicRef, offset: Int, value: Data) {
        self.central = central
        self.characteristic = characteristic
        self.offset = offset
        self.value = value
    }

    /// Creates a `WireWriteEntry` from a `WriteRequest.Entry`.
    public init(_ entry: WriteRequest.Entry) {
        self.central = WireSubscriber(entry.central)
        self.characteristic = WireCharacteristicRef(entry.characteristic)
        self.offset = entry.offset
        self.value = entry.value
    }

    /// Converts back to a `WriteRequest.Entry`.
    ///
    /// - Throws:
    ///   - ``WireDecodingError/invalidIdentifier(_:)`` if BLESwift identifiers cannot represent
    ///     the entry's characteristic.
    ///   - ``WireDecodingError/invalidMaximumLength(_:)`` if the central's update length is
    ///     unusable.
    ///   - ``WireDecodingError/invalidOffset(_:)`` if ``offset`` is negative.
    public var entry: WriteRequest.Entry {
        get throws {
            WriteRequest.Entry(
                central: try central.subscriber,
                characteristic: try characteristic.identifier,
                offset: try WireLengthValidation.validatedOffset(offset),
                value: value
            )
        }
    }
}

/// A `Codable` mirror of `WriteRequest`.
public struct WireWriteRequest: Codable, Sendable, Equatable {

    /// The `RequestToken.rawValue` that identifies this batch.
    public var token: UUID

    /// The writes in this batch.
    public var entries: [WireWriteEntry]

    /// Creates a `WireWriteRequest` directly from its fields.
    public init(token: UUID, entries: [WireWriteEntry]) {
        self.token = token
        self.entries = entries
    }

    /// Creates a `WireWriteRequest` from a `WriteRequest`.
    public init(_ request: WriteRequest) {
        self.token = request.token.rawValue
        self.entries = request.entries.map(WireWriteEntry.init)
    }

    /// Converts back to a `WriteRequest`.
    ///
    /// - Throws:
    ///   - ``WireDecodingError/invalidIdentifier(_:)`` if an entry's characteristic is not
    ///     representable by BLESwift identifiers.
    ///   - ``WireDecodingError/invalidMaximumLength(_:)`` if an entry's central reports an
    ///     unusable update length.
    ///   - ``WireDecodingError/invalidOffset(_:)`` if an entry's offset is negative.
    public var writeRequest: WriteRequest {
        get throws {
            WriteRequest(token: RequestToken(rawValue: token), entries: try entries.map { try $0.entry })
        }
    }
}

/// A `Codable` mirror of `WarningOptions`.
public struct WireConnectOptions: Codable, Sendable, Equatable {

    /// Mirrors `WarningOptions.notifyOnConnection`.
    public var notifyOnConnection: Bool

    /// Mirrors `WarningOptions.notifyOnDisconnection`.
    public var notifyOnDisconnection: Bool

    /// Mirrors `WarningOptions.notifyOnNotification`.
    public var notifyOnNotification: Bool

    /// Creates a `WireConnectOptions` directly from its fields.
    public init(notifyOnConnection: Bool, notifyOnDisconnection: Bool, notifyOnNotification: Bool) {
        self.notifyOnConnection = notifyOnConnection
        self.notifyOnDisconnection = notifyOnDisconnection
        self.notifyOnNotification = notifyOnNotification
    }

    /// Creates a `WireConnectOptions` from `WarningOptions`.
    public init(_ options: WarningOptions) {
        self.notifyOnConnection = options.notifyOnConnection
        self.notifyOnDisconnection = options.notifyOnDisconnection
        self.notifyOnNotification = options.notifyOnNotification
    }

    /// Converts back to `WarningOptions`.
    public var warningOptions: WarningOptions {
        WarningOptions(
            notifyOnConnection: notifyOnConnection,
            notifyOnDisconnection: notifyOnDisconnection,
            notifyOnNotification: notifyOnNotification
        )
    }
}
