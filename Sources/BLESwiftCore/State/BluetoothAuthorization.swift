//
//  BluetoothAuthorization.swift
//  BLESwiftCore
//

/// The app's authorization to use Bluetooth, as `Central` reports it.
///
/// BLESwift owns this type, so no CoreBluetooth type appears in its public API. The `BLESwift`
/// module maps the backend's native authorization to it (`init(_:)`).
public enum BluetoothAuthorization: Sendable, Equatable {

    /// The user has not yet granted or denied Bluetooth authorization.
    case notDetermined

    /// The app is not authorized to use Bluetooth, and the user cannot change this, for example
    /// because of parental controls.
    case restricted

    /// The user explicitly denied Bluetooth authorization for this app.
    case denied

    /// The user granted Bluetooth authorization for this app.
    case allowedAlways
}
