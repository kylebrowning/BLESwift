//
//  ProfilesTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
@testable import BLESwiftProfiles

/// Decode / round-trip tests for every `BLESwiftProfiles` type, plus direct tests of the
/// internal `IEEE11073Float` codec. Every byte vector is annotated with the GSS field
/// breakdown it was hand-built from; decoding is little-endian throughout.
@Suite("BLESwiftProfiles decoders")
struct ProfilesTests {

    // MARK: - Identifier ↔ assigned-name ties

    @Test("Each profile type's identifiers resolve to their SIG-assigned names")
    func identifierNames() {
        #expect(GATTAssignedNumbers.name(for: HeartRateMeasurement.service) == "Heart Rate")
        #expect(GATTAssignedNumbers.name(for: HeartRateMeasurement.characteristic) == "Heart Rate Measurement")

        #expect(GATTAssignedNumbers.name(for: BatteryLevel.service) == "Battery")
        #expect(GATTAssignedNumbers.name(for: BatteryLevel.characteristic) == "Battery Level")

        #expect(GATTAssignedNumbers.name(for: DeviceInformation.service) == "Device Information")
        #expect(GATTAssignedNumbers.name(for: DeviceInformation.manufacturerNameCharacteristic) == "Manufacturer Name String")
        #expect(GATTAssignedNumbers.name(for: DeviceInformation.modelNumberCharacteristic) == "Model Number String")
        #expect(GATTAssignedNumbers.name(for: DeviceInformation.serialNumberCharacteristic) == "Serial Number String")
        #expect(GATTAssignedNumbers.name(for: DeviceInformation.firmwareRevisionCharacteristic) == "Firmware Revision String")
        #expect(GATTAssignedNumbers.name(for: DeviceInformation.hardwareRevisionCharacteristic) == "Hardware Revision String")
        #expect(GATTAssignedNumbers.name(for: DeviceInformation.softwareRevisionCharacteristic) == "Software Revision String")

        #expect(GATTAssignedNumbers.name(for: CurrentTime.service) == "Current Time")
        #expect(GATTAssignedNumbers.name(for: CurrentTime.characteristic) == "Current Time")

        #expect(GATTAssignedNumbers.name(for: BodySensorLocation.service) == "Heart Rate")
        #expect(GATTAssignedNumbers.name(for: BodySensorLocation.characteristic) == "Body Sensor Location")

        #expect(GATTAssignedNumbers.name(for: CSCMeasurement.service) == "Cycling Speed and Cadence")
        #expect(GATTAssignedNumbers.name(for: CSCMeasurement.characteristic) == "CSC Measurement")

        #expect(GATTAssignedNumbers.name(for: CyclingPowerMeasurement.service) == "Cycling Power")
        #expect(GATTAssignedNumbers.name(for: CyclingPowerMeasurement.characteristic) == "Cycling Power Measurement")

        #expect(GATTAssignedNumbers.name(for: TemperatureMeasurement.service) == "Health Thermometer")
        #expect(GATTAssignedNumbers.name(for: TemperatureMeasurement.characteristic) == "Temperature Measurement")
    }

    // MARK: - IEEE 11073 FLOAT-Type

    @Test("IEEE11073Float decodes 36.5 °C: mantissa 365, exponent -1")
    func ieeeFloatDecodesExampleValue() throws {
        // 36.5 = 365 × 10^-1. Mantissa 365 = 0x00016D as signed 24-bit LE (0x6D 0x01 0x00);
        // exponent -1 = 0xFF.
        let value = try IEEE11073Float.decode(Data([0x6D, 0x01, 0x00, 0xFF]))
        #expect(value == 36.5)
    }

    @Test("IEEE11073Float round-trips 36.5 at exponent -1 to the documented bytes")
    func ieeeFloatRoundTrip() throws {
        let encoded = IEEE11073Float.encode(36.5, exponent: -1)
        #expect(encoded == Data([0x6D, 0x01, 0x00, 0xFF]))
        #expect(try IEEE11073Float.decode(encoded) == 36.5)
    }

    @Test("IEEE11073Float decodes a negative mantissa")
    func ieeeFloatNegativeMantissa() throws {
        // -365 × 10^-1 = -36.5. -365 as signed 24-bit = 0xFFFE93 → LE 0x93 0xFE 0xFF; exp -1.
        let value = try IEEE11073Float.decode(Data([0x93, 0xFE, 0xFF, 0xFF]))
        #expect(value == -36.5)
    }

    @Test("IEEE11073Float maps special mantissa values")
    func ieeeFloatSpecials() throws {
        // NaN: mantissa 0x7FFFFF.
        #expect(try IEEE11073Float.decode(Data([0xFF, 0xFF, 0x7F, 0x00])).isNaN)
        // NRes: mantissa 0x800000 → NaN.
        #expect(try IEEE11073Float.decode(Data([0x00, 0x00, 0x80, 0x00])).isNaN)
        // +Inf: mantissa 0x7FFFFE.
        #expect(try IEEE11073Float.decode(Data([0xFE, 0xFF, 0x7F, 0x00])) == .infinity)
        // -Inf: mantissa 0x800002.
        #expect(try IEEE11073Float.decode(Data([0x02, 0x00, 0x80, 0x00])) == -.infinity)
    }

    @Test("IEEE11073Float throws on truncated input")
    func ieeeFloatTruncated() {
        #expect(throws: BLESwiftError.self) {
            _ = try IEEE11073Float.decode(Data([0x6D, 0x01, 0x00]))
        }
    }

    // MARK: - HeartRateMeasurement

    @Test("HeartRateMeasurement decodes 8-bit BPM with no optional fields")
    func heartRate8Bit() throws {
        // [flags 0x00][bpm 72]. bit0=0 → u8 BPM; bit2=0 → contact not supported.
        let m = try HeartRateMeasurement(bluetoothData: Data([0x00, 72]))
        #expect(m.beatsPerMinute == 72)
        #expect(m.sensorContact == .notSupported)
        #expect(m.energyExpended == nil)
        #expect(m.rrIntervals.isEmpty)
    }

    @Test("HeartRateMeasurement decodes 16-bit BPM, contact, energy, and RR intervals")
    func heartRateFullFlags() throws {
        // flags 0x1F = bit0(u16 BPM) | bit1(detected) | bit2(supported) | bit3(energy) | bit4(RR)
        // [flags 0x1F][bpm 0x012C = 300][energy 0x0064 = 100][rr 0x0100 = 256][rr 0x0200 = 512]
        let data = Data([0x1F, 0x2C, 0x01, 0x64, 0x00, 0x00, 0x01, 0x00, 0x02])
        let m = try HeartRateMeasurement(bluetoothData: data)
        #expect(m.beatsPerMinute == 300)
        #expect(m.sensorContact == .detected)
        #expect(m.energyExpended == 100)
        #expect(m.rrIntervals == [256, 512])
    }

    @Test("HeartRateMeasurement reports supported-but-not-detected contact")
    func heartRateContactNotDetected() throws {
        // flags 0x04 = bit2 supported, bit1 clear → notDetected.
        let m = try HeartRateMeasurement(bluetoothData: Data([0x04, 60]))
        #expect(m.sensorContact == .notDetected)
    }

    @Test("HeartRateMeasurement throws on truncated payload")
    func heartRateTruncated() {
        #expect(throws: BLESwiftError.self) {
            _ = try HeartRateMeasurement(bluetoothData: Data([0x01, 0x2C])) // bit0 wants u16, only 1 byte
        }
    }

    // MARK: - BatteryLevel

    @Test("BatteryLevel decodes and round-trips a valid percentage")
    func batteryLevelRoundTrip() throws {
        let level = try BatteryLevel(bluetoothData: Data([88]))
        #expect(level.percentage == 88)
        #expect(try level.toBluetoothData() == Data([88]))
        #expect(try BatteryLevel(bluetoothData: level.toBluetoothData()) == level)
    }

    @Test("BatteryLevel rejects a value above 100")
    func batteryLevelOutOfRange() {
        #expect(throws: BLESwiftError.invalidArgument("Battery level out of range: 101")) {
            _ = try BatteryLevel(bluetoothData: Data([101]))
        }
    }

    @Test("BatteryLevel throws on empty input")
    func batteryLevelTruncated() {
        #expect(throws: BLESwiftError.self) {
            _ = try BatteryLevel(bluetoothData: Data())
        }
    }

    // MARK: - BodySensorLocation

    @Test("BodySensorLocation decodes a known and a reserved value")
    func bodySensorLocation() throws {
        #expect(try BodySensorLocation(bluetoothData: Data([0x02])).location == .wrist)
        #expect(try BodySensorLocation(bluetoothData: Data([0x00])).location == .other)
        // 0x40 = 64, in the reserved 7…255 range.
        #expect(try BodySensorLocation(bluetoothData: Data([0x40])).location == .reserved(64))
    }

    @Test("BodySensorLocation throws on empty input")
    func bodySensorLocationTruncated() {
        #expect(throws: BLESwiftError.self) {
            _ = try BodySensorLocation(bluetoothData: Data())
        }
    }

    // MARK: - GATTDateTime & CurrentTime

    @Test("GATTDateTime decodes and round-trips")
    func gattDateTimeRoundTrip() throws {
        // year 2024 = 0x07E8 → LE 0xE8 0x07; month 8; day 24; 13:45:30.
        let data = Data([0xE8, 0x07, 8, 24, 13, 45, 30])
        let dt = try GATTDateTime(bluetoothData: data)
        #expect(dt.year == 2024)
        #expect(dt.month == 8)
        #expect(dt.day == 24)
        #expect(dt.hours == 13)
        #expect(dt.minutes == 45)
        #expect(dt.seconds == 30)
        #expect(try dt.toBluetoothData() == data)
    }

    @Test("CurrentTime decodes and round-trips, with adjust reason flags")
    func currentTimeRoundTrip() throws {
        // [DateTime 2024-08-24 13:45:30][dayOfWeek 6 = Saturday][fractions 128]
        // [adjustReason 0x05 = manualTimeUpdate | changeOfTimeZone]
        let data = Data([0xE8, 0x07, 8, 24, 13, 45, 30, 6, 128, 0x05])
        let time = try CurrentTime(bluetoothData: data)
        #expect(time.dateTime.year == 2024)
        #expect(time.dayOfWeek == 6)
        #expect(time.fractions256 == 128)
        #expect(time.adjustReason.contains(.manualTimeUpdate))
        #expect(time.adjustReason.contains(.changeOfTimeZone))
        #expect(!time.adjustReason.contains(.changeOfDST))
        #expect(try time.toBluetoothData() == data)
    }

    @Test("CurrentTime.date is nil when month or day is unknown (0)")
    func currentTimeUnknownDate() throws {
        // month 0 = unknown.
        let data = Data([0xE8, 0x07, 0, 24, 13, 45, 30, 6, 0, 0x00])
        let time = try CurrentTime(bluetoothData: data)
        #expect(time.date() == nil)
    }

    @Test("CurrentTime(date:) sets the GATT day-of-week and reconstructs the date")
    func currentTimeFromDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2024-08-24 is a Saturday → GATT day of week 6.
        let components = DateComponents(year: 2024, month: 8, day: 24, hour: 13, minute: 45, second: 30)
        let date = calendar.date(from: components)!
        let time = CurrentTime(date: date, calendar: calendar, adjustReason: .manualTimeUpdate)
        #expect(time.dateTime.year == 2024)
        #expect(time.dateTime.month == 8)
        #expect(time.dateTime.day == 24)
        #expect(time.dayOfWeek == 6)
        #expect(time.date(in: calendar) == date)
    }

    // MARK: - CSCMeasurement

    @Test("CSCMeasurement decodes both wheel and crank data")
    func cscBothPresent() throws {
        // flags 0x03 = wheel(bit0) + crank(bit1).
        // [flags 0x03][wheel cumulative 0x0000000A = 10][wheel event 0x0400 = 1024]
        // [crank cumulative 0x0005 = 5][crank event 0x0200 = 512]
        let data = Data([0x03, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x04, 0x05, 0x00, 0x00, 0x02])
        let m = try CSCMeasurement(bluetoothData: data)
        #expect(m.wheel?.cumulativeRevolutions == 10)
        #expect(m.wheel?.lastEventTime == 1024)
        #expect(m.crank?.cumulativeRevolutions == 5)
        #expect(m.crank?.lastEventTime == 512)
    }

    @Test("CSCMeasurement decodes crank-only data (wheel absent)")
    func cscCrankOnly() throws {
        // flags 0x02 = crank only. [flags][crank cumulative 7][crank event 256]
        let data = Data([0x02, 0x07, 0x00, 0x00, 0x01])
        let m = try CSCMeasurement(bluetoothData: data)
        #expect(m.wheel == nil)
        #expect(m.crank?.cumulativeRevolutions == 7)
        #expect(m.crank?.lastEventTime == 256)
    }

    @Test("CSCMeasurement throws when a flagged group is truncated")
    func cscTruncated() {
        // flags 0x01 promises wheel data (6 bytes) but only 3 follow.
        #expect(throws: BLESwiftError.self) {
            _ = try CSCMeasurement(bluetoothData: Data([0x01, 0x0A, 0x00, 0x00]))
        }
    }

    // MARK: - CyclingPowerMeasurement

    @Test("CyclingPowerMeasurement decodes flags-off (power only)")
    func cyclingPowerMinimal() throws {
        // flags 0x0000, power 0x00C8 = 200 W.
        let data = Data([0x00, 0x00, 0xC8, 0x00])
        let m = try CyclingPowerMeasurement(bluetoothData: data)
        #expect(m.instantaneousPower == 200)
        #expect(m.pedalPowerBalance == nil)
        #expect(m.pedalPowerBalanceReference == .unknown)
        #expect(m.accumulatedTorque == nil)
        #expect(m.accumulatedTorqueSource == .wheelBased)
        #expect(m.wheelRevolutions == nil)
        #expect(m.offsetCompensationIndicator == false)
    }

    @Test("CyclingPowerMeasurement decodes balance, torque, wheel/crank, and extreme angles")
    func cyclingPowerRichFlags() throws {
        // flags = bit0|bit1|bit2|bit3|bit4|bit5|bit8 = 0x013F.
        //   bit0 pedalPowerBalance, bit1 reference=left, bit2 accumulatedTorque,
        //   bit3 torqueSource=crank, bit4 wheelRev, bit5 crankRev, bit8 extremeAngles.
        // power 0x0064 = 100 W.
        // pedalPowerBalance 0x32 = 50 (i.e. 25%).
        // accumulatedTorque 0x0140 = 320 (10 N·m).
        // wheel cumulative 0x000003E8 = 1000, wheel event 0x0800 = 2048.
        // crank cumulative 0x0064 = 100, crank event 0x0400 = 1024.
        // extremeAngles raw24 = 0x00ABCD → LE 0xCD 0xAB 0x00; max = 0xBCD = 3021, min = 0x00A = 10.
        var data = Data([0x3F, 0x01, 0x64, 0x00])   // flags 0x013F, power 100
        data.append(0x32)                            // pedalPowerBalance 50
        data.append(contentsOf: [0x40, 0x01])        // accumulatedTorque 320
        data.append(contentsOf: [0xE8, 0x03, 0x00, 0x00, 0x00, 0x08]) // wheel 1000, event 2048
        data.append(contentsOf: [0x64, 0x00, 0x00, 0x04])             // crank 100, event 1024
        data.append(contentsOf: [0xCD, 0xAB, 0x00]) // extremeAngles raw24 0x00ABCD

        let m = try CyclingPowerMeasurement(bluetoothData: data)
        #expect(m.instantaneousPower == 100)
        #expect(m.pedalPowerBalance == 50)
        #expect(m.pedalPowerBalanceReference == .left)
        #expect(m.accumulatedTorque == 320)
        #expect(m.accumulatedTorqueSource == .crankBased)
        #expect(m.wheelRevolutions?.cumulativeRevolutions == 1000)
        #expect(m.wheelRevolutions?.lastEventTime == 2048)
        #expect(m.crankRevolutions?.cumulativeRevolutions == 100)
        #expect(m.crankRevolutions?.lastEventTime == 1024)
        #expect(m.extremeAngles?.maximum == 0xBCD)
        #expect(m.extremeAngles?.minimum == 0x00A)
    }

    @Test("CyclingPowerMeasurement decodes a negative instantaneous power")
    func cyclingPowerNegativePower() throws {
        // power 0xFFF6 = -10 (signed).
        let m = try CyclingPowerMeasurement(bluetoothData: Data([0x00, 0x00, 0xF6, 0xFF]))
        #expect(m.instantaneousPower == -10)
    }

    @Test("CyclingPowerMeasurement decodes the offset compensation indicator flag")
    func cyclingPowerOffsetIndicator() throws {
        // flags 0x1000 = bit12. power 50.
        let m = try CyclingPowerMeasurement(bluetoothData: Data([0x00, 0x10, 0x32, 0x00]))
        #expect(m.offsetCompensationIndicator == true)
    }

    @Test("CyclingPowerMeasurement throws when a flagged field is truncated")
    func cyclingPowerTruncated() {
        // flags 0x0004 promises accumulatedTorque (2 bytes) but none follow.
        #expect(throws: BLESwiftError.self) {
            _ = try CyclingPowerMeasurement(bluetoothData: Data([0x04, 0x00, 0x64, 0x00]))
        }
    }

    // MARK: - TemperatureMeasurement

    @Test("TemperatureMeasurement decodes Celsius with no optional fields")
    func temperatureCelsius() throws {
        // flags 0x00 (celsius, no timestamp, no type). value 36.5 = 0x6D 0x01 0x00 0xFF.
        let data = Data([0x00, 0x6D, 0x01, 0x00, 0xFF])
        let m = try TemperatureMeasurement(bluetoothData: data)
        #expect(m.temperature == 36.5)
        #expect(m.unit == .celsius)
        #expect(m.timestamp == nil)
        #expect(m.type == nil)
    }

    @Test("TemperatureMeasurement decodes Fahrenheit with timestamp and type")
    func temperatureFullFlags() throws {
        // flags 0x07 = fahrenheit(bit0) | timestamp(bit1) | type(bit2).
        // value 98.6 = 986 × 10^-1. 986 = 0x0003DA → LE 0xDA 0x03 0x00; exp -1 = 0xFF.
        // timestamp 2024-08-24 13:45:30. type 0x02 = body.
        var data = Data([0x07, 0xDA, 0x03, 0x00, 0xFF])
        data.append(contentsOf: [0xE8, 0x07, 8, 24, 13, 45, 30]) // GATTDateTime
        data.append(0x02)                                        // type = body
        let m = try TemperatureMeasurement(bluetoothData: data)
        #expect(abs(m.temperature - 98.6) < 0.0001) // 986 × 10^-1, subject to binary FP rounding
        #expect(m.unit == .fahrenheit)
        #expect(m.timestamp?.year == 2024)
        #expect(m.timestamp?.day == 24)
        #expect(m.type == .body)
    }

    @Test("TemperatureMeasurement decodes a reserved temperature type")
    func temperatureReservedType() throws {
        // flags 0x04 (type present, celsius, no timestamp). value 36.5. type 0x63 = 99 reserved.
        let data = Data([0x04, 0x6D, 0x01, 0x00, 0xFF, 0x63])
        let m = try TemperatureMeasurement(bluetoothData: data)
        #expect(m.type == .reserved(99))
    }

    @Test("TemperatureMeasurement throws on truncated float")
    func temperatureTruncated() {
        #expect(throws: BLESwiftError.self) {
            _ = try TemperatureMeasurement(bluetoothData: Data([0x00, 0x6D, 0x01])) // only 2 of 4 float bytes
        }
    }
}
