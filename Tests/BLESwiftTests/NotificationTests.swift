//
//  NotificationTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
@testable import BLESwift

/// Tests `Peripheral.notifications(for:policy:)`, the multicast notification streams. The tests
/// cover:
/// - fan-out to concurrent subscribers
/// - the `setNotifyValue` lifecycle with reference counts
/// - decode isolation for each subscriber
/// - teardown at disconnect
/// - the precedence in the routing of `didUpdateValue`
///
/// The tests use the fakes of `makeConnectedTestCentral()`.
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

        // Both subscribers are registered (registration is asynchronous) and notify is enabled
        // before the test emits.
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement, on: fakePeripheral.peripheralIdentifier) == 2 }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

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
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1 }
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.first?.enabled } == true)
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.first?.characteristic } == Self.heartRateMeasurement)

        let streamB: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.heartRateMeasurement)
        let taskB = Task { for try await _ in streamB {} }

        // The second subscriber is registered (registration is asynchronous). There is still no
        // further setNotifyValue call.
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement, on: fakePeripheral.peripheralIdentifier) == 2 }
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([1]))
        await fakePeripheral.onQueue {} // Flush the delivery.
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1)

        // The first subscriber cancels. There is no disable because a subscriber remains.
        taskA.cancel()
        _ = try? await taskA.value
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement, on: fakePeripheral.peripheralIdentifier) == 1 }
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1)

        // The last subscriber cancels. There is exactly one disable.
        taskB.cancel()
        _ = try? await taskB.value
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 2 }
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.last?.enabled } == false)
        #expect(await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.isEmpty } == true)
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

        // Both subscribers are registered (registration is asynchronous) before the test emits.
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement, on: fakePeripheral.peripheralIdentifier) == 2 }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        // 0xFF is not valid standalone UTF-8. It fails the String subscriber's decode and passes
        // the Data subscriber's identity decode unchanged.
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([0xFF]))
        // "A" proves that the sibling keeps receiving after the String subscriber died.
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([0x41]))

        let stringError = await stringTask.value
        #expect(stringError as? BLESwiftError == .invalidStringEncoding)

        let dataValues = try await dataTask.value
        #expect(dataValues == [Data([0xFF]), Data([0x41])])

        // Releasing the failing subscriber must not have disabled notifications. The sibling still
        // holds a reference count.
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 1)
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

        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let error = await task.value
        #expect(error as? BLESwiftError == .unexpectedDisconnect)

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected")
            return
        }
    }

    // MARK: - didUpdateValue routing precedence

    @Test("An active notification subscription takes precedence over a pending read on the same characteristic")
    func notificationRoutingTakesPrecedenceOverPendingRead() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue {
            fakePeripheral.holdReadCompletions = true
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = Data([9])
        }

        // A read is pending first, with its completion held, so a pending-read continuation AND
        // (below) an active subscription exist for the characteristic.
        let readTask = Task<UInt8, Error> {
            try await peripheral.read(from: Self.heartRateMeasurement)
        }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.readCallCount } == 1 }

        // The stream is created and referenced entirely inside the subscriber task. When
        // `collectData` returns, the last reference drops and `onTermination` fires, releasing the
        // subscription's reference count. The end of this test depends on this. A test-scoped `let`
        // would keep the subscription alive until the test returns, and the held read below could
        // never resolve.
        let subscriberTask = Task {
            try await collectData(peripheral.notifications(for: Self.heartRateMeasurement), count: 1)
        }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        // The code routes it to the subscription FIRST, as in the ported fallback chain. If the
        // code had resolved the pending read, `readTask` would return 7 and not 9, below.
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([7]))
        let received = try await subscriberTask.value
        #expect(received == [Data([7])])

        // The subscriber is gone. Its `break` released the last reference count and disabled
        // notify, so the held read completion falls through to the pending read.
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 2 }
        fakePeripheral.simulateNextHeldReadCompletion()
        let readValue = try await readTask.value
        #expect(readValue == 9)
    }
}

/// Collects exactly `count` `Data` values from `stream`, then returns and unsubscribes.
func collectData(_ stream: AsyncThrowingStream<Data, Error>, count: Int) async throws -> [Data] {
    var results: [Data] = []
    var iterator = stream.makeAsyncIterator()
    while results.count < count, let value = try await iterator.next() {
        results.append(value)
    }
    return results
}

/// Tests notification isolation for multiple peripherals:
/// - Two peripherals connect at the same time and subscribe to the identical
///   `CharacteristicIdentifier`. This proves that the key is per session, not global per
///   characteristic.
/// - The reference-count lifecycles are independent.
/// - The teardown at disconnect affects only the peripheral that disconnects.
@Suite("Multi-peripheral notification isolation")
struct MultiPeripheralNotificationTests {

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)

    @Test("Notifications on the SAME characteristic identifier, subscribed on both A and B: values simulated from A reach only A's subscribers")
    func notificationsOnSameCharacteristicAreIsolatedPerPeripheral() async throws {
        let (_, _, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB) = try await connectedPair()

        let streamA: AsyncThrowingStream<Data, Error> = peripheralA.notifications(for: Self.heartRateMeasurement)
        let streamB: AsyncThrowingStream<Data, Error> = peripheralB.notifications(for: Self.heartRateMeasurement)

        let taskA = Task { try await collectData(streamA, count: 2) }
        let taskB = Task<[Data], Never> {
            var collected: [Data] = []
            do {
                for try await value in streamB {
                    collected.append(value)
                    if collected.count == 1 { break }
                }
            } catch {}
            return collected
        }

        await waitFor { await fakePeripheralA.onQueue { fakePeripheralA.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }
        await waitFor { await fakePeripheralB.onQueue { fakePeripheralB.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        // Two values come from A only and one from B only. The identical characteristic UUID on
        // each peripheral must not cross-deliver.
        fakePeripheralA.simulateNotification(for: Self.heartRateMeasurement, value: Data([1]))
        fakePeripheralB.simulateNotification(for: Self.heartRateMeasurement, value: Data([100]))
        fakePeripheralA.simulateNotification(for: Self.heartRateMeasurement, value: Data([2]))

        let receivedA = try await taskA.value
        let receivedB = await taskB.value
        #expect(receivedA == [Data([1]), Data([2])])
        #expect(receivedB == [Data([100])])
    }

    @Test("Refcounted setNotifyValue lifecycles are independent per peripheral: enabling/disabling on A doesn't touch B's fake")
    func refcountLifecyclesAreIndependentPerPeripheral() async throws {
        let (central, _, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB) = try await connectedPair()

        let streamA: AsyncThrowingStream<Data, Error> = peripheralA.notifications(for: Self.heartRateMeasurement)
        let taskA = Task { for try await _ in streamA {} }
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement, on: fakePeripheralA.peripheralIdentifier) == 1 }
        // The reference count reaching one and the fake's call are two different observables. On a
        // loaded machine the second can arrive after the first, so the test waits for it.
        await waitFor { await fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.count } == 1 }
        #expect(await fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.count } == 1)
        // B's fake must not be affected by A's subscription.
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.setNotifyValueCalls.count } == 0)

        let streamB: AsyncThrowingStream<Data, Error> = peripheralB.notifications(for: Self.heartRateMeasurement)
        let taskB = Task { for try await _ in streamB {} }
        await waitFor { await central.notificationSubscriberCount(for: Self.heartRateMeasurement, on: fakePeripheralB.peripheralIdentifier) == 1 }
        await waitFor { await fakePeripheralB.onQueue { fakePeripheralB.setNotifyValueCalls.count } == 1 }
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.setNotifyValueCalls.count } == 1)
        // A's fake must not be affected by B's subscription starting.
        #expect(await fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.count } == 1)

        taskA.cancel()
        _ = try? await taskA.value
        await waitFor { await fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.count } == 2 }
        #expect(await fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.last?.enabled } == false)
        // B's live subscription must not be affected by A's cancellation.
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.setNotifyValueCalls.count } == 1)

        taskB.cancel()
        _ = try? await taskB.value
        await waitFor { await fakePeripheralB.onQueue { fakePeripheralB.setNotifyValueCalls.count } == 2 }
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.setNotifyValueCalls.last?.enabled } == false)
    }

    @Test("An unexpected disconnect of A finishes A's notification streams with .unexpectedDisconnect while B's streams keep delivering")
    func disconnectOfOneFinishesOnlyThatOnesStreams() async throws {
        let (central, fakeCentral, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB) = try await connectedPair()

        let streamA: AsyncThrowingStream<Data, Error> = peripheralA.notifications(for: Self.heartRateMeasurement)
        let taskA = Task { () -> Error? in
            do {
                for try await _ in streamA {}
                return nil
            } catch {
                return error
            }
        }
        let streamB: AsyncThrowingStream<Data, Error> = peripheralB.notifications(for: Self.heartRateMeasurement)
        let taskB = Task { try await collectData(streamB, count: 1) }

        await waitFor { await fakePeripheralA.onQueue { fakePeripheralA.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }
        await waitFor { await fakePeripheralB.onQueue { fakePeripheralB.notifyingCharacteristics.contains(Self.heartRateMeasurement) } }

        fakeCentral.simulateDisconnect(fakePeripheralA.peripheralIdentifier, error: nil)

        let errorA = await taskA.value
        #expect(errorA as? BLESwiftError == .unexpectedDisconnect)

        guard case .disconnected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A .disconnected")
            return
        }
        guard case .connected = await central.connectionState(of: fakePeripheralB.peripheralIdentifier) else {
            Issue.record("expected B still .connected")
            return
        }

        // B's stream must keep delivering after A's teardown.
        fakePeripheralB.simulateNotification(for: Self.heartRateMeasurement, value: Data([7]))
        let receivedB = try await taskB.value
        #expect(receivedB == [Data([7])])
    }
}

/// Connects two `FakePeripheral` objects to one `Central`. A is the primary fake of
/// `makeTestCentral()`. B comes from `addFakePeripheral(to:fakeCentral:)`. Returns the fake
/// central, the fake peripherals, and the connected `Peripheral` handles.
private func connectedPair() async throws -> (Central, FakeCentral, FakePeripheral, Peripheral, FakePeripheral, Peripheral) {
    let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
    let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
    // Power the radio on first. The ledger guards the `setNotifyValue(false)` at the last release
    // on `.poweredOn` (see `Central.releaseNotificationSubscriber`), as in
    // `makeConnectedTestCentral()`.
    fakeCentral.simulateStateChange(.poweredOn)
    await fakeCentral.onQueue {
        fakeCentral.retrievablePeripherals[fakePeripheralA.identifier] = fakePeripheralA
        fakeCentral.connectBehavior = .succeed
    }
    let peripheralA = try await central.connect(fakePeripheralA.peripheralIdentifier)
    let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)
    return (central, fakeCentral, fakePeripheralA, peripheralA, fakePeripheralB, peripheralB)
}
