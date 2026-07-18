//
//  CharacteristicProperties+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension CharacteristicProperties {

    /// Maps a native `CBCharacteristicProperties` bitmask into BLESwift's own
    /// ``CharacteristicProperties``, the sanctioned CoreBluetooth seam for this type.
    ///
    /// Only the eight properties BLESwift models are mapped; `CBCharacteristicProperties`'s
    /// `notifyEncryptionRequired`/`indicateEncryptionRequired` have no BLESwift equivalent
    /// and are intentionally dropped.
    init(_ cbProperties: CBCharacteristicProperties) {
        var properties: CharacteristicProperties = []
        if cbProperties.contains(.read) { properties.insert(.read) }
        if cbProperties.contains(.write) { properties.insert(.write) }
        if cbProperties.contains(.writeWithoutResponse) { properties.insert(.writeWithoutResponse) }
        if cbProperties.contains(.notify) { properties.insert(.notify) }
        if cbProperties.contains(.indicate) { properties.insert(.indicate) }
        if cbProperties.contains(.authenticatedSignedWrites) { properties.insert(.authenticatedSignedWrites) }
        if cbProperties.contains(.extendedProperties) { properties.insert(.extendedProperties) }
        if cbProperties.contains(.broadcast) { properties.insert(.broadcast) }
        self = properties
    }
}
