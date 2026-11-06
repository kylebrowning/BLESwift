//
//  PeripheralConnectionState+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension PeripheralConnectionState {

    /// Maps a `CBPeripheralState` to a ``PeripheralConnectionState``. An `@unknown` state maps
    /// to ``disconnected``.
    init(_ state: CBPeripheralState) {
        switch state {
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .disconnecting:
            self = .disconnecting
        case .disconnected:
            self = .disconnected
        @unknown default:
            self = .disconnected
        }
    }
}
