//
//  DescriptorTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Exercises `Peripheral`'s characteristic-descriptor surface: `readDescriptor` and
/// `writeDescriptor`, their lazy (service → characteristic → descriptor) discovery and
/// caching, the `.missingDescriptor` failure, timeout, and disconnect teardown — all driven
/// through `makeTestCentral()`'s `FakeCentral`/`FakePeripheral` pair, connected first via
/// the connection lifecycle.
@Suite("Characteristic descriptors")
struct DescriptorTests {

    // MARK: - Fixtures

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)
    /// Characteristic User Description (0x2901).
    private static let userDescription = DescriptorIdentifier(uuid: "2901", characteristic: heartRateMeasurement)
    /// Characteristic Presentation Format (0x2904) — a second descriptor under the same
    /// characteristic, for absence tests.
    private static let presentationFormat = DescriptorIdentifier(uuid: "2904", characteristic: heartRateMeasurement)

    // MARK: - Read / write round-trips

    @Test("readDescriptor() returns the scripted raw bytes")
    func readRoundTrip() async throws {
        let (_, _, fakePeripheral, peripheral) = try await descriptorConnected()
        let payload = Data("Heart Rate".utf8)
        fakePeripheral.onQueue { fakePeripheral.scriptedDescriptorValues[Self.userDescription] = payload }

        let value = try await peripheral.readDescriptor(Self.userDescription)
        #expect(value == payload)
    }

    @Test("writeDescriptor() sends the raw bytes and completes")
    func writeRoundTrip() async throws {
        let (_, _, fakePeripheral, peripheral) = try await descriptorConnected()
        // Make the descriptor exist without scripting a read value (write-only path).
        fakePeripheral.onQueue {
            fakePeripheral.availableDescriptors = [Self.heartRateMeasurement: [Self.userDescription]]
        }
        let payload = Data([0x01, 0x02, 0x03])

        try await peripheral.writeDescriptor(Self.userDescription, value: payload)

        #expect(fakePeripheral.onQueue { fakePeripheral.descriptorWriteCallCounts[Self.userDescription] } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.writtenDescriptorValues[Self.userDescription] } == payload)
    }

    // MARK: - Lazy discovery / cache short-circuit

    @Test("Descriptor discovery is lazy and cached: a second read issues no further discovery calls")
    func discoveryCacheHit() async throws {
        let (_, _, fakePeripheral, peripheral) = try await descriptorConnected()
        fakePeripheral.onQueue { fakePeripheral.scriptedDescriptorValues[Self.userDescription] = Data([1]) }

        _ = try await peripheral.readDescriptor(Self.userDescription)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverDescriptorsCallCount } == 1)

        _ = try await peripheral.readDescriptor(Self.userDescription)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverDescriptorsCallCount } == 1)
    }

    @Test("Pre-seeded descriptor discovery short-circuits entirely: no discovery calls at all")
    func preSeededDiscoverySkipsDiscoveryCalls() async throws {
        let (_, _, fakePeripheral, peripheral) = try await descriptorConnected()
        fakePeripheral.simulateDiscoveredDescriptors([Self.userDescription])
        fakePeripheral.onQueue { fakePeripheral.scriptedDescriptorValues[Self.userDescription] = Data([9]) }

        let value = try await peripheral.readDescriptor(Self.userDescription)
        #expect(value == Data([9]))
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 0)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 0)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverDescriptorsCallCount } == 0)
    }

    // MARK: - Missing descriptor

    @Test("A descriptor genuinely absent from the characteristic's GATT table throws .missingDescriptor")
    func missingDescriptorThrows() async throws {
        let (_, _, fakePeripheral, peripheral) = try await descriptorConnected()
        // The characteristic exists and has a descriptor — but not the one we ask for.
        fakePeripheral.onQueue {
            fakePeripheral.availableDescriptors = [Self.heartRateMeasurement: [Self.presentationFormat]]
        }

        do {
            _ = try await peripheral.readDescriptor(Self.userDescription)
            Issue.record("expected .missingDescriptor")
        } catch let error as BLESwiftError {
            #expect(error == .missingDescriptor(Self.userDescription))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Timeout

    @Test("A descriptor read that never completes throws .timedOut")
    func readTimesOut() async throws {
        let (_, _, fakePeripheral, peripheral) = try await descriptorConnected()
        fakePeripheral.onQueue {
            // Descriptor exists (so discovery succeeds) but its read completion is withheld.
            fakePeripheral.scriptedDescriptorValues[Self.userDescription] = Data([1])
            fakePeripheral.holdDescriptorReadCompletions = true
        }

        do {
            _ = try await peripheral.readDescriptor(Self.userDescription, timeout: .milliseconds(30))
            Issue.record("expected .timedOut")
        } catch let error as BLESwiftError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Disconnect

    @Test("A pending descriptor read fails when the connection is lost mid-flight")
    func descriptorReadFailsOnDisconnect() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await descriptorConnected()
        fakePeripheral.onQueue {
            fakePeripheral.scriptedDescriptorValues[Self.userDescription] = Data([1])
            fakePeripheral.holdDescriptorReadCompletions = true
        }

        let readTask = Task<Data, Error> {
            try await peripheral.readDescriptor(Self.userDescription)
        }
        await waitUntilDescriptor { fakePeripheral.onQueue { fakePeripheral.descriptorReadCallCount } == 1 }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let result = await readTask.result
        switch result {
        case .success:
            Issue.record("expected the descriptor read to fail once disconnected")
        case .failure(let error as BLESwiftError):
            #expect(error == .unexpectedDisconnect)
        case .failure(let error):
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected")
            return
        }
    }
}

// MARK: - Test helpers

/// Registers `peripheral` as retrievable and connects to it, returning the connected
/// `Peripheral` handle alongside the `Central`/`FakeCentral`/`FakePeripheral` backing it.
private func descriptorConnected() async throws -> (Central, FakeCentral, FakePeripheral, Peripheral) {
    let (central, fakeCentral, fakePeripheral) = makeTestCentral()
    fakeCentral.onQueue {
        fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
        fakeCentral.connectBehavior = .succeed
    }
    let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
    return (central, fakeCentral, fakePeripheral, peripheral)
}

/// Polls `condition` until it's `true`, or a generous timeout elapses.
private func waitUntilDescriptor(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
