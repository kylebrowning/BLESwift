//
//  CharacteristicDecoder.swift
//  BLESwiftExplorer
//
//  Decodes a characteristic's raw `Data` into a human-readable string using the
//  `BLESwiftProfiles` types (Task 6) when the UUID is recognized, falling back to a hex
//  dump for anything unknown. Every profile characteristic identifier is referenced here.
//

import BLESwift
import BLESwiftProfiles
import Foundation

enum CharacteristicDecoder {

    /// Every characteristic UUID this app can decode typed, for labelling the browser.
    static let knownCharacteristics: [CharacteristicIdentifier] = [
        HeartRateMeasurement.characteristic,
        BatteryLevel.characteristic,
        BodySensorLocation.characteristic,
        CurrentTime.characteristic,
        CSCMeasurement.characteristic,
        CyclingPowerMeasurement.characteristic,
        TemperatureMeasurement.characteristic,
    ] + DeviceInformation.characteristics

    static func isKnown(_ characteristic: CharacteristicIdentifier) -> Bool {
        knownCharacteristics.contains { $0.uuidString.caseInsensitiveCompare(characteristic.uuidString) == .orderedSame }
    }

    /// Hex fallback for unknown characteristics (and the default rendering of raw reads).
    static func hex(_ data: Data) -> String {
        data.isEmpty ? "(empty)" : data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Returns a typed, human-readable decode when the UUID is recognized, else a hex dump.
    static func decode(_ data: Data, for characteristic: CharacteristicIdentifier) -> String {
        let uuid = characteristic.uuidString.uppercased()
        do {
            switch uuid {
            case HeartRateMeasurement.characteristic.uuidString.uppercased():
                let m = try HeartRateMeasurement(bluetoothData: data)
                return "\(m.beatsPerMinute) bpm, contact: \(m.sensorContact), RR: \(m.rrIntervals.count)"
            case BatteryLevel.characteristic.uuidString.uppercased():
                let b = try BatteryLevel(bluetoothData: data)
                return "\(b.percentage)%"
            case BodySensorLocation.characteristic.uuidString.uppercased():
                let l = try BodySensorLocation(bluetoothData: data)
                return "location: \(l.location)"
            case CurrentTime.characteristic.uuidString.uppercased():
                let t = try CurrentTime(bluetoothData: data)
                return "current time: \(t.dateTime)"
            case CSCMeasurement.characteristic.uuidString.uppercased():
                let c = try CSCMeasurement(bluetoothData: data)
                return "CSC wheel: \(c.wheel != nil), crank: \(c.crank != nil)"
            case CyclingPowerMeasurement.characteristic.uuidString.uppercased():
                let p = try CyclingPowerMeasurement(bluetoothData: data)
                return "\(p.instantaneousPower) W"
            case TemperatureMeasurement.characteristic.uuidString.uppercased():
                let t = try TemperatureMeasurement(bluetoothData: data)
                return "\(t.temperature) °\(t.unit == .celsius ? "C" : "F")"
            default:
                return hex(data)
            }
        } catch {
            return "decode error: \(error) — raw: \(hex(data))"
        }
    }
}
