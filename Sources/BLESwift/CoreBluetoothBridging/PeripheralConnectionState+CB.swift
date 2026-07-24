//
//  PeripheralConnectionState+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension PeripheralConnectionState {

    /// Maps `CBPeripheralState` into BLESwift's own vocabulary (no CoreBluetooth types in
    /// the public API). `@unknown` future states map to ``disconnected`` — the safe
    /// reading.
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
