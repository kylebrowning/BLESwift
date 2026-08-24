//
//  CyclingPowerMeasurement.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The Bluetooth SIG "Cycling Power Measurement" characteristic (GSS §3.59 Cycling Power
/// Measurement, `0x2A63`) from the Cycling Power service.
///
/// Byte layout (little-endian): a 2-byte `Flags` field, a 2-byte signed
/// `instantaneousPower` (watts), then flag-driven optional fields in this exact order:
/// - bit 0 — Pedal Power Balance present (`UInt8`, units of 1/2 %).
/// - bit 1 — Pedal Power Balance Reference: 0 = unknown, 1 = left.
/// - bit 2 — Accumulated Torque present (`UInt16`, units of 1/32 N·m).
/// - bit 3 — Accumulated Torque Source: 0 = wheel-based, 1 = crank-based.
/// - bit 4 — Wheel Revolution Data: cumulative (`UInt32`) + last event time (`UInt16`,
///   units of 1/2048 s).
/// - bit 5 — Crank Revolution Data: cumulative (`UInt16`) + last event time (`UInt16`,
///   units of 1/1024 s).
/// - bit 6 — Extreme Force Magnitudes: max (`Int16`) + min (`Int16`), newtons.
/// - bit 7 — Extreme Torque Magnitudes: max (`Int16`) + min (`Int16`), units of 1/32 N·m.
/// - bit 8 — Extreme Angles: 3 bytes packed as two 12-bit values —
///   `maxAngle = raw24 & 0xFFF`, `minAngle = raw24 >> 12` (degrees).
/// - bit 9 — Top Dead Spot Angle (`UInt16`, degrees).
/// - bit 10 — Bottom Dead Spot Angle (`UInt16`, degrees).
/// - bit 11 — Accumulated Energy (`UInt16`, kilojoules).
/// - bit 12 — Offset Compensation Indicator (a flag; no payload).
public struct CyclingPowerMeasurement: Receivable, Sendable, Equatable {

    /// The reference leg for Pedal Power Balance (Flags bit 1).
    public enum PedalPowerBalanceReference: Sendable, Equatable {
        case unknown
        case left
    }

    /// The source of Accumulated Torque (Flags bit 3).
    public enum AccumulatedTorqueSource: Sendable, Equatable {
        case wheelBased
        case crankBased
    }

    /// Wheel-revolution data (Flags bit 4).
    public struct WheelRevolutionData: Sendable, Equatable {
        public let cumulativeRevolutions: UInt32
        public let lastEventTime: UInt16
        public init(cumulativeRevolutions: UInt32, lastEventTime: UInt16) {
            self.cumulativeRevolutions = cumulativeRevolutions
            self.lastEventTime = lastEventTime
        }
    }

    /// Crank-revolution data (Flags bit 5).
    public struct CrankRevolutionData: Sendable, Equatable {
        public let cumulativeRevolutions: UInt16
        public let lastEventTime: UInt16
        public init(cumulativeRevolutions: UInt16, lastEventTime: UInt16) {
            self.cumulativeRevolutions = cumulativeRevolutions
            self.lastEventTime = lastEventTime
        }
    }

    /// A max/min pair of signed magnitudes (used for extreme force and torque).
    public struct MinMax: Sendable, Equatable {
        public let maximum: Int16
        public let minimum: Int16
        public init(maximum: Int16, minimum: Int16) {
            self.maximum = maximum
            self.minimum = minimum
        }
    }

    /// The extreme crank angles, as two 12-bit degree values (Flags bit 8).
    public struct ExtremeAngles: Sendable, Equatable {
        public let maximum: UInt16
        public let minimum: UInt16
        public init(maximum: UInt16, minimum: UInt16) {
            self.maximum = maximum
            self.minimum = minimum
        }
    }

    /// The Bluetooth SIG-assigned Cycling Power service (`0x1818`).
    public static let service = ServiceIdentifier(uuid: "1818")
    /// The Bluetooth SIG-assigned Cycling Power Measurement characteristic (`0x2A63`).
    public static let characteristic = CharacteristicIdentifier(uuid: "2A63", service: service)

    /// Instantaneous power, in watts.
    public let instantaneousPower: Int16
    /// Pedal power balance, in units of 1/2 % (bit 0), if present.
    public let pedalPowerBalance: UInt8?
    /// The reference leg for ``pedalPowerBalance`` (bit 1).
    public let pedalPowerBalanceReference: PedalPowerBalanceReference
    /// Accumulated torque, in units of 1/32 N·m (bit 2), if present.
    public let accumulatedTorque: UInt16?
    /// The source of ``accumulatedTorque`` (bit 3).
    public let accumulatedTorqueSource: AccumulatedTorqueSource
    /// Wheel revolution data (bit 4), if present.
    public let wheelRevolutions: WheelRevolutionData?
    /// Crank revolution data (bit 5), if present.
    public let crankRevolutions: CrankRevolutionData?
    /// Extreme force magnitudes, in newtons (bit 6), if present.
    public let extremeForceMagnitudes: MinMax?
    /// Extreme torque magnitudes, in units of 1/32 N·m (bit 7), if present.
    public let extremeTorqueMagnitudes: MinMax?
    /// Extreme crank angles, in degrees (bit 8), if present.
    public let extremeAngles: ExtremeAngles?
    /// Top dead spot angle, in degrees (bit 9), if present.
    public let topDeadSpotAngle: UInt16?
    /// Bottom dead spot angle, in degrees (bit 10), if present.
    public let bottomDeadSpotAngle: UInt16?
    /// Accumulated energy, in kilojoules (bit 11), if present.
    public let accumulatedEnergy: UInt16?
    /// Whether the Offset Compensation Indicator flag (bit 12) is set.
    public let offsetCompensationIndicator: Bool

    public init(bluetoothData data: Data) throws {
        let flags: UInt16 = try data.extract(start: 0, length: 2)
        instantaneousPower = try data.extract(start: 2, length: 2)
        var offset = 4

        if (flags & (1 << 0)) != 0 {
            let balance: UInt8 = try data.extract(start: offset, length: 1)
            pedalPowerBalance = balance
            offset += 1
        } else {
            pedalPowerBalance = nil
        }
        pedalPowerBalanceReference = (flags & (1 << 1)) != 0 ? .left : .unknown

        if (flags & (1 << 2)) != 0 {
            let torque: UInt16 = try data.extract(start: offset, length: 2)
            accumulatedTorque = torque
            offset += 2
        } else {
            accumulatedTorque = nil
        }
        accumulatedTorqueSource = (flags & (1 << 3)) != 0 ? .crankBased : .wheelBased

        if (flags & (1 << 4)) != 0 {
            let cumulative: UInt32 = try data.extract(start: offset, length: 4)
            let eventTime: UInt16 = try data.extract(start: offset + 4, length: 2)
            wheelRevolutions = WheelRevolutionData(cumulativeRevolutions: cumulative, lastEventTime: eventTime)
            offset += 6
        } else {
            wheelRevolutions = nil
        }

        if (flags & (1 << 5)) != 0 {
            let cumulative: UInt16 = try data.extract(start: offset, length: 2)
            let eventTime: UInt16 = try data.extract(start: offset + 2, length: 2)
            crankRevolutions = CrankRevolutionData(cumulativeRevolutions: cumulative, lastEventTime: eventTime)
            offset += 4
        } else {
            crankRevolutions = nil
        }

        if (flags & (1 << 6)) != 0 {
            let maximum: Int16 = try data.extract(start: offset, length: 2)
            let minimum: Int16 = try data.extract(start: offset + 2, length: 2)
            extremeForceMagnitudes = MinMax(maximum: maximum, minimum: minimum)
            offset += 4
        } else {
            extremeForceMagnitudes = nil
        }

        if (flags & (1 << 7)) != 0 {
            let maximum: Int16 = try data.extract(start: offset, length: 2)
            let minimum: Int16 = try data.extract(start: offset + 2, length: 2)
            extremeTorqueMagnitudes = MinMax(maximum: maximum, minimum: minimum)
            offset += 4
        } else {
            extremeTorqueMagnitudes = nil
        }

        if (flags & (1 << 8)) != 0 {
            let b0: UInt8 = try data.extract(start: offset, length: 1)
            let b1: UInt8 = try data.extract(start: offset + 1, length: 1)
            let b2: UInt8 = try data.extract(start: offset + 2, length: 1)
            let raw24 = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16)
            let maxAngle = UInt16(raw24 & 0xFFF)
            let minAngle = UInt16((raw24 >> 12) & 0xFFF)
            extremeAngles = ExtremeAngles(maximum: maxAngle, minimum: minAngle)
            offset += 3
        } else {
            extremeAngles = nil
        }

        if (flags & (1 << 9)) != 0 {
            let angle: UInt16 = try data.extract(start: offset, length: 2)
            topDeadSpotAngle = angle
            offset += 2
        } else {
            topDeadSpotAngle = nil
        }

        if (flags & (1 << 10)) != 0 {
            let angle: UInt16 = try data.extract(start: offset, length: 2)
            bottomDeadSpotAngle = angle
            offset += 2
        } else {
            bottomDeadSpotAngle = nil
        }

        if (flags & (1 << 11)) != 0 {
            let energy: UInt16 = try data.extract(start: offset, length: 2)
            accumulatedEnergy = energy
            offset += 2
        } else {
            accumulatedEnergy = nil
        }

        offsetCompensationIndicator = (flags & (1 << 12)) != 0
    }
}
