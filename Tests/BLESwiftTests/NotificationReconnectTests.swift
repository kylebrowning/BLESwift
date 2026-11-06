//
//  NotificationReconnectTests.swift
//  BLESwiftTests
//

import BLESwiftCore
import BLESwiftTestSupport
import Foundation
import Testing

@testable import BLESwift

/// Tests `Peripheral.notifications(for:policy:survivesReconnect:)`, which lets a notification
/// stream survive an automatic reconnect. The tests cover:
/// - delivery on the same stream after the gap
/// - the `.notificationsRestored` event
/// - the single CCCD write that the shared reference count makes to re-arm
/// - every way a gap can end without a restored stream: policy exhausted, GATT change, explicit
///   disconnect, and consumer gone
///
/// The tests use the fakes of `makeTestCentral()`.
@Suite("Notification survival across reconnect")
struct NotificationReconnectTests {

    // MARK: - Fixtures

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)
    private static let bodySensorLocation = CharacteristicIdentifier(uuid: "2A38", service: heartRateService)

    /// `makeTestCentral()` plus a completed connection that uses `reconnect`. The standard helper
    /// connects with `.never`.
    private func makeReconnectingRig(
        reconnect: ReconnectPolicy
    ) async throws -> (Central, FakeCentral, FakePeripheral, Peripheral) {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier, reconnect: reconnect)
        return (central, fakeCentral, fakePeripheral, peripheral)
    }

    /// Awaits the first `.notificationsRestored` of `events` and returns its payload.
    private func firstRestored(
        _ events: AsyncStream<ConnectionEvent>
    ) async -> (restored: [CharacteristicIdentifier], failed: [CharacteristicIdentifier: any Error])? {
        for await event in events {
            if case .notificationsRestored(_, let restored, let failed) = event {
                return (restored, failed)
            }
        }
        return nil
    }

    /// Calls `waitFor` on `central.connectionState(of:)` until it matches `state` (`.connected` or
    /// `.disconnected`, matched by structure).
    private func waitForConnectionState(_ central: Central, _ id: PeripheralIdentifier, connected: Bool) async {
        await waitFor {
            switch await central.connectionState(of: id) {
            case .connected: return connected
            case .disconnected: return !connected
            default: return false
            }
        }
    }

    // MARK: - The eight scenarios

    @Test("survivesReconnect: true — values delivered after the reconnect arrive on the original stream, and .notificationsRestored reports it")
    func streamSurvivesReconnect() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(backoff: .milliseconds(150))
        )
        let pid = fakePeripheral.peripheralIdentifier
        let events = await central.connectionEvents()
        let restoredTask = Task { await firstRestored(events) }

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(
            for: Self.heartRateMeasurement, survivesReconnect: true
        )
        var iterator = stream.makeAsyncIterator()
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([1]))
        #expect(try await iterator.next() == Data([1]))

        fakeCentral.simulateDisconnect(pid, error: nil)
        // The pump parks asynchronously relative to the disconnect. Wait for it inside the backoff
        // window so that the re-arm deterministically finds the pump waiting.
        await waitFor { await central.dormantNotificationWaiterCount(for: Self.heartRateMeasurement, on: pid) == 1 }

        let outcome = await restoredTask.value
        #expect(outcome?.restored == [Self.heartRateMeasurement])
        #expect(outcome?.failed.isEmpty == true)

        // The SAME stream (the same iterator) keeps delivering after the reconnect.
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([2]))
        #expect(try await iterator.next() == Data([2]))
    }

    @Test("survivesReconnect: false (the default) — the stream finishes with .unexpectedDisconnect and no .notificationsRestored is emitted")
    func defaultStreamFinishesAtDisconnect() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(backoff: .milliseconds(10))
        )
        let pid = fakePeripheral.peripheralIdentifier
        let events = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            var collected: [ConnectionEvent] = []
            for await event in events {
                collected.append(event)
            }
            return collected
        }

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let task = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakeCentral.simulateDisconnect(pid, error: nil)

        let error = await task.value
        #expect(error as? BLESwiftError == .unexpectedDisconnect)

        // Let the reconnect complete, then wait for a settle window in which a restored event (a
        // bug) would have time to appear.
        await waitForConnectionState(central, pid, connected: true)
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()
        let collected = await collector.value
        let restoredEvents = collected.filter {
            if case .notificationsRestored = $0 { return true }
            return false
        }
        #expect(restoredEvents.isEmpty)
    }

    @Test("Three surviving subscribers on one characteristic — the reconnect re-arms with exactly one further enable call")
    func refcountedRearmEnablesOnce() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(backoff: .milliseconds(150))
        )
        let pid = fakePeripheral.peripheralIdentifier
        let events = await central.connectionEvents()
        let restoredTask = Task { await firstRestored(events) }

        let streams: [AsyncThrowingStream<Data, Error>] = (0..<3).map { _ in
            peripheral.notifications(for: Self.heartRateMeasurement, survivesReconnect: true)
        }
        let consumers = streams.map { stream in
            Task { for try await _ in stream {} }
        }
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement, on: pid) == 3 }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1)

        fakeCentral.simulateDisconnect(pid, error: nil)
        await waitFor { await central.dormantNotificationWaiterCount(for: Self.heartRateMeasurement, on: pid) == 3 }
        _ = await restoredTask.value

        // Exactly TWO enables: the initial subscribe and the single re-arm. Three survivors share
        // one CCCD write.
        let enableCalls = await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.filter(\.enabled).count }
        #expect(enableCalls == 2)
        #expect(await central.notificationSubscriberCount(for: Self.heartRateMeasurement, on: pid) == 3)

        for consumer in consumers { consumer.cancel() }
        for consumer in consumers { _ = try? await consumer.value }
    }

    @Test("Reconnect policy exhausted — the surviving stream finishes with .unexpectedDisconnect")
    func exhaustedPolicyFinishesSurvivors() async throws {
        let (_, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(maxAttempts: 1, backoff: .milliseconds(10))
        )
        let pid = fakePeripheral.peripheralIdentifier

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(
            for: Self.heartRateMeasurement, survivesReconnect: true
        )
        let task = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        await fakeCentral.onQueue {
            fakeCentral.connectBehavior = .fail(NSError(domain: "test", code: 1))
        }
        fakeCentral.simulateDisconnect(pid, error: nil)

        let error = await task.value
        #expect(error as? BLESwiftError == .unexpectedDisconnect)
    }

    @Test("Characteristic missing after reconnect — only that stream fails; the sibling keeps delivering, and the event partitions them")
    func gattChangeFailsOnlyMissingCharacteristic() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(backoff: .milliseconds(150))
        )
        let pid = fakePeripheral.peripheralIdentifier
        let events = await central.connectionEvents()
        let restoredTask = Task { await firstRestored(events) }

        let streamA: AsyncThrowingStream<Data, Error> = peripheral.notifications(
            for: Self.heartRateMeasurement, survivesReconnect: true
        )
        var iteratorA = streamA.makeAsyncIterator()
        let streamB: AsyncThrowingStream<Data, Error> = peripheral.notifications(
            for: Self.bodySensorLocation, survivesReconnect: true
        )
        let taskB = Task { () -> Error? in
            do {
                for try await _ in streamB {}
                return nil
            } catch {
                return error
            }
        }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.bodySensorLocation) } }

        // The peripheral's GATT table changes across the gap. B is gone. The cached discovery state
        // drops, as on a real disconnect.
        await fakePeripheral.onQueue {
            fakePeripheral.availableServices = [Self.heartRateService: [Self.heartRateMeasurement]]
            fakePeripheral.simulateGATTCacheReset()
        }
        fakeCentral.simulateDisconnect(pid, error: nil)
        await waitFor { await central.dormantNotificationWaiterCount(for: Self.heartRateMeasurement, on: pid) == 1 }
        await waitFor { await central.dormantNotificationWaiterCount(for: Self.bodySensorLocation, on: pid) == 1 }

        let outcome = await restoredTask.value
        #expect(outcome?.restored == [Self.heartRateMeasurement])
        #expect(outcome?.failed.count == 1)
        #expect(outcome?.failed[Self.bodySensorLocation] as? BLESwiftError == .missingCharacteristic(Self.bodySensorLocation))

        let errorB = await taskB.value
        #expect(errorB as? BLESwiftError == .missingCharacteristic(Self.bodySensorLocation))

        // A's stream is not affected by B's failure.
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([9]))
        #expect(try await iteratorA.next() == Data([9]))
    }

    @Test("Explicit disconnect during the backoff gap — the surviving stream finishes with .explicitDisconnect")
    func explicitDisconnectDuringGapFinishesSurvivors() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(backoff: .milliseconds(200))
        )
        let pid = fakePeripheral.peripheralIdentifier

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(
            for: Self.heartRateMeasurement, survivesReconnect: true
        )
        let task = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakeCentral.simulateDisconnect(pid, error: nil)
        await waitForConnectionState(central, pid, connected: false)
        // Wait for the surviving pump to park before the gap ends, so that the explicit disconnect
        // deterministically resolves the parked waiter with `.explicitDisconnect`.
        await waitFor { await central.dormantNotificationWaiterCount(for: Self.heartRateMeasurement, on: pid) == 1 }
        try await central.disconnect(pid)

        let error = await task.value
        #expect(error as? BLESwiftError == .explicitDisconnect)
    }

    @Test("Consumer breaks during the gap — nothing is re-armed on reconnect and no .notificationsRestored is emitted")
    func consumerGoneDuringGapSkipsRearm() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(backoff: .milliseconds(300))
        )
        let pid = fakePeripheral.peripheralIdentifier
        let events = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            var collected: [ConnectionEvent] = []
            for await event in events {
                collected.append(event)
            }
            return collected
        }

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(
            for: Self.heartRateMeasurement, survivesReconnect: true
        )
        let consumer = Task { for try await _ in stream {} }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakeCentral.simulateDisconnect(pid, error: nil)
        await waitForConnectionState(central, pid, connected: false)

        // The only surviving consumer leaves in the middle of the gap. Flush the queue so that its
        // stream's termination bookkeeping completes before the reconnect fires.
        consumer.cancel()
        _ = try? await consumer.value
        await fakeCentral.onQueue {}

        await waitForConnectionState(central, pid, connected: true)
        try await Task.sleep(for: .milliseconds(100))

        // No re-arm: the initial enable stays the only setNotifyValue call, and no restored event
        // fired.
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.filter(\.enabled).count } == 1)
        collector.cancel()
        let collected = await collector.value
        let restoredEvents = collected.filter {
            if case .notificationsRestored = $0 { return true }
            return false
        }
        #expect(restoredEvents.isEmpty)
    }

    @Test("A subscriber racing in after .connected is merged, not clobbered — both streams deliver, with exactly one post-reconnect enable")
    func rearmMergesWithConcurrentSubscriber() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(backoff: .milliseconds(150))
        )
        let pid = fakePeripheral.peripheralIdentifier
        let events = await central.connectionEvents()
        let restoredTask = Task { await firstRestored(events) }

        // Two survivors. A holds the re-arm loop (sorted first, with its re-discovery withheld). B
        // is the merge target.
        let survivorA: AsyncThrowingStream<Data, Error> = peripheral.notifications(
            for: Self.heartRateMeasurement, survivesReconnect: true
        )
        let consumerA = Task { for try await _ in survivorA {} }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }
        let survivorB: AsyncThrowingStream<Data, Error> = peripheral.notifications(
            for: Self.bodySensorLocation, survivesReconnect: true
        )
        var iteratorB = survivorB.makeAsyncIterator()
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.bodySensorLocation) } }

        // The re-arm must discover again. Withhold A's service discovery so that the loop parks on
        // A before it can register anything for B.
        await fakePeripheral.onQueue {
            fakePeripheral.simulateGATTCacheReset()
            fakePeripheral.holdServiceDiscoveryCompletions = true
        }
        let discoveryCallsBeforeGap = await fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount }

        fakeCentral.simulateDisconnect(pid, error: nil)
        await waitFor { await central.dormantNotificationWaiterCount(for: Self.heartRateMeasurement, on: pid) == 1 }
        await waitFor { await central.dormantNotificationWaiterCount(for: Self.bodySensorLocation, on: pid) == 1 }

        // The reconnect fires. The re-arm loop issues A's held service discovery and parks.
        await waitForConnectionState(central, pid, connected: true)
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == discoveryCallsBeforeGap + 1 }

        // The app reacts to `.connected` with a new DEFAULT subscriber on B. It registers its own
        // subscription and issues B's one enable after the reconnect, before the re-arm loop can
        // reach B.
        let defaultB: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.bodySensorLocation)
        let defaultTask = Task { try await collectData(defaultB, count: 1) }
        await waitFor { await central.notificationSubscriberCount(for: Self.bodySensorLocation, on: pid) == 1 }

        // Release A's discovery. The re-arm finishes A, then MERGES B's survivor into the default
        // subscriber's live subscription.
        await fakePeripheral.onQueue { fakePeripheral.holdServiceDiscoveryCompletions = false }
        fakePeripheral.simulateNextHeldServiceDiscoveryCompletion()

        let outcome = await restoredTask.value
        #expect(outcome?.restored == [Self.heartRateMeasurement, Self.bodySensorLocation])
        #expect(outcome?.failed.isEmpty == true)

        // Both B streams deliver the same next value: the merged survivor and the racing default
        // subscriber.
        fakePeripheral.simulateNotification(for: Self.bodySensorLocation, value: Data([5]))
        #expect(try await iteratorB.next() == Data([5]))
        #expect(try await defaultTask.value == [Data([5])])

        // Exactly ONE enable for B after the reconnect, from the default subscriber. The merge
        // issued none. B has two enables in total, including the initial subscribe.
        let enableCallsForB = await fakePeripheral.onQueue {
            fakePeripheral.setNotifyValueCalls.filter { $0.enabled && $0.characteristic == Self.bodySensorLocation }.count
        }
        #expect(enableCallsForB == 2)

        consumerA.cancel()
        _ = try? await consumerA.value
    }

    @Test("Composite helpers never survive — writeAndAwaitNotification in flight still throws at an unexpected disconnect despite a reconnect policy")
    func compositeHelpersFailAtDisconnect() async throws {
        let (_, fakeCentral, fakePeripheral, peripheral) = try await makeReconnectingRig(
            reconnect: .always(backoff: .milliseconds(10))
        )
        let pid = fakePeripheral.peripheralIdentifier

        let task = Task { () -> Error? in
            do {
                let _: Data = try await peripheral.writeAndAwaitNotification(
                    write: Data([1]),
                    to: Self.bodySensorLocation,
                    awaitOn: Self.heartRateMeasurement
                )
                return nil
            } catch {
                return error
            }
        }
        // The composite subscribes, then writes. When notify is on and the write has landed, the
        // composite is parked waiting for a response that the device never sends.
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.bodySensorLocation] ?? 0 } == 1 }

        fakeCentral.simulateDisconnect(pid, error: nil)

        let error = await task.value
        #expect(error as? BLESwiftError == .unexpectedDisconnect)
    }
}
