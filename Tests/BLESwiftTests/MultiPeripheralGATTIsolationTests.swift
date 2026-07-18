//
//  MultiPeripheralGATTIsolationTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
@testable import BLESwift

/// Exercises Phase 2's multi-peripheral GATT/service-change isolation: closes the one
/// event-identity gap plan 02 identified (`serviceChanges()`, now backed by
/// `ServiceChangesRegistry`) and audits every `PeripheralEvent` case `Central.handle(_:from:)`
/// routes, proving each one is attributed to the emitting peripheral — never its sibling —
/// when two sessions are live simultaneously. `didUpdateValue`/`didUpdateNotificationState`
/// isolation via the high-level `notifications(for:)` API is exercised in
/// `NotificationTests.swift`; `writeAndAwaitNotification` cross-talk is exercised in
/// `CompositeTests.swift`. This file covers what those don't: `serviceChanges()`,
/// concurrent reads/RSSI/writes/write-without-response-readiness across two sessions, and
/// the untracked-peripheral drop path.
@Suite("Multi-peripheral GATT/service-change isolation")
struct MultiPeripheralGATTIsolationTests {

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)

    // MARK: - serviceChanges() isolation

    @Test("didModifyServices from A appears only on A's serviceChanges(); a concurrent B subscriber sees nothing")
    func serviceChangesIsolatedPerPeripheral() async throws {
        let (_, _, fakePeripheralA, peripheralA, _, peripheralB) = try await connectedPair()

        let streamA = peripheralA.serviceChanges()
        let collectorA = Task<[ServiceIdentifier]?, Never> {
            var iterator = streamA.makeAsyncIterator()
            return await iterator.next()
        }
        let streamB = peripheralB.serviceChanges()
        let collectorB = Task<[ServiceIdentifier]?, Never> {
            var iterator = streamB.makeAsyncIterator()
            return await iterator.next()
        }
        await Task.yield()
        await Task.yield()

        fakePeripheralA.simulateServiceModification(invalidatedServices: [Self.heartRateService])

        let invalidatedA = await collectorA.value
        #expect(invalidatedA?.first == Self.heartRateService)

        // Give B's stream every opportunity to (incorrectly) observe A's invalidation.
        try await Task.sleep(for: .milliseconds(100))
        collectorB.cancel()
        let invalidatedB = await collectorB.value
        #expect(invalidatedB == nil, "B's serviceChanges() must not observe A's service invalidation")
    }

    // MARK: - Per-characteristic FIFO isolation across peripherals

    @Test("Reads on A and B, both against the SAME characteristic identifier, interleave freely — FIFO tails are per-session, not global")
    func readsOnTwoPeripheralsInterleaveEvenOnTheSameCharacteristic() async throws {
        let (_, _, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB) = try await connectedPair()
        await fakePeripheralA.onQueue {
            fakePeripheralA.holdReadCompletions = true
            fakePeripheralA.scriptedReadValues[Self.heartRateMeasurement] = Data([0xAA])
        }
        await fakePeripheralB.onQueue {
            fakePeripheralB.holdReadCompletions = true
            fakePeripheralB.scriptedReadValues[Self.heartRateMeasurement] = Data([0xBB])
        }

        let readA = Task<UInt8, Error> { try await peripheralA.read(from: Self.heartRateMeasurement) }
        await waitFor { await fakePeripheralA.onQueue { fakePeripheralA.readCallCount } == 1 }

        let readB = Task<UInt8, Error> { try await peripheralB.read(from: Self.heartRateMeasurement) }
        // B must be able to start without waiting on A's still-held read, even though both
        // target the identical characteristic identifier.
        await waitFor { await fakePeripheralB.onQueue { fakePeripheralB.readCallCount } == 1 }

        fakePeripheralA.simulateNextHeldReadCompletion()
        fakePeripheralB.simulateNextHeldReadCompletion()

        let valueA = try await readA.value
        let valueB = try await readB.value
        #expect(valueA == 0xAA)
        #expect(valueB == 0xBB)
    }

    // MARK: - didReadRSSI routing

    @Test("readRSSI() on A and B, called concurrently, each resolve with their OWN peripheral's scripted value")
    func concurrentRSSIReadsResolveWithOwnValue() async throws {
        let (_, _, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB) = try await connectedPair()
        await fakePeripheralA.onQueue { fakePeripheralA.scriptedRSSI = -40 }
        await fakePeripheralB.onQueue { fakePeripheralB.scriptedRSSI = -85 }

        async let rssiA = peripheralA.readRSSI()
        async let rssiB = peripheralB.readRSSI()
        let (valueA, valueB) = try await (rssiA, rssiB)

        #expect(valueA == -40)
        #expect(valueB == -85)
    }

    // MARK: - didWriteValue routing

    @Test("Concurrent writes to A and B, both against the SAME characteristic identifier, each complete against their own peripheral")
    func concurrentWritesToTwoPeripheralsCompleteIndependently() async throws {
        let (_, _, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB) = try await connectedPair()

        async let writeA: Void = peripheralA.write(UInt8(1), to: Self.heartRateMeasurement)
        async let writeB: Void = peripheralB.write(UInt8(2), to: Self.heartRateMeasurement)
        _ = try await (writeA, writeB)

        #expect(await fakePeripheralA.onQueue { fakePeripheralA.writeCallCounts[Self.heartRateMeasurement] } == 1)
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.writeCallCounts[Self.heartRateMeasurement] } == 1)
    }

    // MARK: - isReadyToSendWriteWithoutResponse routing

    @Test("isReadyToSendWriteWithoutResponse signals only the peripheral it was raised for; the other's blocked write stays blocked")
    func writeWithoutResponseReadinessRoutesPerPeripheral() async throws {
        let (_, _, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB) = try await connectedPair()
        fakePeripheralA.simulateWriteWithoutResponseBackPressure()
        fakePeripheralB.simulateWriteWithoutResponseBackPressure()

        let writeATask = Task { try await peripheralA.write(UInt8(1), to: Self.heartRateMeasurement, type: .withoutResponse) }
        let writeBTask = Task { try await peripheralB.write(UInt8(2), to: Self.heartRateMeasurement, type: .withoutResponse) }

        // Give both every opportunity to (incorrectly) proceed while both are blocked.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fakePeripheralA.onQueue { fakePeripheralA.writeCallCounts[Self.heartRateMeasurement] } == nil)
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.writeCallCounts[Self.heartRateMeasurement] } == nil)

        fakePeripheralA.simulateReadyToSendWriteWithoutResponse()
        try await writeATask.value
        #expect(await fakePeripheralA.onQueue { fakePeripheralA.writeCallCounts[Self.heartRateMeasurement] } == 1)

        // B's readiness signal was never raised — its write must still be blocked.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.writeCallCounts[Self.heartRateMeasurement] } == nil)

        fakePeripheralB.simulateReadyToSendWriteWithoutResponse()
        try await writeBTask.value
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.writeCallCounts[Self.heartRateMeasurement] } == 1)
    }

    // MARK: - Untracked-peripheral drop

    @Test("didUpdateValue for a never-connected peripheral identifier is dropped, not routed to any live session")
    func didUpdateValueForUntrackedPeripheralIsDropped() async throws {
        let (central, _, _, _, fakePeripheralB, peripheralB) = try await connectedPair()

        let neverConnected = PeripheralIdentifier(uuid: UUID(), name: "Never Connected")
        await central.handle(
            .didUpdateValue(characteristic: Self.heartRateMeasurement, value: Data([0x99]), error: nil),
            from: neverConnected
        )

        // Dropped, not crashed, and not misrouted: B's own subsequent read still resolves
        // with its OWN scripted value, untouched by the bogus delivery.
        await fakePeripheralB.onQueue { fakePeripheralB.scriptedReadValues[Self.heartRateMeasurement] = Data([0x42]) }
        let value: UInt8 = try await peripheralB.read(from: Self.heartRateMeasurement)
        #expect(value == 0x42)

        guard case .disconnected = await central.connectionState(of: neverConnected) else {
            Issue.record("expected .disconnected — no entry should ever be created for an untracked identifier")
            return
        }
    }
}

// MARK: - Test helpers

/// Connects two `FakePeripheral`s (A: `makeTestCentral()`'s primary; B:
/// `addFakePeripheral(to:fakeCentral:)`) against one `Central`, returning both the fakes
/// and the connected `Peripheral` handles.
private func connectedPair() async throws -> (Central, FakeCentral, FakePeripheral, Peripheral, FakePeripheral, Peripheral) {
    let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
    let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
    // Power the radio on first: the last-release `setNotifyValue(false)` is ledger-guarded
    // on `.poweredOn`, matching `makeConnectedTestCentral()`'s own setup.
    fakeCentral.simulateStateChange(.poweredOn)
    await fakeCentral.onQueue {
        fakeCentral.retrievablePeripherals[fakePeripheralA.identifier] = fakePeripheralA
        fakeCentral.connectBehavior = .succeed
    }
    let peripheralA = try await central.connect(fakePeripheralA.peripheralIdentifier)
    let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)
    return (central, fakeCentral, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB)
}
