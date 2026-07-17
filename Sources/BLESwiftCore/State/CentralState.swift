//
//  CentralState.swift
//  BLESwiftCore
//

/// The state of the device's Bluetooth radio, as reported by `Central`.
///
/// BLESwift-owned; the backend's native state-mapping (`init(_:)`) lives in the
/// `BLESwift` module, at the one point an event is received from CoreBluetooth — this
/// type never exposes a CoreBluetooth type in its own public API.
public enum CentralState: Sendable, Equatable {

    /// The state has not yet been determined; the backend has not reported a state
    /// update yet.
    case unknown

    /// The connection with the system Bluetooth service was momentarily lost and is
    /// being re-established.
    case resetting

    /// This device does not support Bluetooth low energy.
    case unsupported

    /// The app is not authorized to use Bluetooth.
    case unauthorized

    /// Bluetooth is currently powered off.
    case poweredOff

    /// Bluetooth is currently powered on and available to use.
    case poweredOn
}
