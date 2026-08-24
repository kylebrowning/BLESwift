//
//  BatteryLevel.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The Bluetooth SIG "Battery Level" characteristic (GSS §3.27 Battery Level, `0x2A19`).
///
/// Byte layout: a single `UInt8` giving the remaining battery as a percentage, 0–100.
/// Values above 100 are invalid and cause decoding to throw.
public struct BatteryLevel: Receivable, Transmittable, Sendable, Equatable {

    /// The Bluetooth SIG-assigned Battery service (`0x180F`).
    public static let service = ServiceIdentifier(uuid: "180F")
    /// The Bluetooth SIG-assigned Battery Level characteristic (`0x2A19`).
    public static let characteristic = CharacteristicIdentifier(uuid: "2A19", service: service)

    /// The remaining battery charge, as a percentage, 0–100.
    public let percentage: UInt8

    public init(percentage: UInt8) {
        self.percentage = percentage
    }

    public init(bluetoothData data: Data) throws {
        let value: UInt8 = try data.extract(start: 0, length: 1)
        guard value <= 100 else {
            throw BLESwiftError.invalidArgument("Battery level out of range: \(value)")
        }
        percentage = value
    }

    public func toBluetoothData() throws -> Data {
        Data([percentage])
    }
}
