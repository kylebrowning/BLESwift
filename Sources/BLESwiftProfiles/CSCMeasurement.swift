//
//  CSCMeasurement.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The Bluetooth SIG "CSC Measurement" characteristic (GSS §3.60 CSC Measurement, `0x2A5B`) from
/// the Cycling Speed and Cadence service.
///
/// Byte layout (little-endian): a one-byte `Flags` field, then the groups that the flags select, in
/// this order:
/// - Flags bit 0: Wheel Revolution Data. It has `cumulativeRevolutions` (`UInt32`) and then
///   `lastEventTime` (`UInt16`, units of 1/1024 s).
/// - Flags bit 1: Crank Revolution Data. It has `cumulativeRevolutions` (`UInt16`) and then
///   `lastEventTime` (`UInt16`, units of 1/1024 s).
public struct CSCMeasurement: Receivable, Sendable, Equatable {

    /// Wheel-revolution data (present only if Flags bit 0 is set).
    public struct WheelData: Sendable, Equatable {
        /// Cumulative wheel revolutions.
        public let cumulativeRevolutions: UInt32
        /// Last wheel event time, in units of 1/1024 s. It wraps at 64 s.
        public let lastEventTime: UInt16
        /// Creates wheel data from a revolution count and an event time.
        public init(cumulativeRevolutions: UInt32, lastEventTime: UInt16) {
            self.cumulativeRevolutions = cumulativeRevolutions
            self.lastEventTime = lastEventTime
        }
    }

    /// Crank-revolution data (present only if Flags bit 1 is set).
    public struct CrankData: Sendable, Equatable {
        /// Cumulative crank revolutions.
        public let cumulativeRevolutions: UInt16
        /// Last crank event time, in units of 1/1024 s. It wraps at 64 s.
        public let lastEventTime: UInt16
        /// Creates crank data from a revolution count and an event time.
        public init(cumulativeRevolutions: UInt16, lastEventTime: UInt16) {
            self.cumulativeRevolutions = cumulativeRevolutions
            self.lastEventTime = lastEventTime
        }
    }

    /// The Bluetooth SIG-assigned Cycling Speed and Cadence service (`0x1816`).
    public static let service = ServiceIdentifier(uuid: "1816")
    /// The Bluetooth SIG-assigned CSC Measurement characteristic (`0x2A5B`).
    public static let characteristic = CharacteristicIdentifier(uuid: "2A5B", service: service)

    /// The wheel data, or `nil` if the peripheral did not send it.
    public let wheel: WheelData?
    /// The crank data, or `nil` if the peripheral did not send it.
    public let crank: CrankData?

    public init(bluetoothData data: Data) throws {
        let flags: UInt8 = try data.extract(start: 0, length: 1)
        var offset = 1

        if (flags & 0x01) != 0 {
            let revolutions: UInt32 = try data.extract(start: offset, length: 4)
            let eventTime: UInt16 = try data.extract(start: offset + 4, length: 2)
            wheel = WheelData(cumulativeRevolutions: revolutions, lastEventTime: eventTime)
            offset += 6
        } else {
            wheel = nil
        }

        if (flags & 0x02) != 0 {
            let revolutions: UInt16 = try data.extract(start: offset, length: 2)
            let eventTime: UInt16 = try data.extract(start: offset + 2, length: 2)
            crank = CrankData(cumulativeRevolutions: revolutions, lastEventTime: eventTime)
        } else {
            crank = nil
        }
    }
}
