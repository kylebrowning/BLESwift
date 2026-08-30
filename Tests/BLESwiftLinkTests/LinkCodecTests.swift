//
//  LinkCodecTests.swift
//  BLESwiftLinkTests
//

import BLESwiftLink
import Foundation
import Testing

@Suite("LinkCodec")
struct LinkCodecTests {

    private struct Sample: Codable, Equatable {
        var name: String
        var payload: Data
        var count: Int
        var optional: String?
    }

    @Test("Round-trips a Codable value", arguments: LinkCodec.allCases)
    func roundTrip(codec: LinkCodec) throws {
        let sample = Sample(name: "x", payload: Data([0, 1, 2, 255]), count: 7, optional: nil)
        let encoded = try codec.encode(sample)
        let decoded = try codec.decode(Sample.self, from: encoded)
        #expect(decoded == sample)
    }

    @Test("Binary plist does not base64-expand Data")
    func binaryIsCompact() throws {
        let sample = Sample(name: "", payload: Data(repeating: 0xAB, count: 10_000), count: 0, optional: nil)
        let binary = try LinkCodec.binaryPropertyList.encode(sample)
        let json = try LinkCodec.json.encode(sample)
        #expect(binary.count < 10_500)
        #expect(json.count > 13_000)
    }

    @Test("Raw values are stable")
    func rawValues() {
        #expect(LinkCodec.binaryPropertyList.rawValue == 1)
        #expect(LinkCodec.json.rawValue == 2)
    }
}
