//
//  DataPadding.swift
//  BLESwift
//

import Foundation

/// Produces empty (zero-filled) `Data` of a fixed length, useful as padding when
/// constructing a packet with ``combine(_:)``.
public struct DataPadding: Transmittable, Sendable {

    /// The number of zero bytes this padding will produce.
    private let amount: Int

    /// Creates a padding value.
    ///
    /// - Parameter amount: The number of zero bytes to produce.
    public init(_ amount: Int) {
        self.amount = amount
    }

    /// Returns `amount` zero bytes.
    public func toBluetoothData() throws -> Data {
        Data(count: amount)
    }
}
