//
//  CentralState+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension CentralState {

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
