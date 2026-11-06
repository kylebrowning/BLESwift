//
//  AdvertisementData.swift
//  BLESwiftCore
//

import Foundation

/// A typed, `Sendable` view of the advertisement packet that a peripheral broadcasts. BLESwift
/// parses it once from CoreBluetooth's `[String: Any]` payload.
public struct AdvertisementData: Sendable {

    /// The local name that the peripheral advertises (`CBAdvertisementDataLocalNameKey`). It can
    /// differ from the name that CoreBluetooth caches.
    public let localName: String?

    /// The service UUIDs in the advertisement packet (`CBAdvertisementDataServiceUUIDsKey`).
    public let serviceUUIDs: [ServiceIdentifier]?

    /// Manufacturer-specific advertisement data (`CBAdvertisementDataManufacturerDataKey`).
    public let manufacturerData: Data?

    /// A mapping of service UUID to service-specific advertisement data
    /// (`CBAdvertisementDataServiceDataKey`).
    public let serviceData: [ServiceIdentifier: Data]?

    /// The transmit power of the peripheral, in dBm (`CBAdvertisementDataTxPowerLevelKey`).
    public let txPowerLevel: Int?

    /// Whether the peripheral accepts connections (`CBAdvertisementDataIsConnectable`).
    public let isConnectable: Bool?

    /// Service UUIDs in the "overflow" area of the advertisement packet
    /// (`CBAdvertisementDataOverflowServiceUUIDsKey`).
    public let overflowServiceUUIDs: [ServiceIdentifier]?

    /// Service UUIDs that the peripheral asks a central to offer
    /// (`CBAdvertisementDataSolicitedServiceUUIDsKey`).
    public let solicitedServiceUUIDs: [ServiceIdentifier]?

    /// Creates an `AdvertisementData` directly. Every field has the default value `nil`.
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
