//
//  Combine.swift
//  BLESwiftCore
//

import Foundation

/// Concatenates the encoded bytes of each `Transmittable` in order.
///
/// Use it to build a single packet from several typed pieces, for example `combine([header,
/// DataPadding(2), payload])`.
///
/// - Parameter transmittables: The values to encode and concatenate, in packet byte order.
/// - Throws: The first encoding error.
/// - Returns: The concatenated `Data`.
public func combine(_ transmittables: [any Transmittable]) throws -> Data {
    var result = Data()
    for transmittable in transmittables {
        result.append(try transmittable.toBluetoothData())
    }
    return result
}
