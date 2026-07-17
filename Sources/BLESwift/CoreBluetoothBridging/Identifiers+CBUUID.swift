//
//  Identifiers+CBUUID.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

/// `CBUUID` bridging for ``ServiceIdentifier``/``CharacteristicIdentifier`` — the only
/// place in `BLESwift` these identifiers cross to/from CoreBluetooth's own UUID type.
/// Built entirely on ``ServiceIdentifier``/``CharacteristicIdentifier``'s public members
/// (`uuidString`, and the validating `init(uuid:)`), so no bridging-specific storage is
/// needed on the Core types themselves.
extension ServiceIdentifier {

    /// Creates a `ServiceIdentifier` from a `CBUUID`.
    init(cbuuid: CBUUID) {
        self.init(uuid: cbuuid.uuidString)
    }

    /// The `CBUUID` representation of this identifier.
    var cbuuid: CBUUID {
        CBUUID(string: uuidString)
    }
}

extension CharacteristicIdentifier {

    /// Creates a `CharacteristicIdentifier` from a `CBUUID` and its owning service.
    init(cbuuid: CBUUID, service: ServiceIdentifier) {
        self.init(uuid: cbuuid.uuidString, service: service)
    }

    /// The `CBUUID` representation of this identifier.
    var cbuuid: CBUUID {
        CBUUID(string: uuidString)
    }
}
