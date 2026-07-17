//
//  RestorationTests.swift
//  BLESwiftTests
//

import BLESwiftCore
import Foundation
import Synchronization
import Testing
@testable import BLESwift

/// Exercises Phase 8's background-restoration surface: `willRestoreState` buffering and
/// replay, `.poweredOn` routing (adopt restored-connected, manual re-connect for
/// restored-connecting, fail restored-disconnecting/disconnected), the
/// unhandled-notification surface, and the startup background-task window — all driven
/// through the fakes (`FakeCentral.simulateRestoration` delivers `willRestoreState`
/// before the state flip, mirroring CoreBluetooth's guaranteed ordering) and the
/// `StartupBackgroundTaskRunning` seam (SPM tests have no `UIApplication`).
@Suite("Background restoration")
struct RestorationTests {

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)

    // MARK: - Replay

    @Test("willRestoreState delivered before any subscriber is replayed, in order, to the first restorationEvents() consumer")
    func replayToLateSubscriber() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral()
        registerRetrievable(fakePeripheral, on: fakeCentral)

        let restored = restoredState(for: fakePeripheral, state: .connected)
        fakeCentral.simulateRestoration(restored)
        fakeCentral.simulateStateChange(.poweredOn)

        // Deliberately let the entire restoration complete BEFORE the first subscriber
        // arrives — the buffered-replay guarantee is the point of this test.
        await waitFor {
            if case .connected = await central.connectionState { return true }
            return false
        }

        let events = await collectRestorationEvents(central, count: 2)
        try #require(events.count == 2)

        guard case .willRestore(let replayedState) = events[0] else {
            Issue.record("expected .willRestore first, got \(events[0])")
            return
        }
        #expect(replayedState == restored)

        guard case .restoredConnection(let identifier) = events[1] else {
            Issue.record("expected .restoredConnection second, got \(events[1])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)

        // Adoption requires no CoreBluetooth connect call — the peripheral was restored
        // already connected.
        #expect(fakeCentral.onQueue { fakeCentral.connectCallCount } == 0)
    }

    // MARK: - Restored-connected adoption

    @Test("restored-connected peripheral is adopted as the live session and GATT operations work")
    func restoredConnectedAdoptionSupportsGATT() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral()
        registerRetrievable(fakePeripheral, on: fakeCentral)
        let scripted = Data([0x06, 0x48])
        fakePeripheral.onQueue {
            fakePeripheral.scriptedReadValues[Self.heartRateMeasurement] = scripted
        }

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connected))
        fakeCentral.simulateStateChange(.poweredOn)

        await waitFor {
            if case .connected = await central.connectionState { return true }
            return false
        }
        guard case .connected(let peripheral) = await central.connectionState else {
            Issue.record("expected .connected after restored-connected adoption")
            return
        }
        #expect(peripheral.id == fakePeripheral.peripheralIdentifier)

        let value: Data = try await peripheral.read(from: Self.heartRateMeasurement)
        #expect(value == scripted)
    }

    // MARK: - Restored-connecting manual re-connect

    @Test("restored-connecting peripheral gets a manual connect (CoreBluetooth never completes it on its own)")
    func restoredConnectingGetsManualConnect() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral()
        registerRetrievable(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .succeed }

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connecting))
        fakeCentral.simulateStateChange(.poweredOn)

        let events = await collectRestorationEvents(central, count: 2)
        try #require(events.count == 2)
        guard case .willRestore = events[0] else {
            Issue.record("expected .willRestore first, got \(events[0])")
            return
        }
        guard case .restoredConnection(let identifier) = events[1] else {
            Issue.record("expected .restoredConnection second, got \(events[1])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)

        // Exactly one manual re-connect was issued against CoreBluetooth.
        #expect(fakeCentral.onQueue { fakeCentral.connectCallCount } == 1)

        guard case .connected = await central.connectionState else {
            Issue.record("expected .connected after the manual re-connect")
            return
        }
    }

    @Test("restored-connecting manual connect times out per RestorationConfiguration.connectingTimeout")
    func restoredConnectingTimesOut() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral(connectingTimeout: .milliseconds(100))
        registerRetrievable(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connecting))
        fakeCentral.simulateStateChange(.poweredOn)

        // The timeout triggers the standard two-phase cancel: CoreBluetooth is asked to
        // cancel the pending connection, and the failure resolves once it confirms.
        await waitFor { fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let events = await collectRestorationEvents(central, count: 2)
        try #require(events.count == 2)
        guard case .failedToRestoreConnection(let identifier, let error) = events[1] else {
            Issue.record("expected .failedToRestoreConnection, got \(events[1])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)
        #expect(error as? BLESwiftError == .connectionTimedOut)
    }

    // MARK: - Restored-disconnecting/disconnected

    @Test("restored-disconnected peripheral fails restoration with .notConnected")
    func restoredDisconnectedFailsRestoration() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral()
        registerRetrievable(fakePeripheral, on: fakeCentral)

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .disconnected))
        fakeCentral.simulateStateChange(.poweredOn)

        let events = await collectRestorationEvents(central, count: 2)
        try #require(events.count == 2)
        guard case .failedToRestoreConnection(let identifier, let error) = events[1] else {
            Issue.record("expected .failedToRestoreConnection, got \(events[1])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)
        #expect(error as? BLESwiftError == .notConnected)

        guard case .disconnected = await central.connectionState else {
            Issue.record("expected .disconnected — nothing was restored")
            return
        }
    }

    // MARK: - Unhandled notifications

    @Test("a value update with no subscriber and no pending read surfaces as .unhandledNotification when restoration is enabled")
    func unhandledNotificationSurfaces() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral()
        registerRetrievable(fakePeripheral, on: fakeCentral)

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connected))
        fakeCentral.simulateStateChange(.poweredOn)
        await waitFor {
            if case .connected = await central.connectionState { return true }
            return false
        }

        // A notification from a listen that belonged to the previous app life: no BLESwift
        // subscriber, no pending read.
        let payload = Data([0xAB, 0xCD])
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: payload)

        let events = await collectRestorationEvents(central, count: 3)
        try #require(events.count == 3)
        guard case .unhandledNotification(let identifier, let characteristic, let value) = events[2] else {
            Issue.record("expected .unhandledNotification, got \(events[2])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)
        #expect(characteristic == Self.heartRateMeasurement)
        #expect(value == payload)
    }

    @Test("a notification arriving in the willRestoreState→poweredOn window (peripheral staged, not yet routed) surfaces as .unhandledNotification")
    func unhandledNotificationBeforeRoutingSurfaces() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral()
        registerRetrievable(fakePeripheral, on: fakeCentral)

        // Stage restoration, then deliver a notification BEFORE the .poweredOn flip —
        // the phase is still .idle (untracked), but the peripheral is pending
        // restoration, so the value must surface rather than drop.
        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connected))
        fakeCentral.onQueue {} // staged restoration landed in the actor
        let payload = Data([0x5A])
        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: payload)
        fakePeripheral.onQueue {}

        fakeCentral.simulateStateChange(.poweredOn)

        // Replay order: willRestore, unhandledNotification (pre-routing), restoredConnection.
        let events = await collectRestorationEvents(central, count: 3)
        try #require(events.count == 3)
        guard case .unhandledNotification(let identifier, let characteristic, let value) = events[1] else {
            Issue.record("expected .unhandledNotification second, got \(events[1])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)
        #expect(characteristic == Self.heartRateMeasurement)
        #expect(value == payload)
        guard case .restoredConnection = events[2] else {
            Issue.record("expected .restoredConnection third, got \(events[2])")
            return
        }
    }

    @Test("without restoration enabled, an unhandled value update emits nothing on restorationEvents()")
    func unhandledNotificationSilentWithoutRestoration() async throws {
        let (central, _, fakePeripheral, _) = try await makeConnectedTestCentral()

        let received = Mutex<Int>(0)
        let stream = await central.restorationEvents()
        let consumer = Task {
            for await _ in stream {
                received.withLock { $0 += 1 }
            }
        }

        fakePeripheral.simulateNotification(for: Self.heartRateMeasurement, value: Data([0x01]))
        fakePeripheral.onQueue {} // flush the delivery through the actor
        try? await Task.sleep(for: .milliseconds(50))

        #expect(received.withLock { $0 } == 0)
        consumer.cancel()
    }

    // MARK: - Startup background task

    @Test("the startup window opens at init and closes on the first .poweredOn with nothing to restore")
    func startupWindowClosesWhenNothingToRestore() async throws {
        let runner = FakeStartupBackgroundTask()
        let (_, fakeCentral, _) = makeRestorationCentral(startupBackgroundTask: runner)
        #expect(runner.beginCount == 1)
        #expect(runner.endCount == 0)

        fakeCentral.simulateStateChange(.poweredOn)

        await waitFor { runner.endCount == 1 }
        #expect(runner.endCount == 1)
    }

    @Test("expiration before .poweredOn fails the staged restoration with .startupBackgroundTaskExpired")
    func expirationFailsStagedRestoration() async throws {
        let runner = FakeStartupBackgroundTask()
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral(startupBackgroundTask: runner)
        registerRetrievable(fakePeripheral, on: fakeCentral)

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connected))
        fakeCentral.onQueue {} // ensure the staged restoration has landed in the actor

        runner.fireExpiration()

        let events = await collectRestorationEvents(central, count: 2)
        try #require(events.count == 2)
        guard case .failedToRestoreConnection(let identifier, let error) = events[1] else {
            Issue.record("expected .failedToRestoreConnection, got \(events[1])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)
        #expect(error as? BLESwiftError == .startupBackgroundTaskExpired)
        await waitFor { runner.endCount >= 1 }
        #expect(runner.endCount >= 1)

        // A later .poweredOn must not adopt anything — the staged restoration is gone.
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {}
        guard case .disconnected = await central.connectionState else {
            Issue.record("expected .disconnected — the expired restoration must not be adopted")
            return
        }
    }

    @Test("expiration during the restored-connecting manual connect fails it with .startupBackgroundTaskExpired")
    func expirationFailsInFlightManualConnect() async throws {
        let runner = FakeStartupBackgroundTask()
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral(startupBackgroundTask: runner)
        registerRetrievable(fakePeripheral, on: fakeCentral)
        fakeCentral.onQueue { fakeCentral.connectBehavior = .hang }

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connecting))
        fakeCentral.simulateStateChange(.poweredOn)
        await waitFor { fakeCentral.onQueue { fakeCentral.connectCallCount } == 1 }

        runner.fireExpiration()

        // Expiration routes through the standard two-phase cancel; complete it.
        await waitFor { fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let events = await collectRestorationEvents(central, count: 2)
        try #require(events.count == 2)
        guard case .failedToRestoreConnection(let identifier, let error) = events[1] else {
            Issue.record("expected .failedToRestoreConnection, got \(events[1])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)
        #expect(error as? BLESwiftError == .startupBackgroundTaskExpired)
        await waitFor { runner.endCount >= 1 }
        #expect(runner.endCount >= 1)
    }

    // MARK: - Interactions

    @Test("connect() while a restoration is staged throws .backgroundRestorationInProgress")
    func connectDuringStagedRestorationRejected() async throws {
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral()
        registerRetrievable(fakePeripheral, on: fakeCentral)

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connected))
        fakeCentral.onQueue {} // ensure the staged restoration has landed in the actor

        do {
            _ = try await central.connect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected .backgroundRestorationInProgress")
        } catch let error as BLESwiftError {
            #expect(error == .backgroundRestorationInProgress)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("a non-poweredOn state fails the staged restoration with .bluetoothUnavailable rather than clearing it silently")
    func poweredOffFailsStagedRestoration() async throws {
        let runner = FakeStartupBackgroundTask()
        let (central, fakeCentral, fakePeripheral) = makeRestorationCentral(startupBackgroundTask: runner)
        registerRetrievable(fakePeripheral, on: fakeCentral)

        fakeCentral.simulateRestoration(restoredState(for: fakePeripheral, state: .connected))
        fakeCentral.simulateStateChange(.poweredOff)

        let events = await collectRestorationEvents(central, count: 2)
        try #require(events.count == 2)
        guard case .failedToRestoreConnection(let identifier, let error) = events[1] else {
            Issue.record("expected .failedToRestoreConnection, got \(events[1])")
            return
        }
        #expect(identifier == fakePeripheral.peripheralIdentifier)
        #expect(error as? BLESwiftError == .bluetoothUnavailable)
        await waitFor { runner.endCount >= 1 }
        #expect(runner.endCount >= 1)
    }
}

// MARK: - Helpers

/// A `Configuration` with restoration enabled (via the internal seam on non-iOS
/// platforms — see the dual-access note in `RestorationConfiguration.swift`), wired
/// through `makeTestCentral`.
private func makeRestorationCentral(
    connectingTimeout: Duration = .seconds(15),
    startupBackgroundTask: (any StartupBackgroundTaskRunning)? = nil
) -> (Central, FakeCentral, FakePeripheral) {
    var configuration = Configuration()
    configuration.restoration = RestorationConfiguration(
        identifier: "BLESwiftTests.restore",
        connectingTimeout: connectingTimeout
    )
    return makeTestCentral(configuration: configuration, startupBackgroundTask: startupBackgroundTask)
}

/// A single-peripheral `RestoredState`, as CoreBluetooth would hand back for `peripheral`.
private func restoredState(for peripheral: FakePeripheral, state: PeripheralConnectionState) -> RestoredState {
    RestoredState(
        peripherals: [RestoredPeripheral(identifier: peripheral.peripheralIdentifier, state: state)]
    )
}

/// Registers `peripheral` as retrievable from `central` — restoration routing re-resolves
/// restored peripherals via `retrievePeripherals(withIdentifiers:)`.
private func registerRetrievable(_ peripheral: FakePeripheral, on central: FakeCentral) {
    central.onQueue {
        central.retrievablePeripherals[peripheral.identifier] = peripheral
    }
}

/// Collects up to `count` restoration events, giving up (and returning what arrived) after
/// `timeout` so a missing event fails the test's assertions instead of hanging it.
private func collectRestorationEvents(
    _ central: Central,
    count: Int,
    timeout: Duration = .seconds(2)
) async -> [RestorationEvent] {
    let stream = await central.restorationEvents()
    let collector = Task {
        var events: [RestorationEvent] = []
        for await event in stream {
            events.append(event)
            if events.count == count { break }
        }
        return events
    }
    let deadline = Task {
        try? await Task.sleep(for: timeout)
        collector.cancel()
    }
    let events = await collector.value
    deadline.cancel()
    return events
}
