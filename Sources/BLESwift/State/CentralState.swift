//
//  CentralState.swift
//  BLESwift
//

import CoreBluetooth

/// The state of the device's Bluetooth radio, as reported by ``Central``.
///
/// BLESwift never exposes CoreBluetooth's `CBManagerState` in its public API; `CentralState`
/// is BLESwift-owned and mapped one-to-one from `CBManagerState` at the point an event is
/// received from CoreBluetooth.
public enum CentralState: Sendable, Equatable {

    /// The state has not yet been determined; CoreBluetooth has not reported a state
    /// update yet. Mirrors `CBManagerState.unknown`.
    case unknown

    /// The connection with the system service was momentarily lost and is being
    /// re-established. Mirrors `CBManagerState.resetting`.
    case resetting

    /// This device does not support Bluetooth low energy. Mirrors
    /// `CBManagerState.unsupported`.
    case unsupported

    /// The app is not authorized to use Bluetooth. Mirrors `CBManagerState.unauthorized`.
    case unauthorized

    /// Bluetooth is currently powered off. Mirrors `CBManagerState.poweredOff`.
    case poweredOff

    /// Bluetooth is currently powered on and available to use. Mirrors
    /// `CBManagerState.poweredOn`.
    case poweredOn

    /// Maps a `CBManagerState` to its ``CentralState`` equivalent.
    init(_ cbManagerState: CBManagerState) {
        switch cbManagerState {
        case .unknown:
            self = .unknown
        case .resetting:
            self = .resetting
        case .unsupported:
            self = .unsupported
        case .unauthorized:
            self = .unauthorized
        case .poweredOff:
            self = .poweredOff
        case .poweredOn:
            self = .poweredOn
        @unknown default:
            self = .unknown
        }
    }
}
