//
//  LinkCodec.swift
//  BLESwiftLink
//

import Foundation

/// How a frame's payload is encoded. The codec byte travels on every frame, so each side
/// encodes with its own preference and decodes whatever arrives.
public enum LinkCodec: UInt8, Sendable, CaseIterable {
    /// `PropertyListEncoder` in binary format — compact, and `Data` is stored raw rather
    /// than base64-expanded. The default.
    case binaryPropertyList = 1
    /// `JSONEncoder` — human-readable, for debugging with `--json`.
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
