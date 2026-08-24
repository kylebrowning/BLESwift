//
//  ProfilesConsumerTests.swift
//  ConsumerTests
//
//  Out-of-package proof that the `BLESwiftProfiles` product's typed decoders are usable by a
//  real consumer that depends on the root package only by path. Also the type-check gate for
//  the `Examples/HeartRateMonitor` sample, which now uses `BLESwiftProfiles`'
//  `HeartRateMeasurement` rather than defining its own.
//

import BLESwiftCore
import BLESwiftProfiles
import Foundation
import Testing

@Suite("Consumer proof — BLESwiftProfiles decoders from outside the package")
struct ProfilesConsumerTests {

    @Test("BLESwiftProfiles.HeartRateMeasurement decodes an 8-bit reading")
    func decodesHeartRateMeasurement() throws {
        // [flags 0x00][bpm 72]: bit0 clear → 8-bit BPM; bit2 clear → contact not supported.
        let reading = try BLESwiftProfiles.HeartRateMeasurement(bluetoothData: Data([0x00, 72]))
        #expect(reading.beatsPerMinute == 72)
        #expect(reading.sensorContact == .notSupported)
    }

    @Test("The Heart Rate identifiers ship with the product")
    func identifiersShipWithProduct() {
        #expect(BLESwiftProfiles.HeartRateMeasurement.characteristic.uuidString == "2A37")
        #expect(BLESwiftProfiles.HeartRateMeasurement.service.uuidString == "180D")
    }
}
