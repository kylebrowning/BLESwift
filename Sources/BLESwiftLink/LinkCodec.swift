//
//  LinkCodec.swift
//  BLESwiftLink
//

import Foundation

/// The encoding of a frame's payload. Every frame carries a codec byte.
/// Each side encodes with its own preference and decodes any codec that arrives.
public enum LinkCodec: UInt8, Sendable, CaseIterable {
    /// `PropertyListEncoder` in binary format. This codec is compact. It stores `Data` as raw
    /// bytes and does not expand it to base64. This codec is the default.
    case binaryPropertyList = 1
    /// `JSONEncoder`. People can read this format. Use it to debug with `--json`.
    case json = 2

    /// Encodes `value` in this codec.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        switch self {
        case .binaryPropertyList:
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try encoder.encode(value)
        case .json:
            return try JSONEncoder().encode(value)
        }
    }

    /// Decodes a `type` from `data` encoded in this codec.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        switch self {
        case .binaryPropertyList:
            return try PropertyListDecoder().decode(type, from: data)
        case .json:
            return try JSONDecoder().decode(type, from: data)
        }
    }
}
