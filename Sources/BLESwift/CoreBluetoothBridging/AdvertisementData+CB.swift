//
//  AdvertisementData+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation

extension AdvertisementData {

    /// Parses an `AdvertisementData` from CoreBluetooth's raw advertisement dictionary.
    /// The only place `BLESwift` touches the raw `[String: Any]` advertisement dictionary.
    ///
    /// - Parameter advertisementData: The `[String: Any]` dictionary CoreBluetooth vends
    ///   to `centralManager(_:didDiscover:advertisementData:rssi:)`.
    init(advertisementData: [String: Any]) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String

        let serviceUUIDs: [ServiceIdentifier]?
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            serviceUUIDs = uuids.map { ServiceIdentifier(cbuuid: $0) }
        } else {
            serviceUUIDs = nil
        }

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        let serviceData: [ServiceIdentifier: Data]?
        if let rawServiceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            var mapped: [ServiceIdentifier: Data] = [:]
            for (uuid, data) in rawServiceData {
                mapped[ServiceIdentifier(cbuuid: uuid)] = data
            }
            serviceData = mapped
        } else {
            serviceData = nil
        }

        let txPowerLevel = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue

        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue

        let overflowServiceUUIDs: [ServiceIdentifier]?
        if let uuids = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            overflowServiceUUIDs = uuids.map { ServiceIdentifier(cbuuid: $0) }
        } else {
            overflowServiceUUIDs = nil
        }

        let solicitedServiceUUIDs: [ServiceIdentifier]?
        if let uuids = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] {
            solicitedServiceUUIDs = uuids.map { ServiceIdentifier(cbuuid: $0) }
        } else {
            solicitedServiceUUIDs = nil
        }

        self.init(
            localName: localName,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturerData,
            serviceData: serviceData,
            txPowerLevel: txPowerLevel,
            isConnectable: isConnectable,
            overflowServiceUUIDs: overflowServiceUUIDs,
            solicitedServiceUUIDs: solicitedServiceUUIDs
        )
    }
}
