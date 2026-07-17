//
//  BluetoothAuthorization.swift
//  BLESwiftCore
//

/// The app's authorization to use Bluetooth, as reported by `Central`.
///
/// BLESwift-owned; the backend's native authorization-mapping (`init(_:)`) lives in the
/// `BLESwift` module — this type never exposes a CoreBluetooth type in its own public API.
public enum BluetoothAuthorization: Sendable, Equatable {

    /// The user has not yet granted or denied Bluetooth authorization.
    case notDetermined

    /// The app is not authorized to use Bluetooth and the user cannot change this, e.g.
    /// due to parental controls.
    case restricted

    /// The user explicitly denied Bluetooth authorization for this app.
    case denied

    /// The user granted Bluetooth authorization for this app.
    case allowedAlways
}
