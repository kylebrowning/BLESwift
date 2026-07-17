//
//  DataExtractionTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwift

@Suite("Data.extract")
struct DataExtractionTests {

    @Test("extracts a value at a valid, aligned offset")
    func extractValid() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let value: UInt32 = try data.extract(start: 0, length: 4)
        let expected = UInt32(0x01) | (UInt32(0x02) << 8) | (UInt32(0x03) << 16) | (UInt32(0x04) << 24)
        #expect(value == expected)
    }

    @Test("succeeds at a misaligned offset using loadUnaligned, not load(as:)")
    func extractMisaligned() throws {
        // Offset 1 is not 4-byte aligned for a UInt32 read;
        // UnsafeRawBufferPointer.load(as:) would trap here.
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        let value: UInt32 = try data.extract(start: 1, length: 4)
        let expected = UInt32(0x01) | (UInt32(0x02) << 8) | (UInt32(0x03) << 16) | (UInt32(0x04) << 24)
        #expect(value == expected)
    }

    @Test("throws dataOutOfBounds when length exceeds available bytes")
    func extractOutOfBounds() {
        let data = Data([0x01, 0x02])
        #expect(throws: BLESwiftError.dataOutOfBounds(start: 0, length: 4, count: 2)) {
            let _: UInt32 = try data.extract(start: 0, length: 4)
        }
    }

    @Test("throws instead of overflowing when start is pathologically large")
    func extractOverflowGuard() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        #expect(throws: BLESwiftError.self) {
            let _: UInt8 = try data.extract(start: Int.max - 1, length: 4)
        }
    }

    @Test("throws for a negative start")
    func extractNegativeStart() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        #expect(throws: BLESwiftError.self) {
            let _: UInt8 = try data.extract(start: -1, length: 1)
        }
    }

    @Test("throws for a non-positive length")
    func extractZeroLength() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        #expect(throws: BLESwiftError.self) {
            let _: UInt8 = try data.extract(start: 0, length: 0)
        }
    }

    @Test("throws when length does not match the target type's size")
    func extractLengthMismatch() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        #expect(throws: BLESwiftError.self) {
            let _: UInt32 = try data.extract(start: 0, length: 2)
        }
    }
}
