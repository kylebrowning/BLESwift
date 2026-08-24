//
//  HeartRateMeasurement.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The Bluetooth SIG "Heart Rate Measurement" characteristic (GSS §3.113 Heart Rate
/// Measurement, `0x2A37`).
///
/// Byte layout (little-endian): a one-byte `Flags` field, then the flag-driven fields in
/// order:
/// - Flags bit 0 — heart-rate value format: 0 = `UInt8`, 1 = `UInt16`.
/// - Flags bits 1-2 — sensor contact status: bit 2 = supported, bit 1 = contact detected.
/// - Flags bit 3 — Energy Expended present (`UInt16`, kilojoules).
/// - Flags bit 4 — one or more RR-Interval values present (`UInt16` each, units of
///   1/1024 s), filling the remainder of the payload.
public struct HeartRateMeasurement: Receivable, Sendable, Equatable {

    /// The peripheral's skin-contact status, from Flags bits 1-2.
    public enum SensorContact: Sendable, Equatable {
        /// The sensor does not report a contact status (bit 2 clear).
        case notSupported
        /// The sensor supports contact detection and reports no contact.
        case notDetected
        /// The sensor supports contact detection and reports good contact.
        case detected
    }

    /// The Bluetooth SIG-assigned Heart Rate service (`0x180D`).
    public static let service = ServiceIdentifier(uuid: "180D")
    /// The Bluetooth SIG-assigned Heart Rate Measurement characteristic (`0x2A37`).
    public static let characteristic = CharacteristicIdentifier(uuid: "2A37", service: service)

    /// The heart rate, in beats per minute.
    public let beatsPerMinute: Int
    /// The sensor's skin-contact status.
    public let sensorContact: SensorContact
    /// Cumulative energy expended, in kilojoules, if reported.
    public let energyExpended: UInt16?
    /// RR-Interval values, in units of 1/1024 second, if reported.
    public let rrIntervals: [UInt16]

    public init(bluetoothData data: Data) throws {
        let flags: UInt8 = try data.extract(start: 0, length: 1)
        var offset = 1

        if (flags & 0x01) != 0 {
            let value: UInt16 = try data.extract(start: offset, length: 2)
            beatsPerMinute = Int(value)
            offset += 2
        } else {
            let value: UInt8 = try data.extract(start: offset, length: 1)
            beatsPerMinute = Int(value)
            offset += 1
        }

        if (flags & 0x04) != 0 {
            sensorContact = (flags & 0x02) != 0 ? .detected : .notDetected
        } else {
            sensorContact = .notSupported
        }

        if (flags & 0x08) != 0 {
            let energy: UInt16 = try data.extract(start: offset, length: 2)
            energyExpended = energy
            offset += 2
        } else {
            energyExpended = nil
        }

        if (flags & 0x10) != 0 {
            var intervals: [UInt16] = []
            while data.count - offset >= 2 {
                intervals.append(try data.extract(start: offset, length: 2))
                offset += 2
            }
            rrIntervals = intervals
        } else {
            rrIntervals = []
        }
    }
}
