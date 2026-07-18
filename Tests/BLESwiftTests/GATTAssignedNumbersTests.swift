//
//  GATTAssignedNumbersTests.swift
//  BLESwiftTests
//

import Testing
import BLESwiftCore

@Suite("GATTAssignedNumbers")
struct GATTAssignedNumbersTests {

    // The Bluetooth Base UUID, parameterized on its 16-bit field, is how a 16-bit SIG UUID
    // expands to its full 128-bit form.
    private func baseUUID(_ short: String) -> String {
        "0000\(short)-0000-1000-8000-00805F9B34FB"
    }

    // MARK: - Known UUID → name, all three attribute kinds

    @Test("A known service UUID resolves to its assigned name")
    func knownService() {
        let heartRate = ServiceIdentifier(uuid: "180D")
        #expect(GATTAssignedNumbers.name(for: heartRate) == "Heart Rate")
        #expect(ServiceIdentifier(uuid: "180F").name == "Battery")
        #expect(ServiceIdentifier(uuid: "180A").name == "Device Information")
    }

    @Test("A known characteristic UUID resolves to its assigned name")
    func knownCharacteristic() {
        let service = ServiceIdentifier(uuid: "180D")
        let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)
        #expect(GATTAssignedNumbers.name(for: measurement) == "Heart Rate Measurement")

        let battery = ServiceIdentifier(uuid: "180F")
        #expect(CharacteristicIdentifier(uuid: "2A19", service: battery).name == "Battery Level")
        #expect(
            CharacteristicIdentifier(uuid: "2A29", service: ServiceIdentifier(uuid: "180A")).name
                == "Manufacturer Name String"
        )
    }

    @Test("A known descriptor UUID resolves to its assigned name")
    func knownDescriptor() {
        let service = ServiceIdentifier(uuid: "180D")
        let characteristic = CharacteristicIdentifier(uuid: "2A37", service: service)
        let cccd = DescriptorIdentifier(uuid: "2902", characteristic: characteristic)
        #expect(GATTAssignedNumbers.name(for: cccd) == "Client Characteristic Configuration")
        #expect(
            DescriptorIdentifier(uuid: "2901", characteristic: characteristic).name
                == "Characteristic User Description"
        )
        #expect(
            DescriptorIdentifier(uuid: "2904", characteristic: characteristic).name
                == "Characteristic Presentation Format"
        )
    }

    // MARK: - 16-bit vs expanded 128-bit resolve identically

    @Test("A full Base-UUID resolves to the same service name as its 16-bit shorthand")
    func serviceExpandedBaseUUID() {
        let short = ServiceIdentifier(uuid: "180D")
        let expanded = ServiceIdentifier(uuid: baseUUID("180D"))
        #expect(expanded.name == short.name)
        #expect(expanded.name == "Heart Rate")
        // Lowercase input still resolves (identifiers normalize to uppercase).
        #expect(ServiceIdentifier(uuid: "0000180d-0000-1000-8000-00805f9b34fb").name == "Heart Rate")
    }

    @Test("A full Base-UUID resolves to the same characteristic name as its 16-bit shorthand")
    func characteristicExpandedBaseUUID() {
        let service = ServiceIdentifier(uuid: "180D")
        let short = CharacteristicIdentifier(uuid: "2A37", service: service)
        let expanded = CharacteristicIdentifier(uuid: baseUUID("2A37"), service: service)
        #expect(expanded.name == short.name)
        #expect(expanded.name == "Heart Rate Measurement")
    }

    @Test("A full Base-UUID resolves to the same descriptor name as its 16-bit shorthand")
    func descriptorExpandedBaseUUID() {
        let characteristic = CharacteristicIdentifier(
            uuid: "2A37",
            service: ServiceIdentifier(uuid: "180D")
        )
        let short = DescriptorIdentifier(uuid: "2902", characteristic: characteristic)
        let expanded = DescriptorIdentifier(uuid: baseUUID("2902"), characteristic: characteristic)
        #expect(expanded.name == short.name)
        #expect(expanded.name == "Client Characteristic Configuration")
    }

    @Test("The 8-character 32-bit shorthand of a 16-bit UUID also resolves")
    func thirtyTwoBitShorthand() {
        #expect(ServiceIdentifier(uuid: "0000180D").name == "Heart Rate")
    }

    // MARK: - Unknown UUID → nil (never crashes)

    @Test("An unknown 16-bit UUID returns nil for every attribute kind")
    func unknownShort() {
        let service = ServiceIdentifier(uuid: "F00D")
        #expect(GATTAssignedNumbers.name(for: service) == nil)

        let characteristic = CharacteristicIdentifier(uuid: "FFF1", service: service)
        #expect(GATTAssignedNumbers.name(for: characteristic) == nil)

        let descriptor = DescriptorIdentifier(uuid: "FFF2", characteristic: characteristic)
        #expect(GATTAssignedNumbers.name(for: descriptor) == nil)
    }

    @Test("An unknown vendor 128-bit UUID (not a SIG Base UUID) returns nil")
    func unknownVendorUUID() {
        let service = ServiceIdentifier(uuid: "6E400009-B5A3-F393-E0A9-E50E24DCCA9E")
        #expect(GATTAssignedNumbers.name(for: service) == nil)
        #expect(service.name == nil)
    }

    @Test("A 128-bit UUID with a non-zero high field is not treated as a SIG short UUID")
    func nonZeroHighFieldIsNotSIG() {
        // Same low 16 bits as Heart Rate (180D) but a non-zero 32-bit prefix → not SIG.
        let service = ServiceIdentifier(uuid: "1234180D-0000-1000-8000-00805F9B34FB")
        #expect(service.name == nil)
        // 32-bit shorthand with non-zero high half likewise does not resolve.
        #expect(ServiceIdentifier(uuid: "1234180D").name == nil)
    }

    // MARK: - Well-known vendor UUID (Nordic UART)

    @Test("A curated vendor 128-bit UUID resolves by full UUID")
    func vendorNordicUART() {
        #expect(
            ServiceIdentifier(uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E").name
                == "Nordic UART Service"
        )
        let service = ServiceIdentifier(uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        #expect(
            CharacteristicIdentifier(uuid: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E", service: service)
                .name == "Nordic UART RX"
        )
        #expect(
            CharacteristicIdentifier(uuid: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E", service: service)
                .name == "Nordic UART TX"
        )
    }
}
