//
//  ConnectionTests.swift
//  BLESwiftTests
//

import Foundation
import BLESwiftCompat17
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Tests the `Central` connection lifecycle, including auto-reconnect, with the fakes from
/// `makeTestCentral()`.
@Suite("Connection lifecycle")
struct ConnectionTests {

    // MARK: - connect()

    @Test("connect() succeeds: returns a matching Peripheral and connectionState becomes .connected")
    func connectSucceeds() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let options = WarningOptions(
            notifyOnConnection: true,
            notifyOnDisconnection: false,
            notifyOnNotification: true
        )
        _ = try await central.connect(fakePeripheral.peripheralIdentifier, warningOptions: options)

        let recorded = await fakeCentral.onQueue { fakeCentral.lastConnectOptions }
        #expect(recorded?.notifyOnConnection == true)
        #expect(recorded?.notifyOnDisconnection == false)
        #expect(recorded?.notifyOnNotification == true)
    }

    @Test("connect() failure: throws the CoreBluetooth-reported error and returns to .disconnected")
    func connectFails() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        let expectedError = NSError(domain: "BLESwiftTests", code: 42)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .fail(expectedError) }

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
        // The peripheral is deliberately not registered as retrievable.

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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }

        let firstAttempt = Task {
            try? await central.connect(fakePeripheral.peripheralIdentifier)
        }

        await waitUntil { await fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }

        do {
            _ = try await central.connect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected .duplicateConnect(fakePeripheral.peripheralIdentifier)")
        } catch let error as BLESwiftError {
            #expect(error == .duplicateConnect(fakePeripheral.peripheralIdentifier))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        // Cancel the pending first attempt so it does not outlive the test.
        firstAttempt.cancel()
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        _ = await firstAttempt.value
    }

    @Test("connect() while connected throws .duplicateConnect(id)")
    func connectWhileConnectedRejected() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }
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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let connectTask = Task {
            try await central.connect(fakePeripheral.peripheralIdentifier, timeout: .milliseconds(30))
        }

        // Wait for the timeout to fire and start the two-phase cancel.
        await waitUntil { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }

        // The task stays unresolved until CoreBluetooth confirms the cancel.
        #expect(connectTask.isCancelled == false)

        // Simulate the CoreBluetooth cancel confirmation.
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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let connectTask = Task {
            try await central.connect(fakePeripheral.peripheralIdentifier, timeout: nil)
        }

        await waitUntil { await fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }
        connectTask.cancel()

        await waitUntil { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }

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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }
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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }
        _ = try await central.connect(fakePeripheral.peripheralIdentifier)

        // The radio must be `.poweredOn`, so `disconnect()` waits for the CoreBluetooth
        // confirmation. Otherwise the first `disconnect()` finishes before the second can observe
        // `.disconnecting`.
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let connectTask = Task {
            try await central.connect(fakePeripheral.peripheralIdentifier, timeout: nil)
        }
        await waitUntil { await fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }

        await central.cancelAllOperations()

        await waitUntil { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let stream = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            await collect(6, from: stream)
        }
        await Task.yield()

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
        )

        // Unexpected disconnect, not through `disconnect()`.
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let collected = await collector.value
        #expect(collected.count == 6)
        // In order: connecting, connected, disconnected(willReconnect: true), reconnecting(1),
        // connecting, connected. The reconnect attempt succeeds because connectBehavior is still
        // `.succeed`.
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
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
        )
        try await central.disconnect(fakePeripheral.peripheralIdentifier)

        // Wait to show that no reconnect loop fires.
        try await Task.sleep(for: .milliseconds(100))

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected with no reconnect attempted")
            return
        }
        // Exactly one connect() call: no reconnect attempt.
        #expect(await fakeCentral.onQueue { fakeCentral.connectCallCount } == 1)
    }

    @Test("cancelAllOperations() cancelling a pending connect never triggers a reconnect")
    func cancelAllOperationsNeverReconnects() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let connectTask = Task {
            try? await central.connect(
                fakePeripheral.peripheralIdentifier,
                timeout: nil,
                reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
            )
        }
        await waitUntil { await fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }

        await central.cancelAllOperations()
        await waitUntil { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        _ = await connectTask.value

        try await Task.sleep(for: .milliseconds(100))

        #expect(await fakeCentral.onQueue { fakeCentral.connectCallCount } == 1)
    }

    @Test("Reconnect gives up after maxAttempts, then leaves connectionState .disconnected")
    func reconnectMaxAttemptsExhaustion() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        let failError = NSError(domain: "BLESwiftTests", code: 7)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let stream = await central.connectionEvents()
        // In order: connecting, connected, disconnected(1), reconnecting(1), connecting,
        // disconnected(2), reconnecting(2), connecting, disconnected(3). `maxAttempts: 2` gives
        // exactly two `.reconnecting` events.
        let collector = Task { () -> [ConnectionEvent] in
            await collect(9, from: stream)
        }
        await Task.yield()

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: 2, backoff: .milliseconds(5))
        )

        await fakeCentral.onQueue { fakeCentral.connectBehavior = .fail(failError) }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let collected = await collector.value
        #expect(collected.count == 9)

        let reconnectingEvents = collected.compactMap { event -> Int? in
            if case .reconnecting(_, let attempt) = event { return attempt }
            return nil
        }
        #expect(reconnectingEvents == [1, 2])

        // Wait to confirm that no third `.reconnecting` arrives.
        try await Task.sleep(for: .milliseconds(80))
        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected after reconnect attempts are exhausted")
            return
        }
    }

    @Test("disconnect() during an in-flight auto-reconnect backoff cancels it without throwing, and no further connect attempt is made")
    func disconnectDuringReconnectBackoffCancelsIt() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: nil, backoff: .milliseconds(300))
        )

        let connectCountBeforeReconnectAttempt = await fakeCentral.onQueue { fakeCentral.connectCallCount }

        // The backoff sleep starts. `phase` is `.idle` well before any reconnect attempt fires.
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        await fakeCentral.onQueue {} // Flush. The code handled didDisconnect and scheduled reconnectTask.

        // Regression test for the zombie reconnect loop: `disconnect()` while `phase == .idle` must
        // cancel the pending reconnect and must not throw `.notConnected`.
        try await central.disconnect(fakePeripheral.peripheralIdentifier)

        // Wait past the backoff window to show that no reconnect attempt fires.
        try await Task.sleep(for: .milliseconds(450))

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected — no reconnect should have completed after disconnect() cancelled the backoff")
            return
        }
        #expect(await fakeCentral.onQueue { fakeCentral.connectCallCount } == connectCountBeforeReconnectAttempt)
    }

    @Test("cancelAllOperations() during an in-flight auto-reconnect backoff cancels it, and no further connect attempt is made")
    func cancelAllOperationsDuringReconnectBackoffCancelsIt() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: nil, backoff: .milliseconds(300))
        )

        let connectCountBeforeReconnectAttempt = await fakeCentral.onQueue { fakeCentral.connectCallCount }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        await fakeCentral.onQueue {} // Flush. The code handled didDisconnect and scheduled reconnectTask.

        // Same regression, with `cancelAllOperations()`.
        await central.cancelAllOperations()

        try await Task.sleep(for: .milliseconds(450))

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected — no reconnect should have completed after cancelAllOperations() cancelled the backoff")
            return
        }
        #expect(await fakeCentral.onQueue { fakeCentral.connectCallCount } == connectCountBeforeReconnectAttempt)
    }

    @Test("ReconnectPolicy.custom controls attempt delays and can stop retrying")
    func customPolicyControlsRetries() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

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
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .fail(failError) }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let collected = await collector.value
        #expect(collected.count == 4)

        // Wait for the second attempt instead of sleeping a fixed time, which can be too short on a
        // loaded machine. There is no third attempt because the policy returns `nil` for attempt 2.
        await waitFor(timeout: .seconds(10)) { attemptLog.attempts.count >= 2 }
        #expect(attemptLog.attempts == [1, 2])
    }

    // MARK: - Peripheral event-target (delegate) wiring

    @Test("connect() wires the peripheral's eventHandler before initiating the connection")
    func connectAttachesEventTarget() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        #expect(await fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount } == 0)

        _ = try await central.connect(fakePeripheral.peripheralIdentifier)

        // Production assigns `CBPeripheral.delegate = proxy`. The fake's `eventHandler` is the real
        // delivery path, so this also proves that the fake delivers events.
        #expect(await fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount } >= 1)
    }

    @Test("a reconnect attempt re-attaches the peripheral's event target (cleared at teardown, re-wired on initiation)")
    func reconnectReattachesEventTarget() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let stream = await central.connectionEvents()
        let collector = Task { () -> [ConnectionEvent] in
            await collect(6, from: stream)
        }
        await Task.yield()

        _ = try await central.connect(
            fakePeripheral.peripheralIdentifier,
            reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
        )
        let callsAfterFirstConnect = await fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount }
        #expect(callsAfterFirstConnect >= 1)

        // The teardown clears the target (attach(nil)). The reconnect attempt attaches it again.
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        let collected = await collector.value
        #expect(collected.count == 6) // The last events are .disconnected, .reconnecting, .connecting, .connected.

        // At least two more calls: the teardown clear and the reconnect attach.
        let callsAfterReconnect = await fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount }
        #expect(callsAfterReconnect >= callsAfterFirstConnect + 2)
    }

    @Test("explicit disconnect() clears the peripheral's event target at final teardown")
    func disconnectClearsEventTarget() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        await register(fakePeripheral, on: fakeCentral)
        // The radio is powered on, so disconnect() waits for the real cancel confirmation.
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheral.peripheralIdentifier)
        let callsAfterConnect = await fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount }

        let disconnectTask = Task { try await central.disconnect(fakePeripheral.peripheralIdentifier) }
        await waitUntil { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        try await disconnectTask.value

        let callsAfterDisconnect = await fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount }
        #expect(callsAfterDisconnect >= callsAfterConnect + 1)
        // The final call is the clear in the teardown.
        #expect(await fakePeripheral.onQueue { fakePeripheral.eventHandler == nil })
    }

    // MARK: - Adopting-init session adoption

    @Test("adopting an already-connected peripheral at init yields a live session: .connected state, event target attached, GATT works")
    func adoptedConnectedPeripheralSessionIsLive() async throws {
        // Tests the structure of `init(adopting:connectedPeripheral:...)` through the mirrored test
        // init (`Session.adopted`, attach, `.connected` emission). SPM tests cannot reach the
        // production initializer, so keep both paths in step.
        let service = ServiceIdentifier(uuid: "180F")
        let characteristic = CharacteristicIdentifier(uuid: "2A19", service: service)
        let (central, _, fakePeripheral) = makeTestCentral(adoptPeripheral: true)

        // The adoption attached the peripheral's event target during init.
        #expect(await fakePeripheral.onQueue { fakePeripheral.eventHandlerSetCount } >= 1)

        // The session is live immediately. The test never made a connect() call.
        guard case .connected(let peripheral) = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .connected immediately after an adopting init")
            return
        }
        #expect(peripheral.id == fakePeripheral.peripheralIdentifier)

        // GATT operations use the normal machinery against the adopted session.
        let scripted = Data([0x64])
        await fakePeripheral.onQueue { fakePeripheral.scriptedReadValues[characteristic] = scripted }
        let value: Data = try await peripheral.read(from: characteristic)
        #expect(value == scripted)
    }
}

/// Tests multiple peripherals in the connection lifecycle. Independent lifecycles, keyed by
/// `PeripheralIdentifier`, run at the same time. Tests use the primary peripheral of
/// `makeTestCentral()` and `addFakePeripheral(to:fakeCentral:)`.
@Suite("Multi-peripheral connection lifecycle")
struct MultiPeripheralConnectionTests {

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)

    @Test("Two peripherals connect concurrently: both connectionState(of:) report .connected; connectedPeripherals has both, sorted")
    func twoConcurrentConnections() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        await register(fakePeripheralA, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

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
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        await register(fakePeripheralA, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

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
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        await register(fakePeripheralA, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheralA.peripheralIdentifier)
        let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)

        await fakePeripheralB.onQueue {
            fakePeripheralB.holdReadCompletions = true
            fakePeripheralB.scriptedReadValues[Self.heartRateMeasurement] = Data([0x42])
        }

        let readTask = Task<UInt8, Error> {
            try await peripheralB.read(from: Self.heartRateMeasurement)
        }
        await waitUntil { await fakePeripheralB.onQueue { fakePeripheralB.readCallCount } == 1 }

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
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        await register(fakePeripheralA, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

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

    @Test("Independent reconnect loops: A (reconnecting policy) reconnects on unexpected disconnect, B (.never) does not; disconnect(A) mid-backoff cancels only A's loop")
    func independentReconnectLoops() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        await register(fakePeripheralA, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        // Hold A's backoff open with a gate instead of a timer. A timer let a starved runner expire
        // the backoff before `disconnect(A)` ran.
        let backoff = BackoffGate()
        _ = try await central.connect(
            fakePeripheralA.peripheralIdentifier,
            reconnect: .custom { _, _ in
                await backoff.wait()
                return .zero
            }
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

        // Unexpected disconnect of BOTH peripherals.
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

        // B never reconnects. Wait to show that no attempt fires.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralB.identifier] } == 1)

        // A's reconnect loop is parked on the gate in the backoff. Cancel it with disconnect(A),
        // then open the gate. A surviving loop would reconnect at once.
        await waitFor { backoff.entered }
        #expect(backoff.entered)
        try await central.disconnect(fakePeripheralA.peripheralIdentifier)
        backoff.release()

        try await Task.sleep(for: .milliseconds(200))

        guard case .disconnected = await central.connectionState(of: fakePeripheralA.peripheralIdentifier) else {
            Issue.record("expected A .disconnected — no reconnect should have completed after disconnect() cancelled the backoff")
            return
        }
        #expect(await fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralA.identifier] } == 1)
    }

    @Test("disconnectAll() with one connecting (hung) and one connected: both end; the connecting attempt throws .explicitDisconnect; no reconnects")
    func disconnectAllEndsEveryTrackedPeripheral() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        await register(fakePeripheralA, on: fakeCentral)
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(
            fakePeripheralA.peripheralIdentifier,
            reconnect: .always(maxAttempts: 3, backoff: .milliseconds(10))
        )

        await fakeCentral.onQueue { fakeCentral.connectBehaviors[fakePeripheralB.identifier] = .hang }
        let connectBTask = Task {
            try await central.connect(fakePeripheralB.peripheralIdentifier, timeout: nil)
        }
        await waitUntil { await fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralB.identifier] } == 1 }

        // `disconnectAll()` follows dictionary order, which is unspecified. Each peripheral needs a
        // cancel confirmation because the radio is powered on. Confirm both in any order so the
        // test does not depend on order.
        let disconnectAllTask = Task { await central.disconnectAll() }

        let confirmA = Task {
            await waitUntil { await fakeCentral.onQueue { fakeCentral.cancelCallCounts[fakePeripheralA.identifier] } == 1 }
            fakeCentral.simulateDisconnect(fakePeripheralA.peripheralIdentifier, error: nil)
        }
        let confirmB = Task {
            await waitUntil { await fakeCentral.onQueue { fakeCentral.cancelCallCounts[fakePeripheralB.identifier] } == 1 }
            // The two-phase cancel stops B's connecting attempt. Its confirmation throws
            // .explicitDisconnect.
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

        // A does not reconnect despite its .always policy: disconnectAll() is an explicit
        // disconnect.
        try await Task.sleep(for: .milliseconds(60))
        #expect(await fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralA.identifier] } == 1)
    }

    @Test("cancelAllOperations() with two connected sessions fails pending GATT ops on both; both stay connected")
    func cancelAllOperationsFailsGATTOpsOnBothConnectedPeripherals() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        await register(fakePeripheralA, on: fakeCentral)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        let peripheralA = try await central.connect(fakePeripheralA.peripheralIdentifier)
        let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)

        await fakePeripheralA.onQueue { fakePeripheralA.holdReadCompletions = true }
        await fakePeripheralB.onQueue { fakePeripheralB.holdReadCompletions = true }

        let readTaskA = Task<UInt8, Error> { try await peripheralA.read(from: Self.heartRateMeasurement) }
        let readTaskB = Task<UInt8, Error> { try await peripheralB.read(from: Self.heartRateMeasurement) }
        await waitUntil { await fakePeripheralA.onQueue { fakePeripheralA.readCallCount } == 1 }
        await waitUntil { await fakePeripheralB.onQueue { fakePeripheralB.readCallCount } == 1 }

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
        await register(fakePeripheralA, on: fakeCentral)
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheralA.peripheralIdentifier)

        let disconnectTask = Task { try await central.disconnect(fakePeripheralA.peripheralIdentifier) }
        await waitUntil { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }

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

        // The identifier is free after the disconnect resolves.
        let reconnected = try await central.connect(fakePeripheralA.peripheralIdentifier)
        #expect(reconnected.id == fakePeripheralA.peripheralIdentifier)
    }

    @Test("Power-off with A connected and B connecting fails both with .bluetoothUnavailable; the connections map is empty afterward")
    func powerOffFailsEveryTrackedPeripheral() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        await register(fakePeripheralA, on: fakeCentral)
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        _ = try await central.connect(fakePeripheralA.peripheralIdentifier)

        await fakeCentral.onQueue { fakeCentral.connectBehaviors[fakePeripheralB.identifier] = .hang }
        let connectBTask = Task {
            try await central.connect(fakePeripheralB.peripheralIdentifier, timeout: nil)
        }
        await waitUntil { await fakeCentral.onQueue { fakeCentral.connectCallCounts[fakePeripheralB.identifier] } == 1 }

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

/// Registers `peripheral` as retrievable by `central`, so `Central.connect(_:)` can resolve it.
private func register(_ peripheral: FakePeripheral, on central: FakeCentral) async {
    await central.onQueue {
        central.retrievablePeripherals[peripheral.identifier] = peripheral
    }
}

/// Polls `condition` until it is `true` or the timeout ends. After a timeout the dependent
/// assertion fails instead of the suite hanging.
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Collects the next `count` elements from `stream`, or fewer if the stream finishes early.
private func collect(_ count: Int, from stream: AsyncStream<ConnectionEvent>) async -> [ConnectionEvent] {
    var collected: [ConnectionEvent] = []
    var iterator = stream.makeAsyncIterator()
    for _ in 0..<count {
        guard let event = await iterator.next() else { break }
        collected.append(event)
    }
    return collected
}

/// Records an `Issue` with `message` if `value` is `nil` or does not satisfy `predicate`.
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

/// Holds a `ReconnectPolicy.custom` backoff open until the test calls ``release()``, so a test can
/// act mid-backoff without racing a timer. ``entered`` becomes true when the reconnect loop waits
/// on the gate.
private final class BackoffGate: Sendable {
    private struct State {
        var entered = false
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let box = Mutex(State())

    var entered: Bool {
        box.withLock { $0.entered }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let releasedAlready = box.withLock { state -> Bool in
                state.entered = true
                if !state.released { state.waiters.append(continuation) }
                return state.released
            }
            if releasedAlready { continuation.resume() }
        }
    }

    func release() {
        let waiters = box.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A `Mutex`-backed box that collects attempt numbers from a `ReconnectPolicy.custom` closure.
private final class AttemptLog: Sendable {
    private let box = Mutex<[Int]>([])

    func record(_ attempt: Int) {
        box.withLock { $0.append(attempt) }
    }

    var attempts: [Int] {
        box.withLock { $0 }
    }
}
