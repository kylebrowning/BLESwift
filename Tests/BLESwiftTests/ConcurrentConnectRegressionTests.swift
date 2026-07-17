//
//  ConcurrentConnectRegressionTests.swift
//  BLESwiftTests
//

import Foundation
import Synchronization
import Testing
import BLESwiftCore
import BLESwiftTestSupport
@testable import BLESwift

/// Regression tests for the concurrent-connect TOCTOU deadlock (plan-02 "Post-Phase-3
/// finding"): `connect(id)`'s occupied-slot guard and the slot write were not atomic — the
/// write happened inside `awaitConnect`'s continuation closure, reached across
/// `withTimeout`'s `group.addTask` suspension, so a second racing initiator for the same id
/// passed its guard during the first's suspension and overwrote the first's `Connecting`
/// entry (and its continuation), orphaning it → the losing task group never returned →
/// permanent deadlock.
///
/// The fix reserves the slot **synchronously** in each initiator's actor-isolated prologue
/// (`reserveConnectingSlot`), before any suspension, so a racing caller's guard now sees the
/// reservation and throws `.duplicateConnect`. These tests exercise all three
/// `establishConnection`-initiating paths racing one another. Each wraps the racy work in
/// ``runWithTimeout(_:_:)`` so a reintroduced deadlock surfaces as a loud failure instead of
/// hanging CI; every test also carries a coarse `.timeLimit` ceiling as a second backstop.
@Suite("Concurrent-connect deadlock regression")
struct ConcurrentConnectRegressionTests {

    // MARK: - Two concurrent user connect(sameID)

    @Test("Two concurrent connect(sameID): exactly one succeeds, the other throws .duplicateConnect, neither hangs", .timeLimit(.minutes(1)))
    func twoConcurrentConnectsSameID() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }
        let id = fakePeripheral.peripheralIdentifier

        let outcome = await runWithTimeout(.seconds(5)) { () -> [ConnectOutcome] in
            async let first = connectOutcome(central, id)
            async let second = connectOutcome(central, id)
            return await [first, second]
        }

        guard case .completed(let results) = outcome else {
            Issue.record("Two concurrent connect(sameID) deadlocked (timed out) — the TOCTOU regression is back")
            return
        }

        let successes = results.filter { $0.isSuccess }
        let duplicates = results.filter { $0.isDuplicate(id) }
        #expect(successes.count == 1, "expected exactly one success, got \(results)")
        #expect(duplicates.count == 1, "expected exactly one .duplicateConnect, got \(results)")

        // The winner is genuinely connected.
        guard case .connected = await central.connectionState(of: id) else {
            Issue.record("expected the winning connect to leave id .connected")
            return
        }
    }

    // MARK: - User connect racing a restoration manual-connect for the same id

    @Test("connect() racing a restoration manual-connect for the same id: no hang, one throws .duplicateConnect", .timeLimit(.minutes(1)))
    func connectRacingRestorationConnect() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationTestCentral(connectingTimeout: .seconds(30))
        register(fakePeripheral, on: fakeCentral)
        // The restoration manual re-connect hangs, so it stays in-flight (slot reserved and
        // attached) while the racing user connect runs.
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        let id = fakePeripheral.peripheralIdentifier

        // Restore a *connecting* peripheral: routing spawns a restoration manual re-connect
        // for it and consumes `pendingRestoration`, after which a user connect() is no longer
        // fenced out by `.backgroundRestorationInProgress`.
        fakeCentral.simulateRestoration(restoredState(for: id, state: .connecting))
        fakeCentral.simulateStateChange(.poweredOn)

        // Wait until the restoration connect has actually issued its CoreBluetooth attempt —
        // i.e. it has reserved and attached to id's slot.
        await waitUntil { fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }

        // Now race a user connect(id): the slot is occupied by the restoration attempt, so
        // this must throw .duplicateConnect promptly rather than overwrite it and hang.
        let outcome = await runWithTimeout(.seconds(5)) {
            await connectOutcome(central, id)
        }
        guard case .completed(let result) = outcome else {
            Issue.record("connect() racing a restoration manual-connect deadlocked (timed out)")
            return
        }
        #expect(result.isDuplicate(id), "expected .duplicateConnect(id), got \(result)")

        // The restoration attempt is still the live owner of the slot.
        guard case .connecting = await central.connectionState(of: id) else {
            Issue.record("expected id to remain .connecting under the restoration attempt")
            return
        }

        // Clean up the still-in-flight restoration attempt so it doesn't outlive the test.
        await central.cancelAllOperations()
        fakeCentral.simulateDisconnect(id, error: nil)
        await waitUntil {
            if case .disconnected = await central.connectionState(of: id) { return true }
            return false
        }
    }

    // MARK: - Auto-reconnect attempt racing a user connect(sameID)

    @Test("An in-flight auto-reconnect attempt racing a user connect(sameID): no hang, no orphan", .timeLimit(.minutes(1)))
    func reconnectAttemptRacingUserConnect() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }
        let id = fakePeripheral.peripheralIdentifier

        // Establish a connection with an auto-reconnect policy, then drop it — the reconnect
        // loop enters its backoff sleep.
        _ = try await central.connect(id, reconnect: .always(maxAttempts: nil, backoff: .milliseconds(20)))

        // The reconnect *attempt* (after the backoff) must hang, so it stays in-flight (slot
        // reserved and attached) while the racing user connect runs.
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateDisconnect(id, error: nil)

        // Wait until the reconnect attempt has issued its CoreBluetooth connect (call #2) —
        // i.e. it now owns id's slot.
        await waitUntil { fakeCentral.onQueue { fakeCentral.connectCallCount } == 2 }

        // Race a user connect(id) against the in-flight reconnect attempt.
        let outcome = await runWithTimeout(.seconds(5)) {
            await connectOutcome(central, id)
        }
        guard case .completed(let result) = outcome else {
            Issue.record("user connect() racing an in-flight reconnect attempt deadlocked (timed out)")
            return
        }
        // The reconnect attempt reserved first, so the user connect observes .duplicateConnect
        // — cleanly, with no orphaned continuation on either side.
        #expect(result.isDuplicate(id), "expected .duplicateConnect(id), got \(result)")

        // Clean up: cancel the reconnect loop + in-flight attempt, then resolve it.
        await central.cancelAllOperations()
        fakeCentral.simulateDisconnect(id, error: nil)
        await waitUntil {
            if case .disconnected = await central.connectionState(of: id) { return true }
            return false
        }
    }
}

// MARK: - Helpers

/// The distilled result of one `connect(_:)` call — success (carrying the resolved id) or a
/// typed `BLESwiftError`. `Sendable` so it can cross `runWithTimeout`/`async let` boundaries.
private enum ConnectOutcome: Sendable {
    case success(PeripheralIdentifier)
    case failure(BLESwiftError)
    case otherFailure

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    func isDuplicate(_ id: PeripheralIdentifier) -> Bool {
        if case .failure(.duplicateConnect(let matched)) = self { return matched == id }
        return false
    }
}

/// Runs `central.connect(id)` and distills it into a ``ConnectOutcome`` — never throwing, so
/// racing attempts can be gathered and compared without one throw unwinding the other.
private func connectOutcome(_ central: Central, _ id: PeripheralIdentifier) async -> ConnectOutcome {
    do {
        let peripheral = try await central.connect(id)
        return .success(peripheral.id)
    } catch let error as BLESwiftError {
        return .failure(error)
    } catch {
        return .otherFailure
    }
}

/// The outcome of ``runWithTimeout(_:_:)``: the operation's value, or an explicit timeout.
private enum TimeoutOutcome<T: Sendable>: Sendable {
    case completed(T)
    case timedOut
}

/// Races `operation` against `timeout`. Concurrency regression tests wrap their racy work in
/// this so a reintroduced deadlock surfaces as `.timedOut` (a loud, bounded failure) instead
/// of hanging the whole suite. On timeout the operation task is cancelled.
private func runWithTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> T
) async -> TimeoutOutcome<T> {
    await withTaskGroup(of: TimeoutOutcome<T>.self) { group in
        group.addTask { .completed(await operation()) }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return .timedOut
        }
        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first
    }
}

/// Registers `peripheral` as retrievable on `central` (its identifier keys the lookup
/// `Central` performs when reserving a connect slot).
private func register(_ peripheral: FakePeripheral, on central: FakeCentral) {
    central.onQueue {
        central.retrievablePeripherals[peripheral.identifier] = peripheral
    }
}

/// Polls `condition` until it's `true`, or a generous timeout elapses (at which point the
/// surrounding assertions report the real failure rather than hanging).
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A `Central` with restoration enabled (via the internal seam on non-iOS platforms — see
/// the dual-access note in `RestorationConfiguration.swift`), for the restoration-vs-connect
/// race.
private func makeRestorationTestCentral(
    connectingTimeout: Duration
) -> (Central, FakeCentral, FakePeripheral) {
    var configuration = Configuration()
    configuration.restoration = RestorationConfiguration(
        identifier: "BLESwiftTests.concurrentConnect.restore",
        connectingTimeout: connectingTimeout
    )
    return makeTestCentral(configuration: configuration)
}

/// A single-peripheral `RestoredState`, as CoreBluetooth would hand back.
private func restoredState(for id: PeripheralIdentifier, state: PeripheralConnectionState) -> RestoredState {
    RestoredState(peripherals: [RestoredPeripheral(identifier: id, state: state)])
}
