//
//  Combine.swift
//  BLESwift
//

import Foundation

/// Concatenates the encoded bytes of each `Transmittable` in order.
///
/// Useful for constructing a single packet out of several typed pieces, e.g.
/// `combine([header, DataPadding(2), payload])`.
///
/// - Parameter transmittables: The values to encode and concatenate, in the order their
///   bytes should appear in the resulting packet.
/// - Throws: Rethrows the first encoding error encountered, in order.
/// - Returns: The concatenated `Data`.
public func combine(_ transmittables: [any Transmittable]) throws -> Data {
    var result = Data()
    for transmittable in transmittables {
        result.append(try transmittable.toBluetoothData())
    }
    return result
}
