//
//  NotificationTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
@testable import BLESwift

/// Exercises `Peripheral.notifications(for:policy:)` — Phase 7's multicast notification
/// streams: fan-out to concurrent subscribers, the refcounted `setNotifyValue` lifecycle,
/// per-subscriber decode isolation, disconnect teardown, and `didUpdateValue` routing
/// precedence — all driven through `makeConnectedTestCentral()`'s fakes.
@Suite("Notification streams")
struct NotificationTests {

    // MARK: - Fixtures

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)

    // MARK: - Multicast fan-out

    @Test("Two concurrent subscribers each receive every notified value, in order")
    func twoSubscribersEachReceiveEveryValue() async throws {
        let (central, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let streamA: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let streamB: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)

        let taskA = Task { try await collectData(streamA, count: 3) }
        let taskB = Task { try await collectData(streamB, count: 3) }

        // Both subscribers registered (registration is asynchronous) and notify enabled,
        // before emitting anything both are expected to observe.
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement) == 2 }
        await waitFor { fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([1]))
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([2]))
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([3]))

        let receivedA = try await taskA.value
        let receivedB = try await taskB.value
        #expect(receivedA == [Data([1]), Data([2]), Data([3])])
        #expect(receivedB == [Data([1]), Data([2]), Data([3])])
    }

    // MARK: - Refcounted setNotifyValue lifecycle

    @Test("setNotifyValue lifecycle is refcounted: enabled once by the first subscriber, disabled only when the last cancels")
    func refcountLifecycle() async throws {
        let (central, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let streamA: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let taskA = Task { for try await _ in streamA {} }

        // First subscriber: exactly one setNotifyValue call, an enable.
        await waitFor { fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1 }
        #expect(fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.first?.enabled } == true)
        #expect(fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.first?.characteristic } == Self.heartRateMeasurement)

        let streamB: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let taskB = Task { for try await _ in streamB {} }

        // Second subscriber fully registered (registration is asynchronous): still no
        // further setNotifyValue call.
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement) == 2 }
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([1]))
        fakePeripheral.onQueue {} // flush the delivery
        #expect(fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1)

        // First subscriber cancels: still no disable — a subscriber remains.
        taskA.cancel()
        _ = try? await taskA.value
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement) == 1 }
        #expect(fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1)

        // Last subscriber cancels: exactly one disable.
        taskB.cancel()
        _ = try? await taskB.value
        await waitFor { fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 2 }
        #expect(fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.last?.enabled } == false)
        #expect(fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.isEmpty } == true)
    }

    // MARK: - Per-subscriber decode isolation

    @Test("A decode failure finishes only the failing subscriber's stream; a sibling keeps receiving")
    func decodeFailureKillsOnlyFailingSubscriber() async throws {
        let (central, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let stringStream: AsyncThrowingStream<String, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let dataStream: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)

        let stringTask = Task { () -> Error? in
            do {
                for try await _ in stringStream {}
                return nil
            } catch {
                return error
            }
        }
        let dataTask = Task { try await collectData(dataStream, count: 2) }

        // Both subscribers registered (registration is asynchronous) before emitting.
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement) == 2 }
        await waitFor { fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        // 0xFF is not valid standalone UTF-8: fails the String subscriber's decode layer,
        // passes the Data subscriber's identity decode untouched.
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([0xFF]))
        // "A" — proves the sibling keeps receiving after the String subscriber died.
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([0x41]))

        let stringError = await stringTask.value
        #expect(stringError as? BLESwiftError == .invalidStringEncoding)

        let dataValues = try await dataTask.value
        #expect(dataValues == [Data([0xFF]), Data([0x41])])

        // The failing subscriber's release must not have disabled notifications — the
        // sibling still holds a refcount.
        #expect(fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1)
    }

    // MARK: - Disconnect teardown

    @Test("An unexpected disconnect finishes every notification stream by throwing .unexpectedDisconnect")
    func streamsFinishWithErrorOnDisconnect() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let task = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }

        await waitFor { fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let error = await task.value
        #expect(error as? BLESwiftError == .unexpectedDisconnect)

        guard case .disconnected = await central.connectionState else {
            Issue.record("expected .disconnected")
            return
        }
    }

    // MARK: - didUpdateValue routing precedence

    @Test("An active notification subscription takes precedence over a pending read on the same characteristic")
    func notificationRoutingTakesPrecedenceOverPendingRead() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        fakePeripheral.onQueue {
            fakePeripheral.holdReadCompletions = true
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([9])
        }

        // A read is pending first (its completion held), so both a pending-read
        // continuation AND (below) an active subscription exist for the characteristic.
        let readTask = Task<UInt8, Error> {
            try await peripheral.read(from: Self.heartRateMeasurement)
        }
        await waitFor { fakePeripheral.onQueue { fakePeripheral.readCallCount } == 1 }

        // The stream is created (and so referenced) entirely inside the subscriber task:
        // when `collectData` returns, the last reference to it drops, its `onTermination`
        // fires, and the subscription's refcount is released — which the end of this test
        // depends on. (Holding it in a test-scoped `let` would keep the subscription
        // alive until the test returns, and the held read below could never resolve.)
        let subscriberTask = Task {
            try await collectData(peripheral.notifications(for: Self.heartRateMeasurement), count: 1)
        }
        await waitFor { fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        // Routed to the subscription FIRST (the ported fallback-chain order) — were the
        // pending read resolved instead, `readTask` would return 7, not 9, below.
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([7]))
        let received = try await subscriberTask.value
        #expect(received == [Data([7])])

        // Once the subscriber is gone (its `break` above released the last refcount and
        // disabled notify), the held read completion falls through to the pending read.
        await waitFor { fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 2 }
        fakePeripheral.simulateNextHeldReadCompletion()
        let readValue = try await readTask.value
        #expect(readValue == 9)
    }
}

/// Collects exactly `count` `Data` values from `stream`, then returns (unsubscribing).
func collectData(_ stream: AsyncThrowingStream<Data, Error>, count: Int) async throws -> [Data] {
    var results: [Data] = []
    var iterator = stream.makeAsyncIterator()
    while results.count < count, let value = try await iterator.next() {
        results.append(value)
    }
    return results
}
