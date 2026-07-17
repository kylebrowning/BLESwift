//
//  BluetoothAuthorization.swift
//  BLESwift
//

import CoreBluetooth

/// The app's authorization to use Bluetooth, as reported by ``Central``.
///
/// BLESwift never exposes CoreBluetooth's `CBManagerAuthorization` in its public API;
/// `BluetoothAuthorization` is BLESwift-owned and mapped one-to-one from
/// `CBManagerAuthorization` (read via the `CBManager.authorization` class property).
public enum BluetoothAuthorization: Sendable, Equatable {

    /// The user has not yet granted or denied Bluetooth authorization. Mirrors
    /// `CBManagerAuthorization.notDetermined`.
    case notDetermined

    /// The app is not authorized to use Bluetooth and the user cannot change this, e.g.
    /// due to parental controls. Mirrors `CBManagerAuthorization.restricted`.
    case restricted

    /// The user explicitly denied Bluetooth authorization for this app. Mirrors
    /// `CBManagerAuthorization.denied`.
    case denied

    /// The user granted Bluetooth authorization for this app. Mirrors
    /// `CBManagerAuthorization.allowedAlways`.
    case allowedAlways

    /// Maps a `CBManagerAuthorization` to its ``BluetoothAuthorization`` equivalent.
    init(_ cbManagerAuthorization: CBManagerAuthorization) {
        switch cbManagerAuthorization {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .allowedAlways:
            self = .allowedAlways
        @unknown default:
            self = .notDetermined
        }
    }
}
