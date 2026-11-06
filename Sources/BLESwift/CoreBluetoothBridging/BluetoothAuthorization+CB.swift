//
//  BluetoothAuthorization+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension BluetoothAuthorization {

    /// Maps a `CBManagerAuthorization` to its equivalent ``BluetoothAuthorization``.
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
