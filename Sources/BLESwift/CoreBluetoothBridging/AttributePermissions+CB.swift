//
//  AttributePermissions+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

/// `CBAttributePermissions` bridging for ``AttributePermissions``. The two have the same
/// raw-value layout, so the bridge passes the raw value through.
extension AttributePermissions {

    /// Creates an ``AttributePermissions`` from a `CBAttributePermissions` option set.
    init(_ cbPermissions: CBAttributePermissions) {
        self.init(rawValue: cbPermissions.rawValue)
    }

    /// The `CBAttributePermissions` representation of this option set.
    var cbPermissions: CBAttributePermissions {
        CBAttributePermissions(rawValue: rawValue)
    }
}
