//
//  Data+Identity.swift
//  BLESwift
//

import Foundation

extension Data: Transmittable, Receivable {

    /// Creates a `Data` value by copying `bluetoothData` verbatim (identity conformance),
    /// so raw bytes can be read from a characteristic without a custom `Receivable` type.
    public init(bluetoothData: Data) throws {
        self = bluetoothData
    }

    /// Returns `self` verbatim (identity conformance), so raw bytes can be written to a
    /// characteristic without a custom `Transmittable` type.
    public func toBluetoothData() throws -> Data {
        self
    }
}
