//
//  HeartRateMonitor.swift
//  ConsumerTests
//
//  A small consumer-style domain type, mirroring `Examples/HeartRateMonitor` in the root
//  package: the Bluetooth SIG-assigned Heart Rate service/characteristic identifiers, and a
//  `Receivable` decoder for the characteristic's wire format. Exists here (rather than being
//  imported from the root example) because this package builds against BLESwift only via
//  its published products — it has no access to the root package's `Examples/` sources,
//  same as any real consumer wouldn't.
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

/// Decodes the Bluetooth SIG "Heart Rate Measurement" characteristic (`2A37`) wire
/// format: a one-byte flags field, followed by either an 8-bit or 16-bit heart-rate
/// value depending on flags bit 0 (0 = `UInt8`, 1 = `UInt16`, little-endian).
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

    /// Encodes back to the same wire format, always using the 8-bit form — lets tests
    /// script a `scriptedReadValues` entry from a typed value instead of raw bytes.
    static func wireData(beatsPerMinute: UInt8) -> Data {
        Data([0x00, beatsPerMinute])
    }
}
