//
//  Peripheral+Profiles.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// Convenience reads for standard GATT profiles. They use
/// ``BLESwift/Peripheral/read(from:timeout:)``.
extension Peripheral {

    /// Reads every Device Information String characteristic that the peripheral exposes. It
    /// discovers the service's characteristics first and reads only those that exist. The field of
    /// a missing characteristic is `nil`, so an omitted string does not make this function throw.
    ///
    /// - Parameter timeout: The timeout for each read, forwarded to
    ///   ``BLESwift/Peripheral/read(from:timeout:)``. `nil` (the default) waits without a limit.
    /// - Returns: A ``DeviceInformation`` with a value for each characteristic that exists.
    /// - Throws: ``BLESwiftError/missingService(_:)`` if the Device Information service is absent.
    ///   Also ``BLESwiftError/notConnected``, ``BLESwiftError/timedOut``, or any error that a read
    ///   or its UTF-8 decoding throws.
    public func readDeviceInformation(timeout: Duration? = nil) async throws -> DeviceInformation {
        let present = Set(try await discoverCharacteristics(for: DeviceInformation.service))

        func readIfPresent(_ characteristic: CharacteristicIdentifier) async throws -> String? {
            guard present.contains(characteristic) else { return nil }
            return try await read(from: characteristic, timeout: timeout) as String
        }

        // The reads run in sequence. Concurrent reads would give no benefit.
        let manufacturerName = try await readIfPresent(DeviceInformation.manufacturerNameCharacteristic)
        let modelNumber = try await readIfPresent(DeviceInformation.modelNumberCharacteristic)
        let serialNumber = try await readIfPresent(DeviceInformation.serialNumberCharacteristic)
        let firmwareRevision = try await readIfPresent(DeviceInformation.firmwareRevisionCharacteristic)
        let hardwareRevision = try await readIfPresent(DeviceInformation.hardwareRevisionCharacteristic)
        let softwareRevision = try await readIfPresent(DeviceInformation.softwareRevisionCharacteristic)

        return DeviceInformation(
            manufacturerName: manufacturerName,
            modelNumber: modelNumber,
            serialNumber: serialNumber,
            firmwareRevision: firmwareRevision,
            hardwareRevision: hardwareRevision,
            softwareRevision: softwareRevision
        )
    }

    /// Reads Battery Level (`0x2A19`) and returns the percentage (0–100).
    ///
    /// - Parameter timeout: Forwarded to ``BLESwift/Peripheral/read(from:timeout:)``. `nil` (the
    ///   default) waits without a limit.
    /// - Returns: The battery charge, as a percentage.
    /// - Throws: The same errors as ``BLESwift/Peripheral/read(from:timeout:)``. Also
    ///   ``BLESwiftError/invalidArgument(_:)`` if the peripheral reports a value above 100.
    public func readBatteryLevel(timeout: Duration? = nil) async throws -> UInt8 {
        let level: BatteryLevel = try await read(from: BatteryLevel.characteristic, timeout: timeout)
        return level.percentage
    }
}
