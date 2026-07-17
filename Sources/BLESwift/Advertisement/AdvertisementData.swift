//
//  AdvertisementData.swift
//  BLESwift
//

import CoreBluetooth
import Foundation

/// A typed, `Sendable` view of the advertisement packet a peripheral is broadcasting.
///
/// CoreBluetooth delivers this data as `[String: Any]`, which cannot cross actor
/// isolation boundaries. `AdvertisementData` is parsed from that dictionary once, at the
/// point it is received from CoreBluetooth, into `Sendable` values — this is the only
/// place in BLESwift the raw advertisement dictionary is touched.
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

    /// Parses an `AdvertisementData` from CoreBluetooth's raw advertisement dictionary.
    ///
    /// - Parameter advertisementData: The `[String: Any]` dictionary CoreBluetooth vends
    ///   to `centralManager(_:didDiscover:advertisementData:rssi:)`.
    init(advertisementData: [String: Any]) {
        self.localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String

        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            self.serviceUUIDs = uuids.map { ServiceIdentifier(cbuuid: $0) }
        } else {
            self.serviceUUIDs = nil
        }

        self.manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        if let rawServiceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            var mapped: [ServiceIdentifier: Data] = [:]
            for (uuid, data) in rawServiceData {
                mapped[ServiceIdentifier(cbuuid: uuid)] = data
            }
            self.serviceData = mapped
        } else {
            self.serviceData = nil
        }

        self.txPowerLevel = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue

        self.isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue

        if let uuids = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            self.overflowServiceUUIDs = uuids.map { ServiceIdentifier(cbuuid: $0) }
        } else {
            self.overflowServiceUUIDs = nil
        }

        if let uuids = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] {
            self.solicitedServiceUUIDs = uuids.map { ServiceIdentifier(cbuuid: $0) }
        } else {
            self.solicitedServiceUUIDs = nil
        }
    }
}
