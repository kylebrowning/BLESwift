//
//  Peripheral+Profiles.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// Convenience reads for standard GATT profiles, built on ``BLESwift/Peripheral``'s generic
/// ``BLESwift/Peripheral/read(from:timeout:)``.
extension Peripheral {

    /// Reads every Device Information String characteristic the peripheral exposes. Discovers
    /// the service's characteristics first, then reads only those present; a missing
    /// characteristic leaves its field `nil`, so this never throws just because the
    /// peripheral omits some strings.
    ///
    /// - Parameter timeout: Per-read timeout, forwarded to
    ///   ``BLESwift/Peripheral/read(from:timeout:)``. `nil` (the default) waits indefinitely.
    /// - Returns: A ``DeviceInformation`` with a value for each present characteristic and
    ///   `nil` for each absent one.
    /// - Throws: ``BLESwiftError/missingService(_:)`` if the Device Information service is
    ///   absent, ``BLESwiftError/notConnected``, ``BLESwiftError/timedOut``, or whatever a
    ///   read or its UTF-8 decoding throws.
    public func readDeviceInformation(timeout: Duration? = nil) async throws -> DeviceInformation {
        let present = Set(try await discoverCharacteristics(for: DeviceInformation.service))

        func readIfPresent(_ characteristic: CharacteristicIdentifier) async throws -> String? {
            guard present.contains(characteristic) else { return nil }
            return try await read(from: characteristic, timeout: timeout) as String
        }

        // Sequential — per-characteristic FIFO makes concurrency pointless here.
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
    /// - Parameter timeout: Forwarded to ``BLESwift/Peripheral/read(from:timeout:)``. `nil`
    ///   (the default) waits indefinitely.
    /// - Returns: The battery charge, as a percentage.
    /// - Throws: As ``BLESwift/Peripheral/read(from:timeout:)`` does, plus
    ///   ``BLESwiftError/invalidArgument(_:)`` if the peripheral reports a value above 100.
    public func readBatteryLevel(timeout: Duration? = nil) async throws -> UInt8 {
        let level: BatteryLevel = try await read(from: BatteryLevel.characteristic, timeout: timeout)
        return level.percentage
    }
}
