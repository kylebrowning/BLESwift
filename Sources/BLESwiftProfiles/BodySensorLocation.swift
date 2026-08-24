//
//  BodySensorLocation.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The Bluetooth SIG "Body Sensor Location" characteristic (GSS §3.34 Body Sensor
/// Location, `0x2A38`).
///
/// Byte layout: a single `UInt8` enumerating where on the body the sensor sits. Values
/// 7–255 are reserved by the SIG; they decode to ``Location/reserved(_:)`` rather than
/// throwing, so an unknown value from a nonstandard peripheral is preserved, not rejected.
public struct BodySensorLocation: Receivable, Sendable, Equatable {

    /// Where on the body a heart-rate (or similar) sensor is worn.
    public enum Location: Sendable, Equatable {
        case other
        case chest
        case wrist
        case finger
        case hand
        case earLobe
        case foot
        /// A value the SIG has reserved (7–255), preserved verbatim.
        case reserved(UInt8)

        init(rawValue: UInt8) {
            switch rawValue {
            case 0: self = .other
            case 1: self = .chest
            case 2: self = .wrist
            case 3: self = .finger
            case 4: self = .hand
            case 5: self = .earLobe
            case 6: self = .foot
            default: self = .reserved(rawValue)
            }
        }
    }

    /// The Bluetooth SIG-assigned Heart Rate service (`0x180D`).
    public static let service = ServiceIdentifier(uuid: "180D")
    /// The Bluetooth SIG-assigned Body Sensor Location characteristic (`0x2A38`).
    public static let characteristic = CharacteristicIdentifier(uuid: "2A38", service: service)

    /// The decoded sensor location.
    public let location: Location

    public init(bluetoothData data: Data) throws {
        let raw: UInt8 = try data.extract(start: 0, length: 1)
        location = Location(rawValue: raw)
    }
}
