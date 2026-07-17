//
//  ConnectionTests.swift
//  BLESwiftTests
//

import Foundation
import Synchronization
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Exercises `Central`'s Phase 5 connection lifecycle surface: `connect`, `disconnect`,
/// `cancelAllOperations`, `connectionEvents()`/`connectionState`, and auto-reconnect — all
/// driven through `makeTestCentral()`'s `FakeCentral`/`FakePeripheral` pair.
@Suite("Connection lifecycle")
struct ConnectionTests {

    // MARK: - connect()

    @Test("connect() succeeds: returns a matching Peripheral and connectionState becomes .connected")
    func connectSucceeds() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
        #expect(peripheral.id == fakePeripheral.peripheralIdentifier)

        guard case .connected(let connected) = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .connected")
            return
        }
        #expect(connected.id == fakePeripheral.peripheralIdentifier)
    }

    @Test("connect()'s warningOptions reach the backend seam unchanged")
    func warningOptionsReachConnectOptions() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let options = WarningOptions(
            notifyOnConnection: true,
            notifyOnDisconnection: false,
            notifyOnNotification: true
        )
        _ = try await central.connect(fakePeripheral.peripheralIdentifier, warningOptions: options)

        let recorded = fakeCentral.onQueue { fakeCentral.lastConnectOptions }
        #expect(recorded?.notifyOnConnection == true)
        #expect(recorded?.notifyOnDisconnection == false)
        #expect(recorded?.notifyOnNotification == true)
    }

    @Test("connect() failure: throws the CoreBluetooth-reported error and returns to .disconnected")
    func connectFails() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        let expectedError = NSError(domain: "BLESwiftTests", code: 42)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .fail(expectedError) }

        do {
            _ = try await central.connect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected connect() to throw")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "BLESwiftTests")
            #expect(nsError.code == 42)
        }

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected after a failed connect")
            return
        }
    }

    @Test("connect() against an unknown identifier throws .unexpectedPeripheral")
    func connectUnknownPeripheralThrows() async throws {
        let (central, _, fakePeripheral) = makeTestCentral()
        // Deliberately not registered as retrievable.

        do {
            _ = try await central.connect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected .unexpectedPeripheral")
        } catch let error as BLESwiftError {
            #expect(error == .unexpectedPeripheral(fakePeripheral.peripheralIdentifier))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("connect() while already connecting throws .duplicateConnect(id)")
    func doubleConnectRejected() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }

        let firstAttempt = Task {
            try? await central.connect(fakePeripheral.peripheralIdentifier)
        }

        await waitUntil { fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }

        do {
            _ = try await central.connect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected .duplicateConnect(fakePeripheral.peripheralIdentifier)")
        } catch let error as BLESwiftError {
            #expect(error == .duplicateConnect(fakePeripheral.peripheralIdentifier))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        // Clean up the still-pending first attempt so it doesn't outlive the test.
        firstAttempt.cancel()
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        _ = await firstAttempt.value
    }

    @Test("connect() while connected throws .duplicateConnect(id)")
    func connectWhileConnectedRejected() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }
        _ = try await central.connect(fakePeripheral.peripheralIdentifier)

        do {
            _ = try await central.connect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected .duplicateConnect(fakePeripheral.peripheralIdentifier)")
        } catch let error as BLESwiftError {
            #expect(error == .duplicateConnect(fakePeripheral.peripheralIdentifier))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Timeout / cancellation (two-phase cancel)

    @Test("connect() timeout cancels the pending CoreBluetooth connection, then throws .connectionTimedOut once CB confirms")
    func connectTimesOut() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {}

        let connectTask = Task {
            try await central.connect(fakePeripheral.peripheralIdentifier, timeout: .milliseconds(30))
        }

        // Wait for the timeout to fire and trigger the two-phase cancel.
        await waitUntil { fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }

        // The task shouldn't have resolved yet: the two-phase cancel is still awaiting
        // CoreBluetooth's confirmation.
        #expect(connectTask.isCancelled == false)

        // Simulate CoreBluetooth confirming the cancellation.
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let result = await connectTask.result
        switch result {
        case .success:
            Issue.record("expected connect() to throw .connectionTimedOut")
        case .failure(let error as BLESwiftError):
            #expect(error == .connectionTimedOut)
        case .failure(let error):
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("Cancelling connect()'s Task cancels the pending CoreBluetooth connection, then throws .operationCancelled once CB confirms")
    func connectTaskCancellation() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {}

        let connectTask = Task {
            try await central.connect(fakePeripheral.peripheralIdentifier, timeout: nil)
        }

        await waitUntil { fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }
        connectTask.cancel()

        await waitUntil { fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let result = await connectTask.result
        switch result {
        case .success:
            Issue.record("expected connect() to throw .operationCancelled")
        case .failure(let error as BLESwiftError):
            #expect(error == .operationCancelled)
        case .failure(let error):
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Disconnect / cancelAllOperations

    @Test("disconnect() resolves cleanly and moves connectionState back to .disconnected")
    func explicitDisconnectResolves() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }
        _ = try await central.connect(fakePeripheral.peripheralIdentifier)

        try await central.disconnect(fakePeripheral.peripheralIdentifier)

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected after disconnect()")
            return
        }
    }

    @Test("disconnect() with nothing connected throws .notConnected")
    func disconnectWithoutConnectionThrows() async throws {
        let (central, _, fakePeripheral) = makeTestCentral()

        do {
            try await central.disconnect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected .notConnected")
        } catch let error as BLESwiftError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("A second concurrent disconnect() throws .multipleDisconnectNotSupported")
    func doubleDisconnectRejected() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }
        _ = try await central.connect(fakePeripheral.peripheralIdentifier)

        // Radio must be `.poweredOn` for `disconnect()` to actually wait on CoreBluetooth's
        // confirmation (via `cancelPeripheralConnection`) rather than resolving
        // synchronously — otherwise the first `disconnect()` would finish before the
        // second one has a chance to observe `.disconnecting`.
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {}

        let firstDisconnect = Task {
            try await central.disconnect(fakePeripheral.peripheralIdentifier)
        }
        await waitUntil { await central.connectionState(of: fakePeripheral.peripheralIdentifier).isDisconnecting }

        do {
            try await central.disconnect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected .multipleDisconnectNotSupported")
        } catch let error as BLESwiftError {
            #expect(error == .multipleDisconnectNotSupported)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        _ = try await firstDisconnect.value
    }

    @Test("cancelAllOperations() cancels a pending connect without disconnecting an established connection")
    func cancelAllOperationsCancelsPendingConnect() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {}

        let connectTask = Task {
            try await central.connect(fakePeripheral.peripheralIdentifier, timeout: nil)
        }
        await waitUntil { fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }

        await central.cancelAllOperations()

        await waitUntil { fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let result = await connectTask.result
        switch result {
        case .success:
            Issue.record("expected connect() to throw")
        case .failure(let error as BLESwiftError):
            #expect(error == .cancelled)
        case .failure(let error):
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected")
            return
        }
    }

    // MARK: - Event ordering

    @Test("connectionEvents() observes .connecting, .connected, then .disconnected in order for a clean connect + disconnect")
    func connectionEventsOrdering() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let stream = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            await collect(3, from: stream)
        }
        await Task.yield()

        _ = try await central.connect(fakePeripheral.peripheralIdentifier)
        try await central.disconnect(fakePeripheral.peripheralIdentifier)

        let collected = await collector.value
        #expect(collected.count == 3)
        assertCase(collected.count > 0 ? collected[0] : nil, is: { if case .connecting = $0 { return true } else { return false } }, "expected .connecting first")
        assertCase(collected.count > 1 ? collected[1] : nil, is: { if case .connected = $0 { return true } else { return false } }, "expected .connected second")
        assertCase(collected.count > 2 ? collected[2] : nil, is: { if case .disconnected = $0 { return true } else { return false } }, "expected .disconnected third")
    }

    // MARK: - Auto-reconnect

    @Test("An unexpected disconnect triggers reconnect per policy: .reconnecting then .connected again")
    func unexpectedDisconnectTriggersReconnect() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let stream = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            await collect(6, from: stream)
        }
        await Task.yield()

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
        )

        // Unexpected disconnect — not via `disconnect()`.
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let collected = await collector.value
        #expect(collected.count == 6)
        // [0] connecting, [1] connected, [2] disconnected(willReconnect: true),
        // [3] reconnecting(attempt: 1), [4] connecting (the reconnect attempt's own
        // `awaitConnect` yields `.connecting` too, same as any other attempt), [5] connected
        // (the reconnect attempt succeeds since connectBehavior is still `.succeed`).
        if case .disconnected(_, _, let willReconnect) = collected[2] {
            #expect(willReconnect)
        } else {
            Issue.record("expected .disconnected(willReconnect: true) at index 2, got \(collected[2])")
        }
        if case .reconnecting(_, let attempt) = collected[3] {
            #expect(attempt == 1)
        } else {
            Issue.record("expected .reconnecting(attempt: 1) at index 3, got \(collected[3])")
        }
        if case .connecting = collected[4] {} else {
            Issue.record("expected .connecting at index 4, got \(collected[4])")
        }
        if case .connected = collected[5] {} else {
            Issue.record("expected .connected at index 5, got \(collected[5])")
        }

        guard case .connected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected connectionState == .connected after a successful reconnect")
            return
        }
    }

    @Test("An explicit disconnect() never triggers a reconnect, even with a non-.never policy")
    func explicitDisconnectNeverReconnects() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
        )
        try await central.disconnect(fakePeripheral.peripheralIdentifier)

        // Give any (incorrect) reconnect loop a chance to fire.
        try await Task.sleep(for: .milliseconds(100))

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected with no reconnect attempted")
            return
        }
        // Exactly one connect() call was made — no reconnect attempt issued a second one.
        #expect(fakeCentral.onQueue { fakeCentral.connectCallCount } == 1)
    }

    @Test("cancelAllOperations() cancelling a pending connect never triggers a reconnect")
    func cancelAllOperationsNeverReconnects() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {}

        let connectTask = Task {
            try? await central.connect(
                fakePeripheral.peripheralIdentifier,
                timeout: nil,
                reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
            )
        }
        await waitUntil { fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }

        await central.cancelAllOperations()
        await waitUntil { fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        _ = await connectTask.value

        try await Task.sleep(for: .milliseconds(100))

        #expect(fakeCentral.onQueue { fakeCentral.connectCallCount } == 1)
    }

    @Test("Reconnect gives up after maxAttempts, then leaves connectionState .disconnected")
    func reconnectMaxAttemptsExhaustion() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        let failError = NSError(domain: "BLESwiftTests", code: 7)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let stream = await central.connectionEvents()
        // connecting, connected, disconnected(1), reconnecting(1), connecting, disconnected(2),
        // reconnecting(2), connecting, disconnected(3) — maxAttempts: 2 means exactly two
        // .reconnecting events, each followed by a failed retry.
        let collector = Task { () -> [ConnectionEvent] in
            await collect(9, from: stream)
        }
        await Task.yield()

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: 2, backoff: .milliseconds(5))
        )

        fakeCentral.onQueue { fakeCentral.connectBehavior = .fail(failError) }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let collected = await collector.value
        #expect(collected.count == 9)

        let reconnectingEvents = collected.compactMap { event -> Int? in
            if case .reconnecting(_, let attempt) = event { return attempt }
            return nil
        }
        #expect(reconnectingEvents == [1, 2])

        // Give the (exhausted) loop a moment to fully wind down, then confirm no third
        // .reconnecting ever arrives.
        try await Task.sleep(for: .milliseconds(80))
        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected after reconnect attempts are exhausted")
            return
        }
    }

    @Test("disconnect() during an in-flight auto-reconnect backoff cancels it without throwing, and no further connect attempt is made")
    func disconnectDuringReconnectBackoffCancelsIt() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: nil, backoff: .milliseconds(300))
        )

        let connectCountBeforeReconnectAttempt = fakeCentral.onQueue { fakeCentral.connectCallCount }

        // Unexpected disconnect starts the reconnect loop's backoff sleep — `phase` becomes
        // `.idle` here, well before any reconnect attempt actually fires.
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        fakeCentral.onQueue {} // flush: didDisconnect handled, reconnectTask now scheduled

        // `disconnect()` while `phase == .idle` must cancel the pending reconnect rather
        // than throw `.notConnected` — regression test for the "zombie reconnect loop"
        // defect (an explicit disconnect during backoff previously left the loop running,
        // producing a second connect attempt and a surprise reconnection afterward).
        try await central.disconnect(fakePeripheral.peripheralIdentifier)

        // Wait past the original backoff window to prove no reconnect attempt ever fires.
        try await Task.sleep(for: .milliseconds(450))

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected — no reconnect should have completed after disconnect() cancelled the backoff")
            return
        }
        #expect(fakeCentral.onQueue { fakeCentral.connectCallCount } == connectCountBeforeReconnectAttempt)
    }

    @Test("cancelAllOperations() during an in-flight auto-reconnect backoff cancels it, and no further connect attempt is made")
    func cancelAllOperationsDuringReconnectBackoffCancelsIt() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: nil, backoff: .milliseconds(300))
        )

        let connectCountBeforeReconnectAttempt = fakeCentral.onQueue { fakeCentral.connectCallCount }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        fakeCentral.onQueue {} // flush: didDisconnect handled, reconnectTask now scheduled

        // Regression test for the same "zombie reconnect loop" defect, via
        // `cancelAllOperations()` instead of `disconnect()`.
        await central.cancelAllOperations()

        try await Task.sleep(for: .milliseconds(450))

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected — no reconnect should have completed after cancelAllOperations() cancelled the backoff")
            return
        }
        #expect(fakeCentral.onQueue { fakeCentral.connectCallCount } == connectCountBeforeReconnectAttempt)
    }

    @Test("ReconnectPolicy.custom controls attempt delays and can stop retrying")
    func customPolicyControlsRetries() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let attemptLog = AttemptLog()
        let policy = ReconnectPolicy.custom { attempt, _ in
            attemptLog.record(attempt)
            return attempt < 2 ? .milliseconds(5) : nil
        }

        let stream = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            await collect(4, from: stream)
        }
        await Task.yield()

        _ = try await central.connect(fakePeripheral.peripheralIdentifier, reconnect: policy)

        let failError = NSError(domain: "BLESwiftTests", code: 99)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .fail(failError) }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let collected = await collector.value
        #expect(collected.count == 4)

        try await Task.sleep(for: .milliseconds(60))
        #expect(attemptLog.attempts == [1, 2])
    }

    // MARK: - Peripheral event-target (delegate) wiring

    @Test("connect() wires the peripheral's eventHandler before initiating the connection")
    func connectAttachesEventTarget() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        #expect(fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount } == 0)

        _ = try await central.connect(fakePeripheral.peripheralIdentifier)

        // In production this is the `CBPeripheral.delegate = proxy` assignment real
        // CoreBluetooth requires for any GATT callback to arrive; the fake's `eventHandler`
        // is now both the protocol witness and the actual delivery path (replacing the old
        // decoupled `eventSink` + `attachEventTarget` call-counter split), so this also
        // proves events are actually delivered, not just that a wiring call happened.
        #expect(fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount } >= 1)
    }

    @Test("a reconnect attempt re-attaches the peripheral's event target (cleared at teardown, re-wired on initiation)")
    func reconnectReattachesEventTarget() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let stream = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            await collect(6, from: stream)
        }
        await Task.yield()

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
        )
        let callsAfterFirstConnect = fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount }
        #expect(callsAfterFirstConnect >= 1)

        // Unexpected disconnect → teardown clears the target (attach(nil)), then the
        // reconnect attempt's own initiation re-attaches it.
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        let collected = await collector.value
        #expect(collected.count == 6) // ... .disconnected, .reconnecting, .connecting, .connected

        // At least two more calls since the first connect: the teardown clear and the
        // reconnect attempt's re-attach.
        let callsAfterReconnect = fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount }
        #expect(callsAfterReconnect >= callsAfterFirstConnect + 2)
    }

    @Test("explicit disconnect() clears the peripheral's event target at final teardown")
    func disconnectClearsEventTarget() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        register(fakePeripheral, on: fakeCentral)
        // Powered on so disconnect() goes through the real cancelPeripheralConnection
        // confirmation path rather than resolving synchronously.
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheral.peripheralIdentifier)
        let callsAfterConnect = fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount }

        let disconnectTask = Task { try await central.disconnect(fakePeripheral.peripheralIdentifier) }
        await waitUntil { fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        try await disconnectTask.value

        let callsAfterDisconnect = fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount }
        #expect(callsAfterDisconnect >= callsAfterConnect + 1)
        // The final call is the teardown's clear.
        #expect(fakePeripheral.onQueue { fakePeripheral.eventHandler } == nil)
    }

    // MARK: - Adopting-init session adoption

    @Test("adopting an already-connected peripheral at init yields a live session: .connected state, event target attached, GATT works")
    func adoptedConnectedPeripheralSessionIsLive() async throws {
        // Exercises `init(adopting:connectedPeripheral:...)`'s adoption STRUCTURE via the
        // test init's mirrored path (`Session.adopted` + attach + `.connected` emission)
        // — the production initializer itself requires real CoreBluetooth objects and is
        // unreachable in SPM tests (Phase 10 audits that both paths share the shape).
        let service = ServiceIdentifier(uuid: "180F")
        let characteristic = CharacteristicIdentifier(uuid: "2A19", service: service)
        let (central, _, fakePeripheral) = makeTestCentral(adoptPeripheral: true)

        // The adoption attached the peripheral's event target during init.
        #expect(fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount } >= 1)

        // The session is live immediately — no connect() call was ever made.
        guard case .connected(let peripheral) = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .connected immediately after an adopting init")
            return
        }
        #expect(peripheral.id == fakePeripheral.peripheralIdentifier)

        // GATT operations route through the normal machinery against the adopted session.
        let scripted = Data([0x64])
        fakePeripheral.onQueue { fakePeripheral.scriptedReadValues[characteristic] = scripted }
        let value: Data = try await peripheral.read(from: characteristic)
        #expect(value == scripted)
    }
}

/// Exercises Phase 1's multi-peripheral connection support: N independent
/// connect/disconnect/reconnect/cancel lifecycles tracked simultaneously, keyed by
/// `PeripheralIdentifier` — the `connections`/`reconnectLoops` dictionaries replacing the
/// old single `Phase`/`reconnectTask`. Driven through `makeTestCentral()`'s primary fake
/// peripheral plus `addFakePeripheral(to:fakeCentral:)` for every additional one.
@Suite("Multi-peripheral connection lifecycle")
struct MultiPeripheralConnectionTests {

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)

    @Test("Two peripherals connect concurrently: both connectionState(of:) report .connected; connectedPeripherals has both, sorted")
    func twoConcurrentConnections() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        async let connectA = central.connect(fakePeripheralA.peripheralIdentifier)
        async let connectB = central.connect(fakePeripheralB.peripheralIdentifier)
        let (resolvedA, resolvedB) = try await (connectA, connectB)

        #expect(resolvedA.id == fakePeripheralA.peripheralIdentifier)
        #expect(resolvedB.id == fakePeripheralB.peripheralIdentifier)

        guard case .connected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A .connected")
            return
        }
        guard case .connected = await central.connectionState(of: fakePeripheralB.peripheralIdentifier) else {
            Issue.record("expected B .connected")
            return
        }

        let connected = await central.connectedPeripherals
        let expectedIDs = [fakePeripheralA.peripheralIdentifier, fakePeripheralB.peripheralIdentifier]
            .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        #expect(connected.map(\.id) == expectedIDs)
    }

    @Test("connect() to B while connected to A succeeds; connect() to A again throws .duplicateConnect(A)")
    func connectToSecondPeripheralWhileFirstConnected() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheralA.peripheralIdentifier)
        let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)
        #expect(peripheralB.id == fakePeripheralB.peripheralIdentifier)

        do {
            _ = try await central.connect(fakePeripheralA.peripheralIdentifier)
            Issue.record("expected .duplicateConnect(A)")
        } catch let error as BLESwiftError {
            #expect(error == .duplicateConnect(fakePeripheralA.peripheralIdentifier))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("Disconnecting A leaves B's session fully intact: B's pending GATT op survives A's disconnect")
    func disconnectingOnePeripheralLeavesAnotherIntact() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheralA.peripheralIdentifier)
        let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)

        fakePeripheralB.onQueue {
            fakePeripheralB.holdReadCompletions = true
            fakePeripheralB.scriptedReadValues[Self.heartRateMeasurement] = Data([0x42])
        }

        let readTask = Task<UInt8, Error> {
            try await peripheralB.read(from: Self.heartRateMeasurement)
        }
        await waitUntil { fakePeripheralB.onQueue { fakePeripheralB.readCallCount } == 1 }

        try await central.disconnect(fakePeripheralA.peripheralIdentifier)

        guard case .disconnected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A .disconnected")
            return
        }
        guard case .connected = await central.connectionState(of: fakePeripheralB.peripheralIdentifier) else {
            Issue.record("expected B still .connected")
            return
        }

        fakePeripheralB.simulateNextHeldReadCompletion()
        let value = try await readTask.value
        #expect(value == 0x42)
    }

    @Test("An unexpected disconnect of A tears down only A: .disconnected(A) observed on connectionEvents() while B stays .connected")
    func unexpectedDisconnectOfOneTearsDownOnlyThatOne() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheralA.peripheralIdentifier)
        _ = try await central.connect(fakePeripheralB.peripheralIdentifier)

        let stream = await central.connectionEvents()
        let collector = Task { () -> ConnectionEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        await Task.yield()

        fakeCentral.simulateDisconnect(fakePeripheralA.peripheralIdentifier, error: nil)

        guard let event = await collector.value, case .disconnected(let identifier, _, _) = event else {
            Issue.record("expected .disconnected")
            return
        }
        #expect(identifier == fakePeripheralA.peripheralIdentifier)

        guard case .disconnected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A .disconnected")
            return
        }
        guard case .connected = await central.connectionState(of: fakePeripheralB.peripheralIdentifier) else {
            Issue.record("expected B still .connected")
            return
        }
    }

    @Test("Independent reconnect loops: A (.always) reconnects on unexpected disconnect, B (.never) does not; disconnect(A) mid-backoff cancels only A's loop")
    func independentReconnectLoops() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheralA.peripheralIdentifier,
            reconnect: .always(maxAttempts: nil, backoff: .milliseconds(300))
        )
        _ = try await central.connect(fakePeripheralB.peripheralIdentifier, reconnect: .never)

        let stream = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            var collected: [ConnectionEvent] = []
            var iterator = stream.makeAsyncIterator()
            for _ in 0..<2 {
                guard let event = await iterator.next() else { break }
                collected.append(event)
            }
            return collected
        }
        await Task.yield()

        // Unexpected disconnect of BOTH.
        fakeCentral.simulateDisconnect(fakePeripheralA.peripheralIdentifier, error: nil)
        fakeCentral.simulateDisconnect(fakePeripheralB.peripheralIdentifier, error: nil)

        let collected = await collector.value
        #expect(collected.count == 2)
        for event in collected {
            guard case .disconnected(let identifier, _, let willReconnect) = event else {
                Issue.record("expected .disconnected, got \(event)")
                continue
            }
            if identifier == fakePeripheralA.peripheralIdentifier {
                #expect(willReconnect)
            } else if identifier == fakePeripheralB.peripheralIdentifier {
                #expect(!willReconnect)
            }
        }

        // B never reconnects — give any (incorrect) attempt a chance to fire.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralB.identifier] } == 1)

        // A's reconnect loop is mid-backoff (300ms); cancel it via disconnect(A).
        try await central.disconnect(fakePeripheralA.peripheralIdentifier)

        try await Task.sleep(for: .milliseconds(450))

        guard case .disconnected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A .disconnected — no reconnect should have completed after disconnect() cancelled the backoff")
            return
        }
        #expect(fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralA.identifier] } == 1)
    }

    @Test("disconnectAll() with one connecting (hung) and one connected: both end; the connecting attempt throws .explicitDisconnect; no reconnects")
    func disconnectAllEndsEveryTrackedPeripheral() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheralA.peripheralIdentifier,
            reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
        )

        fakeCentral.onQueue { fakeCentral.connectBehaviors[fakePeripheralB.identifier] = .hang }
        let connectBTask = Task {
            try await central.connect(fakePeripheralB.peripheralIdentifier, timeout: nil)
        }
        await waitUntil { fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralB.identifier] } == 1 }

        // `disconnectAll()` processes every tracked peripheral sequentially in an
        // unspecified (dictionary) order, fully awaiting each one's own CoreBluetooth
        // `cancelPeripheralConnection` confirmation before moving to the next (both A,
        // connected, and B, connecting, need one — the radio is powered on). Confirming
        // both concurrently, independently of which is processed first, avoids assuming an
        // order this test must not depend on.
        let disconnectAllTask = Task { await central.disconnectAll() }

        let confirmA = Task {
            await waitUntil { fakeCentral.onQueue { fakeCentral.cancelCallCounts[fakePeripheralA.identifier] } == 1 }
            fakeCentral.simulateDisconnect(fakePeripheralA.peripheralIdentifier, error: nil)
        }
        let confirmB = Task {
            await waitUntil { fakeCentral.onQueue { fakeCentral.cancelCallCounts[fakePeripheralB.identifier] } == 1 }
            // The still-connecting B attempt is two-phase-cancelled: confirming its cancel
            // resolves it throwing .explicitDisconnect.
            fakeCentral.simulateDisconnect(fakePeripheralB.peripheralIdentifier, error: nil)
        }
        _ = await (confirmA.value, confirmB.value)
        await disconnectAllTask.value

        let resultB = await connectBTask.result
        switch resultB {
        case .success:
            Issue.record("expected connect(B) to throw .explicitDisconnect")
        case .failure(let error as BLESwiftError):
            #expect(error == .explicitDisconnect)
        case .failure(let error):
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        guard case .disconnected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A .disconnected")
            return
        }
        guard case .disconnected = await central.connectionState(of: fakePeripheralB.peripheralIdentifier) else {
            Issue.record("expected B .disconnected")
            return
        }

        // No reconnect for A despite its .always policy — disconnectAll() is explicit
        // disconnection of every tracked peripheral, which never reconnects.
        try await Task.sleep(for: .milliseconds(60))
        #expect(fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralA.identifier] } == 1)
    }

    @Test("cancelAllOperations() with two connected sessions fails pending GATT ops on both; both stay connected")
    func cancelAllOperationsFailsGATTOpsOnBothConnectedPeripherals() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let peripheralA = try await central.connect(fakePeripheralA.peripheralIdentifier)
        let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)

        fakePeripheralA.onQueue { fakePeripheralA.holdReadCompletions = true }
        fakePeripheralB.onQueue { fakePeripheralB.holdReadCompletions = true }

        let readTaskA = Task<UInt8, Error> { try await peripheralA.read(from: Self.heartRateMeasurement) }
        let readTaskB = Task<UInt8, Error> { try await peripheralB.read(from: Self.heartRateMeasurement) }
        await waitUntil { fakePeripheralA.onQueue { fakePeripheralA.readCallCount } == 1 }
        await waitUntil { fakePeripheralB.onQueue { fakePeripheralB.readCallCount } == 1 }

        await central.cancelAllOperations()

        for result in [await readTaskA.result, await readTaskB.result] {
            switch result {
            case .success:
                Issue.record("expected the read to fail")
            case .failure(let error as BLESwiftError):
                #expect(error == .cancelled)
            case .failure(let error):
                Issue.record("expected a BLESwiftError, got \(error)")
            }
        }

        guard case .connected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A still .connected")
            return
        }
        guard case .connected = await central.connectionState(of: fakePeripheralB.peripheralIdentifier) else {
            Issue.record("expected B still .connected")
            return
        }
    }

    // MARK: - Adversarial probes

    @Test("connect(A) racing an in-flight disconnect(A) throws .duplicateConnect(A) while disconnecting, then succeeds after termination completes")
    func connectRacingInFlightDisconnectThrowsDuplicateThenSucceeds() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheralA.peripheralIdentifier)

        let disconnectTask = Task { try await central.disconnect(fakePeripheralA.peripheralIdentifier) }
        await waitUntil { fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }

        do {
            _ = try await central.connect(fakePeripheralA.peripheralIdentifier)
            Issue.record("expected .duplicateConnect while disconnecting")
        } catch let error as BLESwiftError {
            #expect(error == .duplicateConnect(fakePeripheralA.peripheralIdentifier))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        fakeCentral.simulateDisconnect(fakePeripheralA.peripheralIdentifier, error: nil)
        try await disconnectTask.value

        // The identifier is free again once the disconnect has fully resolved.
        let reconnected = try await central.connect(fakePeripheralA.peripheralIdentifier)
        #expect(reconnected.id == fakePeripheralA.peripheralIdentifier)
    }

    @Test("Power-off with A connected and B connecting fails both with .bluetoothUnavailable; the connections map is empty afterward")
    func powerOffFailsEveryTrackedPeripheral() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        register(fakePeripheralA, on: fakeCentral)
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheralA.peripheralIdentifier)

        fakeCentral.onQueue { fakeCentral.connectBehaviors[fakePeripheralB.identifier] = .hang }
        let connectBTask = Task {
            try await central.connect(fakePeripheralB.peripheralIdentifier, timeout: nil)
        }
        await waitUntil { fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralB.identifier] } == 1 }

        fakeCentral.simulateStateChange(.poweredOff)

        let resultB = await connectBTask.result
        switch resultB {
        case .success:
            Issue.record("expected connect(B) to throw .bluetoothUnavailable")
        case .failure(let error as BLESwiftError):
            #expect(error == .bluetoothUnavailable)
        case .failure(let error):
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        guard case .disconnected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A .disconnected")
            return
        }
        guard case .disconnected = await central.connectionState(of: fakePeripheralB.peripheralIdentifier) else {
            Issue.record("expected B .disconnected")
            return
        }
        #expect(await central.connectedPeripherals.isEmpty)
    }
}

// MARK: - Test helpers

/// Registers `peripheral` as retrievable by `central`, so `Central.connect(_:)` can resolve
/// it via `retrievePeripherals(withIdentifiers:)`.
private func register(_ peripheral: FakePeripheral, on central: FakeCentral) {
    central.onQueue {
        central.retrievablePeripherals[peripheral.identifier] = peripheral
    }
}

/// Polls `condition` until it's `true`, or a generous timeout elapses (at which point
/// whatever assertion depends on `condition` having become `true` will simply fail with a
/// clear "expected X, got Y" message rather than hanging the test suite).
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Collects the next `count` elements from `stream`, or fewer if it finishes early.
private func collect(_ count: Int, from stream: AsyncStream<ConnectionEvent>) async -> [ConnectionEvent] {
    var collected: [ConnectionEvent] = []
    var iterator = stream.makeAsyncIterator()
    for _ in 0..<count {
        guard let event = await iterator.next() else { break }
        collected.append(event)
    }
    return collected
}

/// Records an `Issue` with `message` if `value` is `nil` or fails `predicate`.
private func assertCase<T>(_ value: T?, is predicate: (T) -> Bool, _ message: String) {
    guard let value, predicate(value) else {
        Issue.record("\(message), got \(String(describing: value))")
        return
    }
}

extension ConnectionState {
    fileprivate var isDisconnecting: Bool {
        if case .disconnecting = self { return true }
        return false
    }
}

/// A tiny `Mutex`-backed box for collecting reconnect attempt numbers from a `@Sendable`
/// closure (`ReconnectPolicy.custom`'s closure) in tests.
private final class AttemptLog: Sendable {
    private let box = Mutex<[Int]>([])

    func record(_ attempt: Int) {
        box.withLock { $0.append(attempt) }
    }

    var attempts: [Int] {
        box.withLock { $0 }
    }
}
