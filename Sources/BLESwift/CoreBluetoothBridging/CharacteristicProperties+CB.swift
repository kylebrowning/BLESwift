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
    /// BLESwift's raw-value layout intentionally does *not* match
    /// `CBCharacteristicProperties`, so this maps bit-by-bit rather than by raw value.
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

    /// The `CBCharacteristicProperties` representation of this option set, for building a
    /// `CBMutableCharacteristic` in the peripheral role. Maps bit-by-bit — the exact
    /// inverse of ``init(_:)``.
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
