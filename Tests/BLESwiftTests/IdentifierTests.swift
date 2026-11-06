//
//  IdentifierTests.swift
//  BLESwiftTests
//

import CoreBluetooth
import Foundation
import Testing
import BLESwiftCore
import BLESwift

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

    @Test("PeripheralIdentifier keeps a missing name as nil and displays it as \"No Name\"")
    func peripheralIdentifierDefaultName() {
        let identifier = PeripheralIdentifier(uuid: UUID(), name: nil)
        #expect(identifier.cachedName == nil)
        #expect(identifier.name == "No Name")
    }

    @Test("A peripheral actually named \"No Name\" is distinguishable from an unnamed one")
    func peripheralIdentifierLiteralNoName() {
        let named = PeripheralIdentifier(uuid: UUID(), name: "No Name")
        #expect(named.cachedName == "No Name")
        #expect(named.name == "No Name")
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

    // MARK: - CBUUID parity (T1.3 BINDING requirement)

    /// A corpus of valid UUID strings. It covers every accepted form (the 4-hex short form, the
    /// 8-hex long-short form, and the 36-character dashed 128-bit form), uppercase and lowercase,
    /// and some real Bluetooth SIG UUIDs.
    private static let validCorpus: [String] = [
        "180D", "180d", "2A37", "2a37",
        "0000180D", "0000180d", "FFFFFFFF", "ffffffff",
        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
        "6e400001-b5a3-f393-e0a9-e50e24dcca9e",
        "6E400001-b5a3-F393-e0a9-E50E24dcca9e",
        "00001800-0000-1000-8000-00805F9B34FB",
        "00001800-0000-1000-8000-00805f9b34fb",
    ]

    @Test(
        "ServiceIdentifier(uuid:)'s pure-Swift normalization matches CBUUID(string:).uuidString exactly, for every valid corpus string",
        arguments: validCorpus
    )
    func normalizationMatchesCBUUIDParity(_ uuid: String) {
        let pureResult = ServiceIdentifier(uuid: uuid).uuidString
        let cbResult = CBUUID(string: uuid).uuidString
        #expect(pureResult == cbResult)
    }

    // NOTE: The tests do not run the invalid corpus, because Swift Testing cannot catch a
    // `preconditionFailure` trap. A person verified each string interactively with a scratch
    // executable. Each traps as `CBUUID(string:)` does, with an ObjC exception ("String <x> does
    // not represent a valid UUID"), for `ServiceIdentifier(uuid:)`,
    // `CharacteristicIdentifier(uuid:)`, and `CBUUID(string:)`. The strings are:
    // - "" (empty string)
    // - "18" (too short: not 4, 8, or 36 characters)
    // - "180D0" (5 characters)
    // - "ZZZZ" (4 characters, not hex)
    // - "6E400001B5A3F393E0A9E50E24DCCA9E" (32 hex characters, no dashes). The real SDK's CBUUID
    //   rejects this exact form.
    // - "6E400001-B5A3-F393-E0A9-E50E24DCCA9" (35 characters, one too few)
    // - "GE400001-B5A3-F393-E0A9-E50E24DCCA9E" (36 characters, a non-hex digit at a hex position)
    // - "6E400001XB5A3-F393-E0A9-E50E24DCCA9E" (36 characters, a wrong character at a dash
    //   position)
}
