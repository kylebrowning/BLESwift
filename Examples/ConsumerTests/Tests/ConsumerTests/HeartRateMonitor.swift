//
//  HeartRateMonitor.swift
//  ConsumerTests
//
//  A small domain type in the style of a consumer. It mirrors `Examples/HeartRateMonitor` in the
//  root package, with the Bluetooth SIG-assigned Heart Rate service and characteristic identifiers
//  and a `Receivable` decoder for the characteristic's wire format. The type lives here and is not
//  imported from the root example, because this package builds against BLESwift only through its
//  published products and, like a real consumer, cannot access the root package's `Examples/`
//  sources.
//

import BLESwift
import Foundation

/// The Bluetooth SIG-assigned identifiers for the standard Heart Rate service and its
/// Heart Rate Measurement characteristic.
enum HeartRateGATT {
    static let service = ServiceIdentifier(uuid: "180D")
    static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)
    static let bodySensorLocation = CharacteristicIdentifier(uuid: "2A38", service: service)
}

/// Decodes the Bluetooth SIG "Heart Rate Measurement" characteristic (`2A37`) wire format: a
/// one-byte flags field followed by a heart-rate value. Bit 0 of the flags selects the size of the
/// value (0 = 8-bit `UInt8`, 1 = 16-bit `UInt16`, little-endian).
struct HeartRateMeasurement: Receivable, Equatable {
    let beatsPerMinute: Int

    init(bluetoothData data: Data) throws {
        let flags: UInt8 = try data.extract(start: 0, length: 1)
        let valueIs16Bit = (flags & 0x01) != 0

        if valueIs16Bit {
            let value: UInt16 = try data.extract(start: 1, length: 2)
            beatsPerMinute = Int(value)
        } else {
            let value: UInt8 = try data.extract(start: 1, length: 1)
            beatsPerMinute = Int(value)
        }
    }

    /// Encodes the value back to the same wire format, always in the 8-bit form. Tests use this to
    /// script a `scriptedReadValues` entry from a typed value instead of raw bytes.
    static func wireData(beatsPerMinute: UInt8) -> Data {
        Data([0x00, beatsPerMinute])
    }
}
