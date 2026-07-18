//
//  CharacteristicPropertiesTests.swift
//  BLESwiftTests
//

import CoreBluetooth
import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
@testable import BLESwift

/// Exercises characteristic property introspection: the `CBCharacteristicProperties` →
/// ``CharacteristicProperties`` mapping at the CoreBluetooth seam, `Peripheral.properties(of:)`
/// triggering lazy discovery, and the scriptable `FakePeripheral` round-trip — all driven
/// through `makeConnectedTestCentral()`'s fakes.
@Suite("Characteristic properties")
struct CharacteristicPropertiesTests {

    // MARK: - Fixtures

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)

    // MARK: - CoreBluetooth mapping (one bit at a time)

    @Test("each CBCharacteristicProperties bit maps to its CharacteristicProperties member")
    func mapsEachBit() {
        #expect(CharacteristicProperties(CBCharacteristicProperties.read) == .read)
        #expect(CharacteristicProperties(CBCharacteristicProperties.write) == .write)
        #expect(CharacteristicProperties(CBCharacteristicProperties.writeWithoutResponse) == .writeWithoutResponse)
        #expect(CharacteristicProperties(CBCharacteristicProperties.notify) == .notify)
        #expect(CharacteristicProperties(CBCharacteristicProperties.indicate) == .indicate)
        #expect(CharacteristicProperties(CBCharacteristicProperties.authenticatedSignedWrites) == .authenticatedSignedWrites)
        #expect(CharacteristicProperties(CBCharacteristicProperties.extendedProperties) == .extendedProperties)
        #expect(CharacteristicProperties(CBCharacteristicProperties.broadcast) == .broadcast)
    }

    @Test("an empty CBCharacteristicProperties maps to an empty set")
    func mapsEmpty() {
        #expect(CharacteristicProperties([]) == [])
    }

    @Test("a combined CBCharacteristicProperties maps every set bit")
    func mapsCombined() {
        let combined: CBCharacteristicProperties = [.read, .write, .notify, .indicate]
        #expect(CharacteristicProperties(combined) == [.read, .write, .notify, .indicate])
    }

    @Test("CoreBluetooth bits BLESwift doesn't model are dropped, not mismapped")
    func dropsUnmodeledBits() {
        // `notifyEncryptionRequired`/`indicateEncryptionRequired` have no BLESwift equivalent.
        #expect(CharacteristicProperties(CBCharacteristicProperties.notifyEncryptionRequired) == [])
        #expect(CharacteristicProperties(CBCharacteristicProperties.indicateEncryptionRequired) == [])
        // A payload mixing modeled and unmodeled bits keeps only the modeled ones.
        let mixed: CBCharacteristicProperties = [.read, .notifyEncryptionRequired]
        #expect(CharacteristicProperties(mixed) == .read)
    }

    // MARK: - Scriptable fake round-trip

    @Test("properties(of:) returns exactly what the fake scripts")
    func scriptedRoundTrip() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        fakePeripheral.onQueue {
            fakePeripheral.scriptedProperties[Self.heartRateMeasurement] = [.read, .indicate, .authenticatedSignedWrites]
        }

        let properties = try await peripheral.properties(of: Self.heartRateMeasurement)
        #expect(properties == [.read, .indicate, .authenticatedSignedWrites])
    }

    @Test("properties(of:) falls back to the fake's default set when nothing is scripted")
    func unscriptedDefault() async throws {
        let (_, _, _, peripheral) = try await makeConnectedTestCentral()

        let properties = try await peripheral.properties(of: Self.heartRateMeasurement)
        #expect(properties == FakePeripheral.defaultProperties)
        #expect(properties == [.read, .write, .notify])
    }

    // MARK: - Lazy discovery

    @Test("properties(of:) triggers discovery once, like every other GATT op")
    func triggersDiscoveryOnce() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        #expect(fakePeripheral.onQueue { fakePeripheral.isDiscovered(Self.heartRateMeasurement) } == false)

        _ = try await peripheral.properties(of: Self.heartRateMeasurement)

        #expect(fakePeripheral.onQueue { fakePeripheral.isDiscovered(Self.heartRateService) } == true)
        #expect(fakePeripheral.onQueue { fakePeripheral.isDiscovered(Self.heartRateMeasurement) } == true)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 1)
    }

    @Test("a second properties(of:) reuses the discovery cache, discovering nothing new")
    func reusesDiscoveryCache() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        _ = try await peripheral.properties(of: Self.heartRateMeasurement)
        _ = try await peripheral.properties(of: Self.heartRateMeasurement)

        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 1)
    }

    @Test("properties(of:) on a disconnected peripheral throws .notConnected")
    func throwsWhenDisconnected() async throws {
        let (central, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        try await central.disconnect(fakePeripheral.peripheralIdentifier)

        await #expect(throws: BLESwiftError.self) {
            _ = try await peripheral.properties(of: Self.heartRateMeasurement)
        }
    }
}
