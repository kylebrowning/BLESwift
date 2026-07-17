//
//  Receivable.swift
//  BLESwift
//

import Foundation

/// A type that can be decoded from data received over Bluetooth.
public protocol Receivable {

    /// Creates an instance by deserializing `bluetoothData`.
    ///
    /// - Parameter bluetoothData: The raw bytes received from a characteristic read or
    ///   notification.
    /// - Throws: Any error encountered while decoding, e.g.
    ///   ``BLESwiftError/dataOutOfBounds(start:length:count:)`` or
    ///   ``BLESwiftError/invalidStringEncoding``.
    init(bluetoothData: Data) throws
}
