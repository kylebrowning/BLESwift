//
//  CentralState.swift
//  BLESwiftCore
//

/// The state of the device's Bluetooth radio, as `Central` reports it.
///
/// BLESwift owns this type, so no CoreBluetooth type appears in its public API. The `BLESwift`
/// module maps the backend's native state to it (`init(_:)`), at the one point where it receives an
/// event from CoreBluetooth.
public enum CentralState: Sendable, Equatable {

    /// The state is not yet determined. The backend has not reported a state update.
    case unknown

    /// The connection with the system Bluetooth service was briefly lost. The system re-establishes
    /// it.
    case resetting

    /// This device does not support Bluetooth Low Energy.
    case unsupported

    /// The app is not authorized to use Bluetooth.
    case unauthorized

    /// Bluetooth is powered off.
    case poweredOff

    /// Bluetooth is powered on and available.
    case poweredOn
}
