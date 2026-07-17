//
//  AdvertisementDataTests.swift
//  BLESwiftTests
//

import CoreBluetooth
import Foundation
import Testing
import BLESwiftCore
@testable import BLESwift

@Suite("AdvertisementData parsing")
struct AdvertisementDataTests {

    @Test("parses every supported key from a literal advertisement dictionary")
    func parsesLiteralDictionary() {
        let serviceUUID = CBUUID(string: "180D")
        let dict: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "Heart Rate Monitor",
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataManufacturerDataKey: Data([0x4C, 0x00, 0x02, 0x15]),
            CBAdvertisementDataServiceDataKey: [serviceUUID: Data([0x01, 0x02])],
            CBAdvertisementDataTxPowerLevelKey: NSNumber(value: -12),
            CBAdvertisementDataIsConnectable: NSNumber(value: true),
            CBAdvertisementDataOverflowServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataSolicitedServiceUUIDsKey: [serviceUUID],
        ]

        let advertisement = AdvertisementData(advertisementData: dict)
        let expectedIdentifier = ServiceIdentifier(uuid: "180D")

        #expect(advertisement.localName == "Heart Rate Monitor")
        #expect(advertisement.serviceUUIDs == [expectedIdentifier])
        #expect(advertisement.manufacturerData == Data([0x4C, 0x00, 0x02, 0x15]))
        #expect(advertisement.serviceData == [expectedIdentifier: Data([0x01, 0x02])])
        #expect(advertisement.txPowerLevel == -12)
        #expect(advertisement.isConnectable == true)
        #expect(advertisement.overflowServiceUUIDs == [expectedIdentifier])
        #expect(advertisement.solicitedServiceUUIDs == [expectedIdentifier])
    }

    @Test("all fields are nil when the dictionary is empty")
    func handlesEmptyDictionary() {
        let advertisement = AdvertisementData(advertisementData: [:])

        #expect(advertisement.localName == nil)
        #expect(advertisement.serviceUUIDs == nil)
        #expect(advertisement.manufacturerData == nil)
        #expect(advertisement.serviceData == nil)
        #expect(advertisement.txPowerLevel == nil)
        #expect(advertisement.isConnectable == nil)
        #expect(advertisement.overflowServiceUUIDs == nil)
        #expect(advertisement.solicitedServiceUUIDs == nil)
    }

    @Test("Discovery bundles peripheral identity, advertisement, and RSSI")
    func discoveryBundlesFields() {
        let peripheral = PeripheralIdentifier(uuid: UUID(), name: "Test Peripheral")
        let advertisement = AdvertisementData(advertisementData: [:])
        let discovery = Discovery(peripheral: peripheral, advertisement: advertisement, rssi: -42)

        #expect(discovery.peripheral == peripheral)
        #expect(discovery.rssi == -42)
    }
}
