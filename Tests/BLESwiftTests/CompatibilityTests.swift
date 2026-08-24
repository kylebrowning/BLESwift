//
//  CompatibilityTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
@testable import BLESwift

/// Exercises ``GATTCompatibility`` — strict-by-default property enforcement on
/// read/write/notify, the per-flag bypasses, `.all` discovery's once-per-connection
/// `discoverServices(nil)`, and per-connection isolation of the setting.
@Suite("GATT compatibility mode")
struct CompatibilityTests {

    // MARK: - Fixtures

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)
    private static let batteryService = ServiceIdentifier(uuid: "180F")
    private static let batteryLevel = CharacteristicIdentifier(uuid: "2A19", service: batteryService)

    /// `makeConnectedTestCentral()` with a caller-chosen ``GATTCompatibility``.
    private func makeConnectedTestCentral(
        compatibility: GATTCompatibility
    ) async throws -> (Central, FakeCentral, FakePeripheral, Peripheral) {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier, compatibility: compatibility)
        return (central, fakeCentral, fakePeripheral, peripheral)
    }

    // MARK: - Notify enforcement

    @Test("strict: subscribing to a characteristic without .notify/.indicate fails the stream with unsupportedCharacteristicOperation")
    func strictNotifyWithoutPropertyThrows() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral(compatibility: .strict)
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedProperties[Self.heartRateMeasurement] = [.read]
        }

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        await #expect(throws: BLESwiftError.unsupportedCharacteristicOperation(Self.heartRateMeasurement, required: [.notify, .indicate])) {
            for try await _ in stream {}
        }
        // The failed subscription never reached setNotifyValue.
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.isEmpty })
    }

    @Test("allowNotifyWithoutProperty: the subscription proceeds and delivers values")
    func bypassNotifyWithoutPropertyDelivers() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral(
            compatibility: GATTCompatibility(allowNotifyWithoutProperty: true)
        )
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedProperties[Self.heartRateMeasurement] = [.read]
        }

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let collector = Task { try await collectData(stream, count: 1) }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([0x2A]))
        let received = try await collector.value
        #expect(received == [Data([0x2A])])
    }

    // MARK: - .all discovery

    @Test(".all discovery calls discoverServices(nil) exactly once per connection")
    func allDiscoveryRunsOnce() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral(
            compatibility: GATTCompatibility(discovery: .all)
        )
        await fakePeripheral.onQueue {
            fakePeripheral.availableServices = [
                Self.heartRateService: [Self.heartRateMeasurement],
                Self.batteryService: [Self.batteryLevel],
            ]
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([60])
            fakePeripheral.scriptedReadValues[Self.batteryLevel] = Data([99])
        }

        let heartRate: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(heartRate == 60)
        #expect(await fakePeripheral.onQueue { fakePeripheral.discoverServicesAllCallCount } == 1)

        // A second read — a different service entirely — triggers no further service
        // discovery of any kind: the one unfiltered pass revealed everything.
        let battery: UInt8 = try await peripheral.read(from: Self.batteryLevel)
        #expect(battery == 99)
        #expect(await fakePeripheral.onQueue { fakePeripheral.discoverServicesAllCallCount } == 1)
        #expect(await fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
    }

    // MARK: - Per-connection isolation

    @Test("peripheral A's .lenient never affects peripheral B's .strict on the same Central")
    func compatibilityIsPerConnection() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheralA.identifier] = fakePeripheralA
            fakeCentral.connectBehavior = .succeed
        }
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)

        // A is .lenient — .all discovery included, so its GATT table must genuinely exist.
        await fakeCentral.onQueue {
            fakePeripheralA.availableServices = [Self.heartRateService: [Self.heartRateMeasurement]]
            fakePeripheralA.scriptedProperties[Self.heartRateMeasurement] = [.read]
            fakePeripheralB.scriptedProperties[Self.heartRateMeasurement] = [.read]
        }

        let peripheralA = try await central.connect(fakePeripheralA.peripheralIdentifier, compatibility: .lenient)
        let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)

        // B (strict) refuses the no-.notify subscription.
        let streamB: AsyncThrowingStream<Data, Error> = peripheralB.notifications(for: Self.heartRateMeasurement)
        await #expect(throws: BLESwiftError.unsupportedCharacteristicOperation(Self.heartRateMeasurement, required: [.notify, .indicate])) {
            for try await _ in streamB {}
        }

        // A (.lenient) proceeds and delivers on the same characteristic identifier.
        let streamA: AsyncThrowingStream<Data, Error> = peripheralA.notifications(for: Self.heartRateMeasurement)
        let collector = Task { try await collectData(streamA, count: 1) }
        await waitFor { await fakeCentral.onQueue { fakePeripheralA.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }
        fakePeripheralA.simulateNotification(for: Self.heartRateMeasurement, value: Data([7]))
        let received = try await collector.value
        #expect(received == [Data([7])])
    }

    // MARK: - Read/write enforcement

    @Test("strict: reading a characteristic without .read throws unsupportedCharacteristicOperation")
    func strictReadWithoutPropertyThrows() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral(compatibility: .strict)
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedProperties[Self.heartRateMeasurement] = [.write, .notify]
        }

        await #expect(throws: BLESwiftError.unsupportedCharacteristicOperation(Self.heartRateMeasurement, required: [.read])) {
            let _: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        }
        #expect(await fakePeripheral.onQueue { fakePeripheral.readCallCount } == 0)
    }

    @Test("allowReadWithoutProperty: the read proceeds")
    func bypassReadWithoutPropertyProceeds() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral(
            compatibility: GATTCompatibility(allowReadWithoutProperty: true)
        )
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedProperties[Self.heartRateMeasurement] = [.write]
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([42])
        }

        let value: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(value == 42)
    }

    @Test("strict: writing without .write (withResponse) or .writeWithoutResponse (withoutResponse) throws, naming the property that write type requires")
    func strictWriteWithoutPropertyThrows() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral(compatibility: .strict)
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedProperties[Self.heartRateMeasurement] = [.read]
        }

        await #expect(throws: BLESwiftError.unsupportedCharacteristicOperation(Self.heartRateMeasurement, required: [.write])) {
            try await peripheral.write(UInt8(1), to: Self.heartRateMeasurement)
        }
        await #expect(throws: BLESwiftError.unsupportedCharacteristicOperation(Self.heartRateMeasurement, required: [.writeWithoutResponse])) {
            try await peripheral.write(UInt8(1), to: Self.heartRateMeasurement, type: .withoutResponse)
        }
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.heartRateMeasurement] } == nil)

        // .write alone still refuses .withoutResponse — the required property is per type.
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedProperties[Self.heartRateMeasurement] = [.write]
        }
        await #expect(throws: BLESwiftError.unsupportedCharacteristicOperation(Self.heartRateMeasurement, required: [.writeWithoutResponse])) {
            try await peripheral.write(UInt8(1), to: Self.heartRateMeasurement, type: .withoutResponse)
        }
    }

    @Test("allowWriteWithoutProperty: both write types proceed")
    func bypassWriteWithoutPropertyProceeds() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral(
            compatibility: GATTCompatibility(allowWriteWithoutProperty: true)
        )
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedProperties[Self.heartRateMeasurement] = [.read]
        }

        try await peripheral.write(UInt8(7), to: Self.heartRateMeasurement)
        try await peripheral.write(UInt8(8), to: Self.heartRateMeasurement, type: .withoutResponse)
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.heartRateMeasurement] } == 2)
    }

    // MARK: - Regression

    @Test("strict is the default and compliant characteristics are unaffected: read, both write types, and notify all work")
    func strictDefaultLeavesCompliantHardwareAlone() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral(compatibility: .strict)
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([5])
        }

        let value: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(value == 5)
        try await peripheral.write(UInt8(1), to: Self.heartRateMeasurement)
        try await peripheral.write(UInt8(2), to: Self.heartRateMeasurement, type: .withoutResponse)

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let collector = Task { try await collectData(stream, count: 1) }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([3]))
        #expect(try await collector.value == [Data([3])])
    }
}
