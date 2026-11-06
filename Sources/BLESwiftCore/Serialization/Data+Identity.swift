//
//  Data+Identity.swift
//  BLESwiftCore
//

import Foundation

extension Data: Transmittable, Receivable {

    /// Creates a `Data` value that copies `bluetoothData` unchanged (identity conformance), so you
    /// can read raw bytes from a characteristic with no custom `Receivable` type.
    public init(bluetoothData: Data) throws {
        self = bluetoothData
    }

    /// Returns `self` unchanged (identity conformance), so you can write raw bytes to a
    /// characteristic with no custom `Transmittable` type.
    public func toBluetoothData() throws -> Data {
        self
    }
}
