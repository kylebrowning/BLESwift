//
//  PeripheralConnectionState+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension PeripheralConnectionState {

    /// Maps `CBPeripheralState` into BLESwift's own vocabulary (no CoreBluetooth types in
    /// the public API). `@unknown` future states map to ``disconnected`` — the safe
    /// reading (a state BLESwift doesn't understand is treated as nothing to restore/report).
    ///
    /// This mapping used to live on a restoration-only state enum; it is now unified into
    /// this one Core-owned connection-state type, shared by the backend seam and by state
    /// restoration alike.
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
