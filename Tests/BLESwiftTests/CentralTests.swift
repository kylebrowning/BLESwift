//
//  CentralTests.swift
//  BLESwiftTests
//

@preconcurrency import CoreBluetooth
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Exercises the `Central` actor's Phase 3 surface: state snapshot/stream wiring through
/// `makeTestCentral()`, using a `FakeCentral` in place of a real `CBCentralManager`.
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
        // Flush the fake's async event delivery, then let the actor's `handle(_:)` (also
        // scheduled via the same serial queue) run to completion before subscribing.
        fakeCentral.onQueue {}
        #expect(central.state == .poweredOn)

        var iterator = await central.stateEvents().makeAsyncIterator()
        let replayed = await iterator.next()

        #expect(replayed == .poweredOn)
    }

    @Test("Two subscribers both observe a poweredOn -> poweredOff transition, in order")
    func twoSubscribersObserveSameTransition() async {
        let (central, fakeCentral, _) = makeTestCentral()

        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {}
        #expect(central.state == .poweredOn)

        let stream1 = await central.stateEvents()
        let stream2 = await central.stateEvents()

        async let collected1 = collectNext(2, from: stream1)
        async let collected2 = collectNext(2, from: stream2)

        // Give both subscribers a chance to register (and drain their .latest replay of
        // .poweredOn) before the next transition is simulated.
        await Task.yield()
        await Task.yield()

        fakeCentral.simulateStateChange(.poweredOff)
        fakeCentral.onQueue {} // flush

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
        // A manager created with `queue: nil` delivers on main — exactly the case
        // `init(adopting:callbackQueue:)`'s doc comment tells callers to pass
        // `DispatchQueue.main as! DispatchSerialQueue` for. Verified runtime-castable
        // (Phase 0 finding).
        let mainQueue = DispatchQueue.main as! DispatchSerialQueue
        let manager = CBCentralManager(delegate: nil, queue: mainQueue)

        let central = Central(adopting: manager, callbackQueue: mainQueue)

        // The adopting init seeds its synchronous `state` snapshot from the adopted
        // manager's current state at adoption time, rather than leaving it `.unknown`
        // until a delegate callback that may never re-fire. A freshly created
        // `CBCentralManager` always starts in `.unknown` (before its first
        // `centralManagerDidUpdateState(_:)`) — asserted directly rather than via the
        // `CentralState(_: CBManagerState)` bridging init, which is `internal` to
        // `BLESwift` (this file no longer uses `@testable import`).
        #expect(manager.state == .unknown)
        #expect(central.state == .unknown)

        let (extractedManager, extractedPeripheral) = try await central.stopAndExtractState()

        // Same instance, not merely an equal one — proves the adopting init actually
        // stored (and stopAndExtractState() handed back) the manager passed in, rather
        // than, say, silently creating a fresh one.
        #expect(extractedManager === manager)
        #expect(extractedPeripheral == nil)

        // A second call throws — this Central gave up its reference above.
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
