//
//  GATTTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
@testable import BLESwift

/// Exercises `Peripheral`'s Phase 6 GATT surface: `read`, `write`, `readRSSI`,
/// `maximumWriteValueLength`, and `serviceChanges()` — all driven through
/// `makeTestCentral()`'s `FakeCentral`/`FakePeripheral` pair, connected first via the
/// Phase 5 connection lifecycle.
@Suite("GATT operations")
struct GATTTests {

    // MARK: - Fixtures

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)
    private static let bodySensorLocation = CharacteristicIdentifier(uuid: "2A38", service: heartRateService)

    private static let batteryService = ServiceIdentifier(uuid: "180F")
    private static let batteryLevel = CharacteristicIdentifier(uuid: "2A19", service: batteryService)

    // MARK: - Read / write round-trips

    @Test("read() decodes the scripted value")
    func readRoundTrip() async throws {
        let (_, fakeCentral, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.onQueue { fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([42]) }

        let value: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(value == 42)
        _ = fakeCentral
    }

    @Test("write() sends the encoded value and completes")
    func writeRoundTrip() async throws {
        let (_, fakeCentral, fakePeripheral, peripheral) = try await connected()

        try await peripheral.write(UInt8(7), to: Self.heartRateMeasurement)

        #expect(fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.heartRateMeasurement] } == 1)
        _ = fakeCentral
    }

    @Test("read() propagates a Receivable decode failure instead of the raw bytes")
    func readDecodeFailurePropagates() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        // 0xFF is not valid standalone UTF-8.
        fakePeripheral.onQueue { fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([0xFF]) }

        do {
            let _: String = try await peripheral.read(from: Self.heartRateMeasurement)
            Issue.record("expected a decode failure")
        } catch let error as BLESwiftError {
            #expect(error == .invalidStringEncoding)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Lazy discovery / cache short-circuit

    @Test("Discovery is lazy and cached: a second read on the same characteristic issues no further discovery calls")
    func discoveryCacheHit() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.onQueue { fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([1]) }

        let _: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 1)

        let _: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 1)
    }

    @Test("Pre-seeded discovery short-circuits entirely: no discovery calls at all")
    func preSeededDiscoverySkipsDiscoveryCalls() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.simulateDiscoveredServices([Self.heartRateService])
        fakePeripheral.simulateDiscoveredCharacteristics([Self.heartRateMeasurement], for: Self.heartRateService)
        fakePeripheral.onQueue { fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([9]) }

        let value: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(value == 9)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 0)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 0)
    }

    @Test("A characteristic genuinely absent from an otherwise-discovered service's GATT table throws .missingCharacteristic")
    func missingCharacteristicThrows() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        // The service is real, but its GATT table doesn't actually contain
        // `heartRateMeasurement` — only a different characteristic under it.
        fakePeripheral.onQueue {
            fakePeripheral.availableServices = [Self.heartRateService: [Self.bodySensorLocation]]
        }

        do {
            let _: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
            Issue.record("expected .missingCharacteristic")
        } catch let error as BLESwiftError {
            #expect(error == .missingCharacteristic(Self.heartRateMeasurement))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("A service genuinely absent from the peripheral's GATT table throws .missingService")
    func missingServiceThrows() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        // The peripheral's GATT table exists (scripted) but simply doesn't include
        // `heartRateService` at all — e.g. only the battery service is present.
        fakePeripheral.onQueue {
            fakePeripheral.availableServices = [Self.batteryService: [Self.batteryLevel]]
        }

        do {
            let _: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
            Issue.record("expected .missingService")
        } catch let error as BLESwiftError {
            #expect(error == .missingService(Self.heartRateService))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Per-characteristic FIFO ordering vs. cross-characteristic interleaving

    @Test("Two reads on the SAME characteristic are serialized: the second doesn't start until the first completes")
    func sameCharacteristicReadsAreSerialized() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.onQueue {
            fakePeripheral.holdReadCompletions = true
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([1])
        }

        let first = Task<UInt8, Error> {
            try await peripheral.read(from: Self.heartRateMeasurement)
        }
        await waitUntil { fakePeripheral.onQueue { fakePeripheral.readCallCount } == 1 }

        let second = Task<UInt8, Error> {
            try await peripheral.read(from: Self.heartRateMeasurement)
        }
        // Give the second read every opportunity to (incorrectly) start early.
        try await Task.sleep(for: .milliseconds(50))
        #expect(fakePeripheral.onQueue { fakePeripheral.readCallCount } == 1, "second read must not start until the first completes")

        fakePeripheral.simulateNextHeldReadCompletion()
        let firstValue = try await first.value
        #expect(firstValue == 1)

        // Only now — after the first read has fully resolved — should the second read's
        // `readValue(for:)` call happen, proving the FIFO unblocked it in order (rather
        // than distinguishing the two reads by scripting different return values, which
        // would race: `readValue(for:)` captures the scripted value at *call* time, and
        // that call is exactly the event being awaited here).
        await waitUntil { fakePeripheral.onQueue { fakePeripheral.readCallCount } == 2 }
        fakePeripheral.simulateNextHeldReadCompletion()
        let secondValue = try await second.value
        #expect(secondValue == 1)
    }

    @Test("Reads on DIFFERENT characteristics interleave freely: neither waits for the other")
    func differentCharacteristicReadsInterleave() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.onQueue {
            fakePeripheral.holdReadCompletions = true
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([11])
            fakePeripheral.scriptedReadValues[Self.batteryLevel] = Data([22])
        }

        let readA = Task<UInt8, Error> {
            try await peripheral.read(from: Self.heartRateMeasurement)
        }
        await waitUntil { fakePeripheral.onQueue { fakePeripheral.readCallCount } == 1 }

        let readB = Task<UInt8, Error> {
            try await peripheral.read(from: Self.batteryLevel)
        }
        // Different characteristic — must be able to start without waiting on `readA`.
        await waitUntil { fakePeripheral.onQueue { fakePeripheral.readCallCount } == 2 }

        fakePeripheral.simulateNextHeldReadCompletion()
        fakePeripheral.simulateNextHeldReadCompletion()

        let valueA = try await readA.value
        let valueB = try await readB.value
        #expect(valueA == 11)
        #expect(valueB == 22)
    }

    // MARK: - write(.withoutResponse) back-pressure

    @Test(".withoutResponse write waits for canSendWriteWithoutResponse before writing")
    func withoutResponseBackPressure() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.simulateWriteWithoutResponseBackPressure()

        let writeTask = Task {
            try await peripheral.write(UInt8(1), to: Self.heartRateMeasurement, type: .withoutResponse)
        }

        // Give the write every opportunity to (incorrectly) proceed while blocked.
        try await Task.sleep(for: .milliseconds(50))
        #expect(fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.heartRateMeasurement] } == nil)

        fakePeripheral.simulateReadyToSendWriteWithoutResponse()
        try await writeTask.value

        #expect(fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.heartRateMeasurement] } == 1)
    }

    @Test(".withoutResponse write proceeds immediately when already ready")
    func withoutResponseWritesImmediatelyWhenReady() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()

        try await peripheral.write(UInt8(1), to: Self.heartRateMeasurement, type: .withoutResponse)

        #expect(fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.heartRateMeasurement] } == 1)
    }

    // MARK: - RSSI

    @Test("readRSSI() returns the scripted value")
    func readRSSIReturnsValue() async throws {
        let (_, _, _, peripheral) = try await connected()
        let rssi = try await peripheral.readRSSI()
        #expect(rssi == -50) // FakePeripheral's fixed placeholder value.
    }

    @Test("maximumWriteValueLength(for:) returns the scripted value")
    func maximumWriteValueLengthReturnsScriptedValue() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.onQueue { fakePeripheral.scriptedMaximumWriteValueLength = 182 }

        let length = await peripheral.maximumWriteValueLength(for: .withoutResponse)
        #expect(length == 182)
    }

    // MARK: - didModifyServices / serviceChanges()

    @Test("didModifyServices emits on serviceChanges() and forces re-discovery on the next op")
    func serviceModificationInvalidatesDiscoveryCache() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.simulateDiscoveredServices([Self.heartRateService])
        fakePeripheral.simulateDiscoveredCharacteristics([Self.heartRateMeasurement], for: Self.heartRateService)
        fakePeripheral.onQueue { fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([1]) }

        let stream = peripheral.serviceChanges()
        let collector = Task<[ServiceIdentifier]?, Never> {
            var iterator = stream.makeAsyncIterator()
            let next = await iterator.next()
            return next
        }
        await Task.yield()

        fakePeripheral.simulateServiceModification(invalidatedServices: [Self.heartRateService])
        let invalidated = await collector.value
        #expect(invalidated?.first == Self.heartRateService)

        #expect(fakePeripheral.onQueue { fakePeripheral.isDiscovered(Self.heartRateService) } == false)
        #expect(fakePeripheral.onQueue { fakePeripheral.isDiscovered(Self.heartRateMeasurement) } == false)

        // The next read must re-discover from scratch.
        let value: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(value == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
        #expect(fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount } == 1)
    }

    // MARK: - Read-while-notifying

    @Test("read() on a currently-notifying characteristic throws .readConflictsWithNotification")
    func readWhileNotifyingThrows() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.simulateDiscoveredServices([Self.heartRateService])
        fakePeripheral.simulateDiscoveredCharacteristics([Self.heartRateMeasurement], for: Self.heartRateService)
        fakePeripheral.onQueue { fakePeripheral.setNotifyValue(true, for: Self.heartRateMeasurement) }
        fakePeripheral.onQueue {} // flush didUpdateNotificationState delivery

        do {
            let _: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement)
            Issue.record("expected .readConflictsWithNotification")
        } catch let error as BLESwiftError {
            #expect(error == .readConflictsWithNotification)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Disconnect / timeout

    @Test("GATT operations fail when the connection is lost mid-flight")
    func gattOperationsFailOnDisconnect() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.onQueue {
            fakePeripheral.holdReadCompletions = true
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([1])
        }

        let readTask = Task<UInt8, Error> {
            try await peripheral.read(from: Self.heartRateMeasurement)
        }
        await waitUntil { fakePeripheral.onQueue { fakePeripheral.readCallCount } == 1 }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let result = await readTask.result
        switch result {
        case .success:
            Issue.record("expected the read to fail once disconnected")
        case .failure(let error as BLESwiftError):
            #expect(error == .unexpectedDisconnect)
        case .failure(let error):
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        guard case .disconnected = await central.connectionState else {
            Issue.record("expected .disconnected")
            return
        }
    }

    @Test("A read that never completes throws .timedOut")
    func readTimesOut() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connected()
        fakePeripheral.onQueue { fakePeripheral.holdReadCompletions = true }

        do {
            let _: UInt8 = try await peripheral.read(from: Self.heartRateMeasurement, timeout: .milliseconds(30))
            Issue.record("expected .timedOut")
        } catch let error as BLESwiftError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }
}

// MARK: - Test helpers

/// Registers `peripheral` as retrievable and connects to it, returning the connected
/// `Peripheral` handle alongside the `Central`/`FakeCentral`/`FakePeripheral` backing it.
private func connected() async throws -> (Central, FakeCentral, FakePeripheral, Peripheral) {
    let (central, fakeCentral, fakePeripheral) = makeTestCentral()
    fakeCentral.onQueue {
        fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
        fakeCentral.connectBehavior = .succeed
    }
    let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
    return (central, fakeCentral, fakePeripheral, peripheral)
}

/// Polls `condition` until it's `true`, or a generous timeout elapses.
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
