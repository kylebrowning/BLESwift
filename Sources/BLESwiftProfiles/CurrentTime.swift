//
//  CurrentTime.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The Bluetooth SIG "Current Time" characteristic (GSS §3.62 Current Time, `0x2A2B`).
///
/// Byte layout (10 bytes, little-endian): a 7-byte ``GATTDateTime`` (year, month, day,
/// hours, minutes, seconds), then:
/// - `dayOfWeek` (`UInt8`, byte 7): 0 = unknown, 1 = Monday … 7 = Sunday.
/// - `fractions256` (`UInt8`, byte 8): 1/256ths of a second.
/// - `adjustReason` (`UInt8`, byte 9): an ``AdjustReason`` option set.
public struct CurrentTime: Receivable, Transmittable, Sendable, Equatable {

    /// Why the peripheral's clock last changed (GSS Adjust Reason bit field).
    public struct AdjustReason: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let manualTimeUpdate = AdjustReason(rawValue: 1 << 0)
        public static let externalReferenceTimeUpdate = AdjustReason(rawValue: 1 << 1)
        public static let changeOfTimeZone = AdjustReason(rawValue: 1 << 2)
        public static let changeOfDST = AdjustReason(rawValue: 1 << 3)
    }

    /// The Bluetooth SIG-assigned Current Time service (`0x1805`).
    public static let service = ServiceIdentifier(uuid: "1805")
    /// The Bluetooth SIG-assigned Current Time characteristic (`0x2A2B`).
    public static let characteristic = CharacteristicIdentifier(uuid: "2A2B", service: service)

    /// The date and time portion (bytes 0-6).
    public let dateTime: GATTDateTime
    /// Day of week: 0 = unknown, 1 = Monday … 7 = Sunday.
    public let dayOfWeek: UInt8
    /// Fractional seconds, in 1/256ths of a second.
    public let fractions256: UInt8
    /// Why the clock last changed.
    public let adjustReason: AdjustReason

    public init(dateTime: GATTDateTime, dayOfWeek: UInt8, fractions256: UInt8, adjustReason: AdjustReason) {
        self.dateTime = dateTime
        self.dayOfWeek = dayOfWeek
        self.fractions256 = fractions256
        self.adjustReason = adjustReason
    }

    /// Builds a Current Time from a `Date`, deriving each field (including day of week and
    /// 1/256-second fractions) from `calendar`.
    public init(date: Date, calendar: Calendar = .current, adjustReason: AdjustReason = []) {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday, .nanosecond],
            from: date
        )
        let dateTime = GATTDateTime(
            year: UInt16(components.year ?? 0),
            month: UInt8(components.month ?? 0),
            day: UInt8(components.day ?? 0),
            hours: UInt8(components.hour ?? 0),
            minutes: UInt8(components.minute ?? 0),
            seconds: UInt8(components.second ?? 0)
        )
        // Calendar weekday is 1 = Sunday … 7 = Saturday; GATT is 1 = Monday … 7 = Sunday.
        let calendarWeekday = components.weekday ?? 1
        let dayOfWeek = UInt8(((calendarWeekday + 5) % 7) + 1)
        let nanoseconds = components.nanosecond ?? 0
        let fractions256 = UInt8((nanoseconds * 256) / 1_000_000_000)

        self.init(dateTime: dateTime, dayOfWeek: dayOfWeek, fractions256: fractions256, adjustReason: adjustReason)
    }

    public init(bluetoothData data: Data) throws {
        dateTime = try GATTDateTime(bluetoothData: data, at: 0)
        dayOfWeek = try data.extract(start: 7, length: 1)
        fractions256 = try data.extract(start: 8, length: 1)
        let reason: UInt8 = try data.extract(start: 9, length: 1)
        adjustReason = AdjustReason(rawValue: reason)
    }

    public func toBluetoothData() throws -> Data {
        var data = try dateTime.toBluetoothData()
        data.append(dayOfWeek)
        data.append(fractions256)
        data.append(adjustReason.rawValue)
        return data
    }

    /// Reconstructs a `Date` from the stored fields, or `nil` if the month or day is 0
    /// ("unknown"), since those cannot form a calendar date.
    public func date(in calendar: Calendar = .current) -> Date? {
        guard dateTime.month != 0, dateTime.day != 0 else { return nil }
        return calendar.date(from: dateTime.dateComponents)
    }
}
