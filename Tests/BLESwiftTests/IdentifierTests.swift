//
//  IdentifierTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
@testable import BLESwift

@Suite("Identifiers")
struct IdentifierTests {

    @Test("PeripheralIdentifier equality is based on UUID only, not name")
    func peripheralIdentifierEquality() {
        let uuid = UUID()
        let a = PeripheralIdentifier(uuid: uuid, name: "Alpha")
        let b = PeripheralIdentifier(uuid: uuid, name: "Beta")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("PeripheralIdentifier defaults to \"No Name\" when name is nil")
    func peripheralIdentifierDefaultName() {
        let identifier = PeripheralIdentifier(uuid: UUID(), name: nil)
        #expect(identifier.name == "No Name")
    }

    @Test("ServiceIdentifier normalizes short-form UUIDs to their canonical string")
    func serviceIdentifierShortForm() {
        let identifier = ServiceIdentifier(uuid: "180D")
        #expect(identifier.uuidString == "180D")
    }

    @Test("ServiceIdentifier equality is based on the normalized UUID string")
    func serviceIdentifierEquality() {
        #expect(ServiceIdentifier(uuid: "180D") == ServiceIdentifier(uuid: "180d"))
    }

    @Test("CharacteristicIdentifier equality considers both the UUID and owning service")
    func characteristicIdentifierEquality() {
        let serviceA = ServiceIdentifier(uuid: "180D")
        let serviceB = ServiceIdentifier(uuid: "180F")
        let charOnA = CharacteristicIdentifier(uuid: "2A37", service: serviceA)
        let charOnASame = CharacteristicIdentifier(uuid: "2A37", service: serviceA)
        let charOnB = CharacteristicIdentifier(uuid: "2A37", service: serviceB)

        #expect(charOnA == charOnASame)
        #expect(charOnA != charOnB)
    }
}
