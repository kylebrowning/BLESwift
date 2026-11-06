//
//  WriteType+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension WriteType {

    /// The equivalent `CBCharacteristicWriteType`.
    var cbWriteType: CBCharacteristicWriteType {
        switch self {
        case .withResponse:
            return .withResponse
        case .withoutResponse:
            return .withoutResponse
        }
    }
}
