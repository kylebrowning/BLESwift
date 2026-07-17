//
//  String+Transferable.swift
//  BLESwift
//

import Foundation

extension String: Transmittable, Receivable {

    /// Decodes `bluetoothData` as a UTF-8 string.
    ///
    /// - Throws: ``BLESwiftError/invalidStringEncoding`` if `bluetoothData` is not valid
    ///   UTF-8. A naive force-unwrapping implementation (`String(data:encoding:)!`) would
    ///   crash on malformed input; this never does.
    public init(bluetoothData: Data) throws {
        guard let decoded = String(data: bluetoothData, encoding: .utf8) else {
            throw BLESwiftError.invalidStringEncoding
        }
        self = decoded
    }

    /// Encodes this string as UTF-8 data.
    ///
    /// - Throws: ``BLESwiftError/invalidStringEncoding`` if the string cannot be represented
    ///   as UTF-8. `String(using: .utf8)` failing is not reachable for well-formed Swift
    ///   `String` values in practice, but the API is kept `throws` for symmetry with
    ///   ``init(bluetoothData:)`` and to avoid a force-unwrap.
    public func toBluetoothData() throws -> Data {
        guard let encoded = data(using: .utf8) else {
            throw BLESwiftError.invalidStringEncoding
        }
        return encoded
    }
}
