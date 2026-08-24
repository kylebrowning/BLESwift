//
//  GATTDateTime.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The Bluetooth SIG "Date Time" structure (GSS §3.70 Date Time) — the 7-byte building
/// block shared by ``CurrentTime`` and the optional timestamp in ``TemperatureMeasurement``.
///
/// Byte layout (little-endian):
/// - `year` (`UInt16`, bytes 0-1): 1582–9999, or 0 for "unknown".
/// - `month` (`UInt8`, byte 2): 1–12, or 0 for "unknown".
/// - `day` (`UInt8`, byte 3): 1–31, or 0 for "unknown".
/// - `hours` (`UInt8`, byte 4): 0–23.
/// - `minutes` (`UInt8`, byte 5): 0–59.
/// - `seconds` (`UInt8`, byte 6): 0–59.
public struct GATTDateTime: Receivable, Transmittable, Sendable, Equatable {

    public let year: UInt16
    public let month: UInt8
    public let day: UInt8
    public let hours: UInt8
    public let minutes: UInt8
    public let seconds: UInt8

    public init(year: UInt16, month: UInt8, day: UInt8, hours: UInt8, minutes: UInt8, seconds: UInt8) {
        self.year = year
        self.month = month
        self.day = day
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }

    public init(bluetoothData: Data) throws {
        try self.init(bluetoothData: bluetoothData, at: 0)
    }

    /// Decodes a Date Time whose 7 bytes begin at `offset` within `data` — lets a larger
    /// characteristic embed a Date Time without copying a subrange out first.
    init(bluetoothData data: Data, at offset: Int) throws {
        year = try data.extract(start: offset, length: 2)
        month = try data.extract(start: offset + 2, length: 1)
        day = try data.extract(start: offset + 3, length: 1)
        hours = try data.extract(start: offset + 4, length: 1)
        minutes = try data.extract(start: offset + 5, length: 1)
        seconds = try data.extract(start: offset + 6, length: 1)
    }

    public func toBluetoothData() throws -> Data {
        var data = Data()
        data.append(UInt8(year & 0xFF))
        data.append(UInt8((year >> 8) & 0xFF))
        data.append(month)
        data.append(day)
        data.append(hours)
        data.append(minutes)
        data.append(seconds)
        return data
    }

    /// The Gregorian calendar components, in the order `GATTDateTime` stores them.
    var dateComponents: DateComponents {
        DateComponents(
            year: Int(year),
            month: Int(month),
            day: Int(day),
            hour: Int(hours),
            minute: Int(minutes),
            second: Int(seconds)
        )
    }
}
