//
//  PrimitiveRoundTripTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwift

private func assertRoundTrip<T: Transmittable & Receivable & Equatable>(
    _ value: T,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let data = try value.toBluetoothData()
    let decoded = try T(bluetoothData: data)
    #expect(decoded == value, sourceLocation: sourceLocation)
}

@Suite("Fixed-width integer Transmittable/Receivable round-trips")
struct IntegerRoundTripTests {

    @Test func int8RoundTrip() throws { try assertRoundTrip(Int8(-12)) }
    @Test func int16RoundTrip() throws { try assertRoundTrip(Int16(-1234)) }
    @Test func int32RoundTrip() throws { try assertRoundTrip(Int32(-123_456_789)) }
    @Test func int64RoundTrip() throws { try assertRoundTrip(Int64(-123_456_789_012)) }

    @Test func uint8RoundTrip() throws { try assertRoundTrip(UInt8(200)) }
    @Test func uint16RoundTrip() throws { try assertRoundTrip(UInt16(50_000)) }
    @Test func uint32RoundTrip() throws { try assertRoundTrip(UInt32(3_000_000_000)) }
    @Test func uint64RoundTrip() throws { try assertRoundTrip(UInt64(12_345_678_901_234)) }

    @Test("integers encode to exactly MemoryLayout<T>.size bytes")
    func integerEncodedByteCount() throws {
        #expect(try UInt8(1).toBluetoothData().count == 1)
        #expect(try UInt16(1).toBluetoothData().count == 2)
        #expect(try UInt32(1).toBluetoothData().count == 4)
        #expect(try UInt64(1).toBluetoothData().count == 8)
    }
}

@Suite("Data identity Transmittable/Receivable round-trip")
struct DataIdentityRoundTripTests {

    @Test func dataRoundTrip() throws {
        let original = Data([0xAA, 0xBB, 0xCC])
        try assertRoundTrip(original)
    }

    @Test("Data identity conformance does not copy-transform bytes")
    func dataIdentityIsVerbatim() throws {
        let original = Data([0x00, 0xFF, 0x10])
        let encoded = try original.toBluetoothData()
        #expect(encoded == original)
    }
}

@Suite("String Transmittable/Receivable")
struct StringRoundTripTests {

    @Test func stringRoundTrip() throws {
        try assertRoundTrip("Hello, BLESwift! 👋")
    }

    @Test func emptyStringRoundTrip() throws {
        try assertRoundTrip("")
    }

    @Test("invalid UTF-8 throws invalidStringEncoding instead of crashing")
    func stringInvalidUTF8Throws() {
        // 0xFF is never valid as a standalone UTF-8 lead byte.
        let invalid = Data([0xFF, 0xFE])
        #expect(throws: BLESwiftError.invalidStringEncoding) {
            _ = try String(bluetoothData: invalid)
        }
    }
}

@Suite("combine(_:)")
struct CombineTests {

    @Test("concatenates encoded bytes in argument order")
    func combineOrdering() throws {
        let items: [any Transmittable] = [UInt8(0x01), UInt16(0x0302), DataPadding(2), UInt8(0xFF)]
        let combined = try combine(items)

        var expected = Data()
        expected.append(try UInt8(0x01).toBluetoothData())
        expected.append(try UInt16(0x0302).toBluetoothData())
        expected.append(try DataPadding(2).toBluetoothData())
        expected.append(try UInt8(0xFF).toBluetoothData())

        #expect(combined == expected)
        #expect(combined.count == 1 + 2 + 2 + 1)
    }

    @Test("combining an empty array yields empty data")
    func combineEmpty() throws {
        let combined = try combine([])
        #expect(combined.isEmpty)
    }
}
