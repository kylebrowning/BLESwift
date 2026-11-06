//
//  ProfilesConsumerTests.swift
//  ConsumerTests
//
//  Proof outside the package that the typed decoders of the `BLESwiftProfiles` product work for a
//  real consumer, which depends on the root package only by path. The file is also the type-check
//  gate for the `Examples/HeartRateMonitor` sample, which uses `BLESwiftProfiles`'s
//  `HeartRateMeasurement` and does not define its own.
//

import BLESwiftCore
import BLESwiftProfiles
import Foundation
import Testing

@Suite("Consumer proof — BLESwiftProfiles decoders from outside the package")
struct ProfilesConsumerTests {

    @Test("BLESwiftProfiles.HeartRateMeasurement decodes an 8-bit reading")
    func decodesHeartRateMeasurement() throws {
        // [flags 0x00][bpm 72]: bit 0 is clear, so the BPM is 8-bit. Bit 2 is clear, so contact is
        // not supported.
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
