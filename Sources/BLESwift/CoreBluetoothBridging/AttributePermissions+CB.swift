//
//  AttributePermissions+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

/// `CBAttributePermissions` bridging for ``AttributePermissions`` — the only place in
/// `BLESwift` this option set crosses to/from CoreBluetooth. The two share raw-value layout
/// by construction, so the bridge is a raw-value passthrough.
extension AttributePermissions {

    /// Creates an ``AttributePermissions`` from CoreBluetooth's option set.
    init(_ cbPermissions: CBAttributePermissions) {
        self.init(rawValue: cbPermissions.rawValue)
    }

    /// The `CBAttributePermissions` representation of this option set.
    var cbPermissions: CBAttributePermissions {
        CBAttributePermissions(rawValue: rawValue)
    }
}
