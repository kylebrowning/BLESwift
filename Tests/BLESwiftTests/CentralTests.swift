//
//  CentralTests.swift
//  BLESwiftTests
//

@preconcurrency import CoreBluetooth
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Tests the `Central` actor: the state snapshot and the state stream through `makeTestCentral()`.
/// The tests use a `FakeCentral` instead of a real `CBCentralManager`.
@Suite("Central")
struct CentralTests {

    @Test("Central.state starts .unknown, matching a freshly-created CBCentralManager")
    func stateStartsUnknown() async {
        let (central, _, _) = makeTestCentral()
        #expect(central.state == .unknown)
        #expect(central.state == .unknown) // also readable synchronously, without await
    }

    @Test("stateEvents() replays the current value to a late subscriber")
    func stateEventsReplaysCurrentValueToLateSubscriber() async {
        let (central, fakeCentral, _) = makeTestCentral()

        fakeCentral.simulateStateChange(.poweredOn)
        // Flush the fake's async event delivery, then let the actor's `handle(_:)` run to the end
        // before subscribing. `handle(_:)` is scheduled on the same serial queue.
        await fakeCentral.onQueue {}
        #expect(central.state == .poweredOn)

        var iterator = await central.stateEvents().makeAsyncIterator()
        let replayed = await iterator.next()

        #expect(replayed == .poweredOn)
    }

    @Test("Two subscribers both observe a poweredOn -> poweredOff transition, in order")
    func twoSubscribersObserveSameTransition() async {
        let (central, fakeCentral, _) = makeTestCentral()

        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}
        #expect(central.state == .poweredOn)

        let stream1 = await central.stateEvents()
        let stream2 = await central.stateEvents()

        async let collected1 = collectNext(2, from: stream1)
        async let collected2 = collectNext(2, from: stream2)

        // Give both subscribers time to register and drain their `.latest` replay of `.poweredOn`
        // before the test simulates the next transition.
        await Task.yield()
        await Task.yield()

        fakeCentral.simulateStateChange(.poweredOff)
        await fakeCentral.onQueue {} // flush

        let (result1, result2) = await (collected1, collected2)
        #expect(result1 == [.poweredOn, .poweredOff])
        #expect(result2 == [.poweredOn, .poweredOff])
    }

    @Test("makeTestCentral() smoke test: FakeCentral.simulateStateChange is observed via Central.stateEvents()")
    func makeTestCentralSmokeTest() async {
        let (central, fakeCentral, _) = makeTestCentral()

        var iterator = await central.stateEvents().makeAsyncIterator()

        fakeCentral.simulateStateChange(.poweredOn)

        let observed = await iterator.next()
        #expect(observed == .poweredOn)
        #expect(central.state == .poweredOn)
    }

    @Test("Central.isScanning starts false, before any scan has been started")
    func isScanningStartsFalse() {
        let (central, _, _) = makeTestCentral()
        #expect(central.isScanning == false)
    }

    @Test("Central.authorization reflects the shim's static authorization")
    func authorizationReflectsShim() async {
        let original = FakeCentral.bluetoothAuthorization
        defer { FakeCentral.bluetoothAuthorization = original }

        FakeCentral.bluetoothAuthorization = .allowedAlways
        let (central, _, _) = makeTestCentral()
        #expect(await central.authorization == .allowedAlways)

        FakeCentral.bluetoothAuthorization = .denied
        #expect(await central.authorization == .denied)
    }

    @Test("stopAndExtractState() throws .stopped for a test-backed Central (no real CBCentralManager)")
    func stopAndExtractStateThrowsForTestBackedCentral() async {
        let (central, _, _) = makeTestCentral()

        do {
            _ = try await central.stopAndExtractState()
            Issue.record("expected stopAndExtractState() to throw .stopped")
        } catch let error as BLESwiftError {
            #expect(error == .stopped)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("adopting init wires a real CBCentralManager: state is mapped, stopAndExtractState returns the same instance")
    func adoptingInitWiresGivenManager() async throws {
        // A manager created with `queue: nil` delivers on main. The doc comment of
        // `init(adopting:callbackQueue:)` tells callers to pass `DispatchQueue.main` in this case.
        //
        // The test creates, adopts, and reads the manager in one block on main. The manager's first
        // `centralManagerDidUpdateState(_:)` is also delivered on main, so it cannot arrive until
        // the block returns. Reading the state from a test thread could let the update arrive first
        // and fail the `.unknown` expectations on a busy runner.
        let (central, managerID) = await MainActor.run { () -> (Central, ObjectIdentifier) in
            let manager = CBCentralManager(delegate: nil, queue: .main)
            let central = Central(adopting: manager, callbackQueue: .main)

            // The adopting init sets its synchronous `state` snapshot from the adopted manager's
            // current state. It does not leave the state `.unknown` until a delegate callback,
            // because that callback may never fire again. A new `CBCentralManager` always starts
            // `.unknown`, before its first `centralManagerDidUpdateState(_:)`. The test asserts
            // this directly, because the bridging init `CentralState(_: CBManagerState)` is
            // `internal` to `BLESwift` and this file does not use `@testable import`.
            #expect(manager.state == .unknown)
            #expect(central.state == .unknown)
            return (central, ObjectIdentifier(manager))
        }

        let (extractedManager, extractedPeripherals) = try await central.stopAndExtractState()

        // The instance is the same, not only an equal one. This proves that the adopting init
        // stored the caller's manager, that stopAndExtractState() returned it, and that the init
        // did not silently create a new manager.
        #expect(ObjectIdentifier(extractedManager) == managerID)
        #expect(extractedPeripherals.isEmpty)

        // A second call throws, because this Central gave up its reference above.
        do {
            _ = try await central.stopAndExtractState()
            Issue.record("expected a second stopAndExtractState() call to throw .stopped")
        } catch let error as BLESwiftError {
            #expect(error == .stopped)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    /// Collects the next `count` elements from `stream`.
    private func collectNext(_ count: Int, from stream: AsyncStream<CentralState>) async -> [CentralState] {
        var results: [CentralState] = []
        var iterator = stream.makeAsyncIterator()
        while results.count < count, let value = await iterator.next() {
            results.append(value)
        }
        return results
    }
}
