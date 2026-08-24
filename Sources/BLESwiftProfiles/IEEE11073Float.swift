//
//  IEEE11073Float.swift
//  BLESwiftProfiles
//

import BLESwiftCore
import Foundation

/// Codec for the IEEE 11073-20601 32-bit FLOAT-Type used by medical/health GATT
/// characteristics (e.g. Temperature Measurement).
///
/// Wire layout (4 bytes, little-endian): a signed 24-bit mantissa in bytes 0-2, and a
/// signed 8-bit base-10 exponent in byte 3. The represented value is
/// `mantissa × 10^exponent`.
///
/// Special mantissa values (per IEEE 11073-20601 §A.2) map to floating-point specials:
/// `0x007FFFFF` → NaN, `0x00800000` (NRes, "not at this resolution") → NaN,
/// `0x007FFFFE` → +∞, `0x00800002` → -∞.
enum IEEE11073Float {

    static let nanMantissa: UInt32 = 0x007F_FFFF
    static let nresMantissa: UInt32 = 0x0080_0000
    static let positiveInfinityMantissa: UInt32 = 0x007F_FFFE
    static let negativeInfinityMantissa: UInt32 = 0x0080_0002

    /// Decodes the 4-byte FLOAT-Type at the start of `data`.
    ///
    /// - Throws: ``BLESwiftError/dataOutOfBounds(start:length:count:)`` if fewer than 4
    ///   bytes are available.
    static func decode(_ data: Data) throws -> Double {
        let b0: UInt8 = try data.extract(start: 0, length: 1)
        let b1: UInt8 = try data.extract(start: 1, length: 1)
        let b2: UInt8 = try data.extract(start: 2, length: 1)
        let b3: UInt8 = try data.extract(start: 3, length: 1)
        return decode(b0, b1, b2, b3)
    }

    /// Decodes the four little-endian bytes of a FLOAT-Type.
    static func decode(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Double {
        let raw24 = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16)

        switch raw24 {
        case nanMantissa, nresMantissa:
            return .nan
        case positiveInfinityMantissa:
            return .infinity
        case negativeInfinityMantissa:
            return -.infinity
        default:
            break
        }

        // Sign-extend the 24-bit mantissa into a full Int32.
        let mantissa: Int32 = (raw24 & 0x0080_0000) != 0
            ? Int32(bitPattern: raw24 | 0xFF00_0000)
            : Int32(raw24)
        let exponent = Int8(bitPattern: b3)
        return Double(mantissa) * pow(10.0, Double(exponent))
    }

    /// Encodes `value` as a FLOAT-Type at the given base-10 `exponent`, choosing the
    /// mantissa so that `mantissa × 10^exponent ≈ value`. The mantissa is clamped to the
    /// signed 24-bit range.
    static func encode(_ value: Double, exponent: Int8) -> Data {
        let scaled = (value / pow(10.0, Double(exponent))).rounded()
        let clamped = min(max(scaled, -8_388_608.0), 8_388_607.0) // signed 24-bit range
        let mantissa = Int32(clamped)
        let raw24 = UInt32(bitPattern: mantissa) & 0x00FF_FFFF
        return Data([
            UInt8(raw24 & 0xFF),
            UInt8((raw24 >> 8) & 0xFF),
            UInt8((raw24 >> 16) & 0xFF),
            UInt8(bitPattern: exponent),
        ])
    }
}
