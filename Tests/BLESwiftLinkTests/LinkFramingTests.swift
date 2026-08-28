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
        #expect(throws: LinkFramingError.payloadTooLarge(Int(UInt32.max))) {
            try LinkFraming.decodeFrames(from: &buffer)
        }
    }

    @Test("A header shorter than 5 bytes yields nothing and keeps the bytes")
    func shortHeader() throws {
        var buffer = Data([1, 0, 0])
        let frames = try LinkFraming.decodeFrames(from: &buffer)
        #expect(frames.isEmpty)
        #expect(buffer.count == 3)
    }
}
