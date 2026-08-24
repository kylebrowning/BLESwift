//
//  ProfilesPeripheralTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift
import BLESwiftProfiles

/// Exercises the `Peripheral` conveniences in `BLESwiftProfiles` —
/// `readDeviceInformation()` and `readBatteryLevel()` — against the scriptable
/// `FakeCentral`/`FakePeripheral` rig.
@Suite("BLESwiftProfiles Peripheral extensions")
struct ProfilesPeripheralTests {

    @Test("readDeviceInformation reads present characteristics and leaves absent ones nil")
    func readDeviceInformationPartial() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        // The Device Information service exposes only 4 of its 6 String characteristics:
        // manufacturer, model, firmware, software present; serial and hardware absent.
        let present: Set<CharacteristicIdentifier> = [
            DeviceInformation.manufacturerNameCharacteristic,
            DeviceInformation.modelNumberCharacteristic,
            DeviceInformation.firmwareRevisionCharacteristic,
            DeviceInformation.softwareRevisionCharacteristic,
        ]
        await fakePeripheral.onQueue {
            fakePeripheral.availableServices = [DeviceInformation.service: present]
            fakePeripheral.scriptedReadValues[DeviceInformation.manufacturerNameCharacteristic] = Data("Acme".utf8)
            fakePeripheral.scriptedReadValues[DeviceInformation.modelNumberCharacteristic] = Data("Model-X".utf8)
            fakePeripheral.scriptedReadValues[DeviceInformation.firmwareRevisionCharacteristic] = Data("1.2.3".utf8)
            fakePeripheral.scriptedReadValues[DeviceInformation.softwareRevisionCharacteristic] = Data("9.9".utf8)
        }

        let info = try await peripheral.readDeviceInformation()
        #expect(info.manufacturerName == "Acme")
        #expect(info.modelNumber == "Model-X")
        #expect(info.firmwareRevision == "1.2.3")
        #expect(info.softwareRevision == "9.9")
        // Absent characteristics decode to nil without throwing.
        #expect(info.serialNumber == nil)
        #expect(info.hardwareRevision == nil)
    }

    @Test("readBatteryLevel returns the scripted percentage byte")
    func readBatteryLevel() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        await fakePeripheral.onQueue {
            fakePeripheral.availableServices = [BatteryLevel.service: [BatteryLevel.characteristic]]
            fakePeripheral.scriptedReadValues[BatteryLevel.characteristic] = Data([77])
        }

        let level = try await peripheral.readBatteryLevel()
        #expect(level == 77)
    }
}
