//
//  Identifiers+CBUUID.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

/// `CBUUID` bridging for the service, characteristic, and descriptor identifiers. It uses only
/// their public members (`uuidString` and the validating `init(uuid:)`).
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

extension DescriptorIdentifier {

    /// Creates a `DescriptorIdentifier` from a `CBUUID` and its owning characteristic.
    init(cbuuid: CBUUID, characteristic: CharacteristicIdentifier) {
        self.init(uuid: cbuuid.uuidString, characteristic: characteristic)
    }

    /// The `CBUUID` representation of this identifier.
    var cbuuid: CBUUID {
        CBUUID(string: uuidString)
    }
}
