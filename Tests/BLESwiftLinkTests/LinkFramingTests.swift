//
//  LinkFramingTests.swift
//  BLESwiftLinkTests
//

import BLESwiftLink
import Foundation
import Testing

@Suite("LinkFraming")
struct LinkFramingTests {

    @Test("Encodes codec byte, big-endian length, payload")
    func encodeLayout() {
        let frame = LinkFraming.encodeFrame(codec: .json, payload: Data([9, 8, 7]))
        #expect(Array(frame) == [2, 0, 0, 0, 3, 9, 8, 7])
    }

    @Test("Decodes several complete frames and leaves a partial tail")
    func decodeMultiple() throws {
        var buffer = LinkFraming.encodeFrame(codec: .binaryPropertyList, payload: Data([1]))
        buffer += LinkFraming.encodeFrame(codec: .json, payload: Data([2, 2]))
        let partial = LinkFraming.encodeFrame(codec: .json, payload: Data([3, 3, 3]))
        buffer += partial.prefix(6)

        let frames = try LinkFraming.decodeFrames(from: &buffer)
        #expect(frames.count == 2)
        #expect(frames[0].codec == .binaryPropertyList)
        #expect(Array(frames[0].payload) == [1])
        #expect(frames[1].codec == .json)
        #expect(Array(frames[1].payload) == [2, 2])
        #expect(buffer == partial.prefix(6))

        buffer += partial.suffix(from: 6)
        let rest = try LinkFraming.decodeFrames(from: &buffer)
        #expect(rest.count == 1)
        #expect(Array(rest[0].payload) == [3, 3, 3])
        #expect(buffer.isEmpty)
    }

    @Test("Empty payload is a valid frame")
    func emptyPayload() throws {
        var buffer = LinkFraming.encodeFrame(codec: .json, payload: Data())
        let frames = try LinkFraming.decodeFrames(from: &buffer)
        #expect(frames.count == 1)
        #expect(frames[0].payload.isEmpty)
    }

    @Test("Unknown codec byte throws")
    func unknownCodec() {
        var buffer = Data([7, 0, 0, 0, 0])
        #expect(throws: LinkFramingError.unknownCodec(7)) {
            try LinkFraming.decodeFrames(from: &buffer)
        }
    }

    @Test("Oversized payload length throws before waiting for bytes")
    func tooLarge() {
        var buffer = Data([1, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: LinkFramingError.payloadTooLarge(UInt32.max)) {
            try LinkFraming.decodeFrames(from: &buffer)
        }
    }

    @Test("A frame one byte over the cap is rejected; one exactly at it decodes")
    func exactlyAtAndOneOverTheCap() throws {
        let cap = LinkFraming.maximumPayloadLength

        // One byte over: refused on the declared length alone, before the bytes are waited for
        // — the header is all this needs, so nothing of that size is ever buffered.
        var oversized = Data([1])
        withUnsafeBytes(of: UInt32(cap + 1).bigEndian) { oversized.append(contentsOf: $0) }
        #expect(throws: LinkFramingError.payloadTooLarge(UInt32(cap + 1))) {
            try LinkFraming.decodeFrames(from: &oversized)
        }
        #expect(oversized.count == LinkFraming.headerLength)

        // And the cap itself is a legal length, not an off-by-one refusal.
        var atCap = LinkFraming.encodeFrame(codec: .json, payload: Data(repeating: 0x5A, count: cap))
        let frames = try LinkFraming.decodeFrames(from: &atCap)
        #expect(frames.count == 1)
        #expect(frames[0].payload.count == cap)
        #expect(atCap.isEmpty)
    }

    @Test("A declared length above Int32.max is rejected, never converted")
    func tooLargeForA32BitInt() {
        // 0x8000_0000: the smallest length whose `Int(_:)` traps where `Int` is 32 bits
        // (watchOS's arm64_32). Decoding must compare it as the `UInt32` it was read as, so
        // this is a thrown error on every platform rather than a trap on one.
        var buffer = Data([1, 0x80, 0x00, 0x00, 0x00])
        #expect(throws: LinkFramingError.payloadTooLarge(0x8000_0000)) {
            try LinkFraming.decodeFrames(from: &buffer)
        }
        #expect(buffer.count == 5)
    }

    @Test("Ten thousand tiny frames in one buffer all decode, and quickly")
    func manySmallFramesInOneBuffer() throws {
        // The shape a busy link produces: one read carrying thousands of small frames.
        // Compacting the buffer per frame made this quadratic — every removal shifts the whole
        // remainder down — so the bound is on the work, not just the answer.
        let count = 10_000
        var buffer = Data()
        for index in 0..<count {
            buffer += LinkFraming.encodeFrame(
                codec: index.isMultiple(of: 2) ? .json : .binaryPropertyList,
                payload: Data([UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)])
            )
        }
        let trailing = LinkFraming.encodeFrame(codec: .json, payload: Data([1, 2, 3]))
        buffer += trailing.prefix(4)

        let started = ContinuousClock.now
        let frames = try LinkFraming.decodeFrames(from: &buffer)
        let elapsed = ContinuousClock.now - started

        #expect(frames.count == count)
        for (index, frame) in frames.enumerated() {
            #expect(frame.codec == (index.isMultiple(of: 2) ? .json : .binaryPropertyList), "frame \(index)")
            #expect(Array(frame.payload) == [UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)], "frame \(index)")
        }
        // The partial frame at the end is kept, and it is *all* that is kept.
        #expect(buffer == trailing.prefix(4))
        #expect(elapsed < .seconds(1), "decoding took \(elapsed)")
    }

    @Test("A header shorter than 5 bytes yields nothing and keeps the bytes")
    func shortHeader() throws {
        var buffer = Data([1, 0, 0])
        let frames = try LinkFraming.decodeFrames(from: &buffer)
        #expect(frames.isEmpty)
        #expect(buffer.count == 3)
    }
}
