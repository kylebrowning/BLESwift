//
//  CharacteristicProperties+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension CharacteristicProperties {

    /// Maps a `CBCharacteristicProperties` bitmask to ``CharacteristicProperties``.
    ///
    /// The raw-value layouts differ, so the code maps bit by bit. It maps only the eight
    /// properties that BLESwift models. It drops `notifyEncryptionRequired` and
    /// `indicateEncryptionRequired`.
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

    /// The `CBCharacteristicProperties` for this option set, for a `CBMutableCharacteristic` in
    /// the peripheral role. It is the exact inverse of ``init(_:)``.
    var cbProperties: CBCharacteristicProperties {
        var properties: CBCharacteristicProperties = []
        if contains(.read) { properties.insert(.read) }
        if contains(.write) { properties.insert(.write) }
        if contains(.writeWithoutResponse) { properties.insert(.writeWithoutResponse) }
        if contains(.notify) { properties.insert(.notify) }
        if contains(.indicate) { properties.insert(.indicate) }
        if contains(.authenticatedSignedWrites) { properties.insert(.authenticatedSignedWrites) }
        if contains(.extendedProperties) { properties.insert(.extendedProperties) }
        if contains(.broadcast) { properties.insert(.broadcast) }
        return properties
    }
}
