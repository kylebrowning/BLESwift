//
//  WriteType+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension WriteType {

    /// This write type's `CBCharacteristicWriteType` equivalent.
    var cbWriteType: CBCharacteristicWriteType {
        switch self {
        case .withResponse:
            return .withResponse
        case .withoutResponse:
            return .withoutResponse
        }
    }
}
