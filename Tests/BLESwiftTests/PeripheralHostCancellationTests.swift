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

/// Creates a `PeripheralHost` wired to a fresh queue-confined `FakePeripheralManager`.
/// Mirrors `PeripheralHostTests.swift`'s factory of the same shape — redeclared here since
/// this is a separate file.
private func makeFakePeripheralHost(
    label: String = "BLESwiftTests.FakePeripheralManager.Cancellation"
) -> (PeripheralHost, FakePeripheralManager, DispatchSerialQueue) {
    let queue = DispatchSerialQueue(label: label)
    let fake = FakePeripheralManager(queue: queue)
    let host = PeripheralHost(backend: fake, queue: queue)
    return (host, fake, queue)
}

private let heartRate = ServiceIdentifier(uuid: "180D")
private let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

private func aCentral(maxLength: Int = 20) -> Subscriber {
    Subscriber(id: UUID(), maximumUpdateValueLength: maxLength)
}

/// Exercises `PeripheralHost` paths not covered by `PeripheralHostTests.swift`:
/// `stopAndExtractState()`'s throw for a test-backed host, `authorization`'s fake-backed
/// branch, task-cancellation through `add(_:)`/`startAdvertising(_:)`/
/// `updateValue(_:for:onSubscribed:)`, the "already in progress" `startAdvertising` guard,
/// and the write-request rejection branch of `respond(to:with:)`.
@Suite("PeripheralHost cancellation & lifecycle edges")
struct PeripheralHostCancellationTests {

    // MARK: - stopAndExtractState()

    @Test("stopAndExtractState() throws .stopped for a test-backed host (no real CBPeripheralManager), and a second call still throws")
    func stopAndExtractStateThrowsForTestBackedHost() async throws {
        let (host, _, _) = makeFakePeripheralHost()

        // `FakePeripheralManager` is never a `CBPeripheralManager`, so `stopAndExtractState()`
        // fails its `as? CBPeripheralManager` guard *before* it reaches
        // `failPendingOperations`/the broadcasters' `.finish()` calls — those are therefore
        // unreachable through this fake (see the accompanying report: this is not something
        // the current test surface can drive, not a flakiness dodge).
        do {
            _ = try await host.stopAndExtractState()
            Issue.record("expected stopAndExtractState() to throw .stopped")
        } catch let error as BLESwiftError {
            #expect(error == .stopped)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        // `manager` was never nilled out above (the throw happens before that assignment),
        // so a second call takes exactly the same path and throws again.
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

        // Note: the `.notDetermined` branch (`guard let manager else { return .notDetermined }`)
        // only fires once `manager` has been nilled out, which — per
        // `stopAndExtractStateThrowsForTestBackedHost` above — never happens for a
        // fake-backed host through the public API. `manager` is also `private`, so it isn't
        // reachable to set directly without `@testable` + breaking the "no internal access
        // needed" boundary for a one-line branch. Left untested here; see the report.
    }

    // MARK: - add(_:) cancellation

    @Test("Cancelling add(_:)'s Task before FakePeripheralManager can auto-resolve it throws .operationCancelled")
    func addServiceTaskCancellation() async throws {
        let (host, fake, queue) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {} // flush the state-change delivery

        // `FakePeripheralManager.add(_:)` always schedules its own `didAddService` completion
        // near-instantly (there's no "hang" script like `FakeCentral.connectBehavior`), so
        // cancelling *after* `add(_:)` starts running would race its auto-completion. Instead,
        // freeze `queue` before starting the Task and cancel it while still frozen: by the
        // time the actor's job actually runs, the Task is already cancelled, so
        // `withTaskCancellationHandler` is documented to invoke `onCancel` immediately —
        // before `register` (and so before `manager.add(_:)` schedules the fake's
        // `didAddService`) ever runs. That makes `cancelPendingAddService` win deterministically.
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
        await fake.onQueue {} // flush the state-change delivery

        // Same freeze-then-cancel shape as `addServiceTaskCancellation` — see that test's
        // comment for why this is the deterministic construction given the fake has no
        // "hang" for `startAdvertising(_:)` either.
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
        await fake.onQueue {} // flush the state-change delivery

        // Freeze `queue` so neither call's actor job can run until both have been submitted —
        // guaranteeing that whichever one the queue happens to run first registers
        // `pendingStartAdvertising` and schedules its own (near-instant) completion, and the
        // other runs immediately after, while that completion is still pending, seeing
        // `pendingStartAdvertising != nil` and hitting the "already in progress" guard.
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }

        // Two `Task.yield()`s give each call's actor job a real chance to be *submitted* to
        // `queue` (not executed — execution stays frozen behind `gate`) before the next line
        // runs, matching the "give it a chance to register" idiom already used elsewhere in
        // this test target (e.g. `CentralTests.twoSubscribersObserveSameTransition`). Which of
        // the two ends up submitted first isn't guaranteed, though, so the assertions below
        // don't assume an order: exactly one call must succeed and the other must throw
        // `.invalidArgument`, whichever task that turns out to be.
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
        // Script exactly one full-queue return, so updateValue falls into
        // `awaitReadyToUpdate()` and suspends — nothing auto-resolves that wait (unlike
        // `add`/`startAdvertising`, `FakePeripheralManager` never fires
        // `.readyToUpdateSubscribers` on its own), so this is a genuine, deterministic
        // "still pending" window, exactly like `updateValueBackPressure`/
        // `updateValueFailsOnPowerOff` in `PeripheralHostTests.swift`.
        await fake.onQueue { fake.scriptedUpdateValueReturns = [false] }

        let central = aCentral()
        fake.simulateSubscribe(central: central, to: measurement)
        await fake.onQueue {} // flush subscribe

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
