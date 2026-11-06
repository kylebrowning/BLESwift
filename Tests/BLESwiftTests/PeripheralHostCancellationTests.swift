//
//  PeripheralHostCancellationTests.swift
//  BLESwiftTests
//

@preconcurrency import CoreBluetooth
import Dispatch
import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Creates a `PeripheralHost` wired to a new `FakePeripheralManager` confined to a queue. It has
/// the same shape as the factory in `PeripheralHostTests.swift`, which is private to that file.
private func makeFakePeripheralHost(
    label: String = "BLESwiftTests.FakePeripheralManager.Cancellation"
) -> (PeripheralHost, FakePeripheralManager, DispatchQueue) {
    let queue = DispatchQueue(label: label)
    let fake = FakePeripheralManager(queue: queue)
    let host = PeripheralHost(backend: fake, queue: queue)
    return (host, fake, queue)
}

private let heartRate = ServiceIdentifier(uuid: "180D")
private let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

private func aCentral(maxLength: Int = 20) -> Subscriber {
    Subscriber(id: UUID(), maximumUpdateValueLength: maxLength)
}

/// Tests paths of `PeripheralHost` that `PeripheralHostTests.swift` does not cover:
/// - the throw of `stopAndExtractState()` for a host that a fake backs
/// - the branch of `authorization` that a fake backs
/// - task cancellation through `add(_:)`, `startAdvertising(_:)`, and
///   `updateValue(_:for:onSubscribed:)`
/// - the "already in progress" guard of `startAdvertising`
/// - the branch of `respond(to:with:)` that rejects a write request
@Suite("PeripheralHost cancellation & lifecycle edges")
struct PeripheralHostCancellationTests {

    // MARK: - stopAndExtractState()

    @Test("stopAndExtractState() throws .stopped for a test-backed host (no real CBPeripheralManager), and a second call still throws")
    func stopAndExtractStateThrowsForTestBackedHost() async throws {
        let (host, _, _) = makeFakePeripheralHost()

        // `FakePeripheralManager` is never a `CBPeripheralManager`, so `stopAndExtractState()`
        // fails its `as? CBPeripheralManager` guard before it reaches `failPendingOperations` and
        // the broadcasters' `.finish()` calls. The current test surface cannot drive those calls.
        do {
            _ = try await host.stopAndExtractState()
            Issue.record("expected stopAndExtractState() to throw .stopped")
        } catch let error as BLESwiftError {
            #expect(error == .stopped)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        // The throw happens before the code sets `manager` to nil, so a second call takes the same
        // path and throws again.
        do {
            _ = try await host.stopAndExtractState()
            Issue.record("expected a second stopAndExtractState() call to throw .stopped")
        } catch let error as BLESwiftError {
            #expect(error == .stopped)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - authorization

    @Test("authorization reflects the fake backend's static bluetoothAuthorization")
    func authorizationReflectsFake() async {
        let original = FakePeripheralManager.bluetoothAuthorization
        defer { FakePeripheralManager.bluetoothAuthorization = original }

        FakePeripheralManager.bluetoothAuthorization = .allowedAlways
        let (host, _, _) = makeFakePeripheralHost()
        #expect(await host.authorization == .allowedAlways)

        FakePeripheralManager.bluetoothAuthorization = .denied
        #expect(await host.authorization == .denied)

        // The `.notDetermined` branch (`guard let manager else { return .notDetermined }`) fires
        // only after the code sets `manager` to nil. As
        // `stopAndExtractStateThrowsForTestBackedHost` shows, this never happens for a fake-backed
        // host through the public API. `manager` is `private`, and setting it needs `@testable`,
        // which would break the "no internal access needed" boundary. This file leaves the one-line
        // branch untested.
    }

    // MARK: - add(_:) cancellation

    @Test("Cancelling add(_:)'s Task before FakePeripheralManager can auto-resolve it throws .operationCancelled")
    func addServiceTaskCancellation() async throws {
        let (host, fake, queue) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {} // Flush the state-change delivery.

        // `FakePeripheralManager.add(_:)` always schedules its `didAddService` completion almost at
        // once, and there is no "hang" script like `FakeCentral.connectBehavior`. A cancel after
        // `add(_:)` starts would race that completion. Instead, freeze `queue` before the test
        // starts the Task, and cancel the Task while the queue is frozen. When the actor job then
        // runs, the Task is already cancelled, so `withTaskCancellationHandler` invokes `onCancel`
        // immediately, as documented. This happens before `register` runs and before
        // `manager.add(_:)` schedules the fake's `didAddService`. So `cancelPendingAddService`
        // deterministically wins.
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }

        let addTask = Task { try await host.add(GATTService(identifier: heartRate)) }
        addTask.cancel()
        gate.signal()

        await #expect(throws: BLESwiftError.operationCancelled) {
            try await addTask.value
        }
    }

    // MARK: - startAdvertising(_:) cancellation

    @Test("Cancelling startAdvertising(_:)'s Task before FakePeripheralManager can auto-resolve it throws .operationCancelled")
    func startAdvertisingTaskCancellation() async throws {
        let (host, fake, queue) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {} // Flush the state-change delivery.

        // Same freeze-then-cancel shape as `addServiceTaskCancellation`, which explains why it is
        // deterministic. The fake also has no "hang" for `startAdvertising(_:)`.
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }

        let advertiseTask = Task { try await host.startAdvertising(PeripheralAdvertisement(localName: "Rig")) }
        advertiseTask.cancel()
        gate.signal()

        await #expect(throws: BLESwiftError.operationCancelled) {
            try await advertiseTask.value
        }
        #expect(!host.isAdvertising)
    }

    // MARK: - startAdvertising(_:) "already in progress" guard

    @Test("A second concurrent startAdvertising(_:) while one is already pending throws .invalidArgument")
    func startAdvertisingAlreadyInProgress() async throws {
        let (host, fake, queue) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {} // Flush the state-change delivery.

        // Freeze `queue` so that neither call's actor job can run until the test has submitted
        // both. The queue runs one first. That call registers `pendingStartAdvertising` and
        // schedules its almost instant completion. The other call runs right after, while that
        // completion is pending, sees `pendingStartAdvertising != nil`, and hits the "already in
        // progress" guard.
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }

        // Two `Task.yield()` calls give each call's actor job a chance to be *submitted* to
        // `queue`. The job does not run because `gate` keeps the queue frozen. Other tests in this
        // target use the same idiom (for example
        // `CentralTests.twoSubscribersObserveSameTransition`). The queue's order of the two calls
        // is not guaranteed, so the assertions do not assume one. Exactly one call must succeed and
        // the other must throw `.invalidArgument`.
        let taskA = Task { try await host.startAdvertising(PeripheralAdvertisement(localName: "A")) }
        await Task.yield()
        await Task.yield()

        let taskB = Task { try await host.startAdvertising(PeripheralAdvertisement(localName: "B")) }
        await Task.yield()
        await Task.yield()

        gate.signal()

        let resultA = await taskA.result
        let resultB = await taskB.result

        let results = [resultA, resultB]
        let successes = results.filter { if case .success = $0 { return true } else { return false } }
        let rejections = results.filter {
            if case .failure(let error as BLESwiftError) = $0 {
                return error == .invalidArgument("startAdvertising is already in progress")
            }
            return false
        }

        #expect(successes.count == 1, "expected exactly one startAdvertising(_:) to succeed, got \(results)")
        #expect(rejections.count == 1, "expected exactly one startAdvertising(_:) to throw .invalidArgument, got \(results)")
        #expect(host.isAdvertising)
    }

    // MARK: - updateValue(_:for:onSubscribed:) cancellation (cancelReadyWaiter)

    @Test("Cancelling updateValue's Task while awaiting transmit capacity throws .operationCancelled")
    func updateValueTaskCancellationWhileAwaitingCapacity() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        // Script exactly one full-queue return. Then updateValue goes into `awaitReadyToUpdate()`
        // and suspends. Unlike `add` and `startAdvertising`, `FakePeripheralManager` never fires
        // `.readyToUpdateSubscribers` by itself, so this is a deterministic "still pending" window,
        // as in `updateValueBackPressure` and `updateValueFailsOnPowerOff` in
        // `PeripheralHostTests.swift`.
        await fake.onQueue { fake.scriptedUpdateValueReturns = [false] }

        let central = aCentral()
        fake.simulateSubscribe(central: central, to: measurement)
        await fake.onQueue {} // Flush the subscribe.

        let updateTask = Task { try await host.updateValue(Data([0xAA]), for: measurement) }

        await waitFor { await fake.onQueue { fake.updateValueCalls.count } >= 1 }
        #expect(await fake.onQueue { fake.updateValueCalls.first?.returned } == false)

        updateTask.cancel()

        await #expect(throws: BLESwiftError.operationCancelled) {
            try await updateTask.value
        }
    }

    // MARK: - respond(to: WriteRequest, with:) rejection branch

    @Test("A write-request batch can be rejected with an ATT error")
    func writeRequestRejected() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)

        var iterator = await host.writeRequests().makeAsyncIterator()
        fake.simulateWriteRequest(central: aCentral(), characteristic: measurement, value: Data([0xAB]))
        let request = try #require(await iterator.next())

        await host.respond(to: request, with: .failure(.writeNotPermitted))

        let responses = await fake.onQueue { fake.respondCalls }
        #expect(responses.count == 1)
        #expect(responses.first?.token == request.token)
        #expect(responses.first?.error == .writeNotPermitted)
        #expect(responses.first?.value == nil)
    }
}
