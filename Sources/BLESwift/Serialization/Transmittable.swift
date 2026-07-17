//
//  Transmittable.swift
//  BLESwift
//

import Foundation

/// A type that can be encoded into data to send over Bluetooth.
///
/// Named `Transmittable` rather than `Sendable` to avoid colliding with
/// Swift concurrency's `Sendable` protocol.
public protocol Transmittable {

    /// Serializes this value into the bytes that should be written to a characteristic.
    ///
    /// This is `throws`, so encoding failures (e.g. a string that cannot be represented in
    /// its target encoding) can be reported instead of force-unwrapped and crashing.
    ///
    /// - Throws: Any error encountered while encoding, e.g.
    ///   ``BLESwiftError/invalidStringEncoding``.
    func toBluetoothData() throws -> Data
}
