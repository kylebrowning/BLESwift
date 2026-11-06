//
//  CharacteristicDecoder.swift
//  BLESwiftExplorer
//
//  Decodes the raw `Data` of a characteristic into a readable string. It uses the `BLESwiftProfiles`
//  types if it recognizes the UUID, and falls back to a hex dump for an unknown UUID. Every profile
//  characteristic identifier is referenced here.
//

import BLESwift
import BLESwiftProfiles
import Foundation

enum CharacteristicDecoder {

    /// Every characteristic UUID that this app can decode as a typed value. The browser uses it for
    /// labels.
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

    /// Hex fallback for unknown characteristics (and the default display of raw reads).
    static func hex(_ data: Data) -> String {
        data.isEmpty ? "(empty)" : data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Returns a readable typed decode if the UUID is recognized. Otherwise returns a hex dump.
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
