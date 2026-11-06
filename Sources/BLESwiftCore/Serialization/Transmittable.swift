//
//  Transmittable.swift
//  BLESwiftCore
//

import Foundation

/// A type that can be encoded into data to send over Bluetooth.
///
/// The name is `Transmittable` and not `Sendable`, to avoid a collision with Swift concurrency's
/// `Sendable` protocol.
public protocol Transmittable {

    /// Serializes this value into the bytes to write to a characteristic.
    ///
    /// This function is `throws` so that it can report an encoding failure, such as a string that
    /// the target encoding cannot represent, instead of crashing.
    ///
    /// - Throws: Any error that occurs during encoding. An example is
    ///   ``BLESwiftError/invalidStringEncoding``.
    func toBluetoothData() throws -> Data
}
