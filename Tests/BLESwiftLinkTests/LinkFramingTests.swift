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
    func encodeLayout() throws {
        let frame = try LinkFraming.encodeFrame(codec: .json, payload: Data([9, 8, 7]))
        #expect(Array(frame) == [2, 0, 0, 0, 3, 9, 8, 7])
    }

    @Test("Decodes several complete frames and leaves a partial tail")
    func decodeMultiple() throws {
        var buffer = try LinkFraming.encodeFrame(codec: .binaryPropertyList, payload: Data([1]))
        buffer += try LinkFraming.encodeFrame(codec: .json, payload: Data([2, 2]))
        let partial = try LinkFraming.encodeFrame(codec: .json, payload: Data([3, 3, 3]))
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
        var buffer = try LinkFraming.encodeFrame(codec: .json, payload: Data())
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

        // One byte over. The decoder refuses the frame on the declared length alone, so it never
        // buffers anything of that size.
        var oversized = Data([1])
        withUnsafeBytes(of: UInt32(cap + 1).bigEndian) { oversized.append(contentsOf: $0) }
        #expect(throws: LinkFramingError.payloadTooLarge(UInt32(cap + 1))) {
            try LinkFraming.decodeFrames(from: &oversized)
        }
        #expect(oversized.count == LinkFraming.headerLength)

        var atCap = try LinkFraming.encodeFrame(codec: .json, payload: Data(repeating: 0x5A, count: cap))
        let frames = try LinkFraming.decodeFrames(from: &atCap)
        #expect(frames.count == 1)
        #expect(frames[0].payload.count == cap)
        #expect(atCap.isEmpty)
    }

    @Test("A payload past the cap is refused before it can be framed")
    func encodingRefusesAnOversizedPayload() {
        // This is the encoder's bound. `LinkConnection.send(_:)` fails a connection on it, so this
        // end never writes a frame it cannot legally send.
        let oversized = Data(repeating: 0x5A, count: LinkFraming.maximumPayloadLength + 1)
        #expect(throws: LinkFramingError.payloadTooLarge(UInt32(LinkFraming.maximumPayloadLength + 1))) {
            try LinkFraming.encodeFrame(codec: .json, payload: oversized)
        }
    }

    @Test("A declared length above Int32.max is rejected, never converted")
    func tooLargeForA32BitInt() {
        // 0x8000_0000 is the smallest length whose `Int(_:)` traps where `Int` is 32 bits (watchOS
        // arm64_32). Decoding must compare it as a `UInt32`, so it is a thrown error on every
        // platform.
        var buffer = Data([1, 0x80, 0x00, 0x00, 0x00])
        #expect(throws: LinkFramingError.payloadTooLarge(0x8000_0000)) {
            try LinkFraming.decodeFrames(from: &buffer)
        }
        #expect(buffer.count == 5)
    }

    @Test("Ten thousand tiny frames in one buffer all decode, and quickly")
    func manySmallFramesInOneBuffer() throws {
        // One read that carries thousands of small frames. Compacting the buffer for each frame was
        // quadratic, so the bound is on the work and not only on the answer.
        let count = 10_000
        var buffer = Data()
        for index in 0..<count {
            buffer += try LinkFraming.encodeFrame(
                codec: index.isMultiple(of: 2) ? .json : .binaryPropertyList,
                payload: Data([UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)])
            )
        }
        let trailing = try LinkFraming.encodeFrame(codec: .json, payload: Data([1, 2, 3]))
        buffer += trailing.prefix(4)

        let started = ContinuousClock.now
        let frames = try LinkFraming.decodeFrames(from: &buffer)
        let elapsed = ContinuousClock.now - started

        #expect(frames.count == count)
        for (index, frame) in frames.enumerated() {
            #expect(frame.codec == (index.isMultiple(of: 2) ? .json : .binaryPropertyList), "frame \(index)")
            #expect(Array(frame.payload) == [UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)], "frame \(index)")
        }
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
