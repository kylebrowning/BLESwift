//
//  TemperatureMeasurement.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The Bluetooth SIG "Temperature Measurement" characteristic (GSS §3.199 Temperature
/// Measurement, `0x2A1C`) from the Health Thermometer service.
///
/// Byte layout (little-endian): a one-byte `Flags` field, a 4-byte IEEE 11073-20601
/// FLOAT-Type temperature (see ``/BLESwiftProfiles``), then flag-driven optional fields:
/// - Flags bit 0 — Temperature Unit: 0 = Celsius, 1 = Fahrenheit.
/// - Flags bit 1 — Time Stamp present: a 7-byte ``GATTDateTime``.
/// - Flags bit 2 — Temperature Type present (`UInt8`).
public struct TemperatureMeasurement: Receivable, Sendable, Equatable {

    /// The unit the temperature is expressed in (Flags bit 0).
    public enum Unit: Sendable, Equatable {
        case celsius
        case fahrenheit
    }

    /// The measurement site (Flags bit 2). Values outside 1–9 decode to
    /// ``TemperatureType/reserved(_:)`` rather than throwing.
    public enum TemperatureType: Sendable, Equatable {
        case armpit
        case body
        case ear
        case finger
        case gastroIntestinal
        case mouth
        case rectum
        case toe
        case tympanum
        case reserved(UInt8)

        init(rawValue: UInt8) {
            switch rawValue {
            case 1: self = .armpit
            case 2: self = .body
            case 3: self = .ear
            case 4: self = .finger
            case 5: self = .gastroIntestinal
            case 6: self = .mouth
            case 7: self = .rectum
            case 8: self = .toe
            case 9: self = .tympanum
            default: self = .reserved(rawValue)
            }
        }
    }

    /// The Bluetooth SIG-assigned Health Thermometer service (`0x1809`).
    public static let service = ServiceIdentifier(uuid: "1809")
    /// The Bluetooth SIG-assigned Temperature Measurement characteristic (`0x2A1C`).
    public static let characteristic = CharacteristicIdentifier(uuid: "2A1C", service: service)

    /// The temperature value, decoded from the IEEE 11073 FLOAT-Type.
    public let temperature: Double
    /// The unit `temperature` is expressed in.
    public let unit: Unit
    /// The measurement time, if reported (Flags bit 1).
    public let timestamp: GATTDateTime?
    /// The measurement site, if reported (Flags bit 2).
    public let type: TemperatureType?

    public init(bluetoothData data: Data) throws {
        let flags: UInt8 = try data.extract(start: 0, length: 1)
        temperature = try IEEE11073Float.decode(data.subdata(in: 1..<data.count))
        unit = (flags & 0x01) != 0 ? .fahrenheit : .celsius
        var offset = 5

        if (flags & 0x02) != 0 {
            timestamp = try GATTDateTime(bluetoothData: data, at: offset)
            offset += 7
        } else {
            timestamp = nil
        }

        if (flags & 0x04) != 0 {
            let raw: UInt8 = try data.extract(start: offset, length: 1)
            type = TemperatureType(rawValue: raw)
        } else {
            type = nil
        }
    }
}
