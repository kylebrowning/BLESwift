//
//  AdvertisementData.swift
//  BLESwiftCore
//

import Foundation

/// A typed, `Sendable` view of the advertisement packet a peripheral is broadcasting.
///
/// CoreBluetooth delivers this data as `[String: Any]`, which cannot cross actor
/// isolation boundaries. `AdvertisementData` is parsed from that dictionary once, at the
/// point it is received from CoreBluetooth (in the `BLESwift` module's internal
/// `init(advertisementData:)` — the only place the raw advertisement dictionary is
/// touched), into `Sendable` values.
public struct AdvertisementData: Sendable {

    /// The peripheral's locally-advertised name (`CBAdvertisementDataLocalNameKey`).
    ///
    /// May differ from the name CoreBluetooth otherwise caches for the peripheral.
    public let localName: String?

    /// The service UUIDs found in the advertisement packet
    /// (`CBAdvertisementDataServiceUUIDsKey`).
    public let serviceUUIDs: [ServiceIdentifier]?

    /// Manufacturer-specific advertisement data
    /// (`CBAdvertisementDataManufacturerDataKey`).
    ///
    /// The first two bytes are typically a company identifier assigned by the Bluetooth
    /// SIG; the remainder is manufacturer-defined.
    public let manufacturerData: Data?

    /// A mapping of service UUID to service-specific advertisement data
    /// (`CBAdvertisementDataServiceDataKey`).
    public let serviceData: [ServiceIdentifier: Data]?

    /// The transmit power of the peripheral, in dBm
    /// (`CBAdvertisementDataTxPowerLevelKey`).
    public let txPowerLevel: Int?

    /// Whether the peripheral is currently accepting connections
    /// (`CBAdvertisementDataIsConnectable`).
    public let isConnectable: Bool?

    /// Service UUIDs found in the "overflow" area of the advertisement packet, which are
    /// only discoverable via active scanning of a peripheral with a specific Bluetooth
    /// chipset (`CBAdvertisementDataOverflowServiceUUIDsKey`).
    public let overflowServiceUUIDs: [ServiceIdentifier]?

    /// Service UUIDs the peripheral is soliciting from a central
    /// (`CBAdvertisementDataSolicitedServiceUUIDsKey`).
    public let solicitedServiceUUIDs: [ServiceIdentifier]?

    /// Creates an `AdvertisementData` directly, with every field defaulted to `nil`.
    ///
    /// The construction path for tests and previews — production advertisement data is
    /// always parsed from CoreBluetooth's raw dictionary by the `BLESwift` module's
    /// internal `init(advertisementData:)`.
    public init(
        localName: String? = nil,
        serviceUUIDs: [ServiceIdentifier]? = nil,
        manufacturerData: Data? = nil,
        serviceData: [ServiceIdentifier: Data]? = nil,
        txPowerLevel: Int? = nil,
        isConnectable: Bool? = nil,
        overflowServiceUUIDs: [ServiceIdentifier]? = nil,
        solicitedServiceUUIDs: [ServiceIdentifier]? = nil
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
}
