//
//  Receivable.swift
//  BLESwiftCore
//

import Foundation

/// A type that can be decoded from data received over Bluetooth.
public protocol Receivable {

    /// Creates an instance by deserializing `bluetoothData`.
    ///
    /// - Parameter bluetoothData: The raw bytes that a characteristic read or a notification
    ///   returned.
    /// - Throws: Any error that occurs during decoding. Examples are
    ///   ``BLESwiftError/dataOutOfBounds(start:length:count:)`` and
    ///   ``BLESwiftError/invalidStringEncoding``.
    init(bluetoothData: Data) throws
}
