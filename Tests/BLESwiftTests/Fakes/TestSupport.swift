//
//  TestSupport.swift
//  BLESwiftTests
//

import Dispatch
@testable import BLESwift

/// Creates a fresh ``FakeCentral``/``FakePeripheral`` pair sharing one
/// `DispatchSerialQueue`, ready for a test to script.
///
/// - Parameter label: A label for the underlying `DispatchSerialQueue`, useful for
///   debugging (e.g. visible in Instruments/lldb thread names). Defaults to a generic
///   label.
/// - Returns: A fake central, a fake peripheral, and the queue both were created with.
func makeFakeCentral(label: String = "BLESwiftTests.FakeCentral") -> (FakeCentral, FakePeripheral, DispatchSerialQueue) {
    let queue = DispatchSerialQueue(label: label)
    let central = FakeCentral(queue: queue)
    let peripheral = FakePeripheral(queue: queue)
    return (central, peripheral, queue)
}

/// Creates a real ``Central`` actor wired to a fresh ``FakeCentral``/``FakePeripheral``
/// pair, for tests that exercise `Central` itself rather than the fakes directly.
///
/// Uses `Central`'s internal `init(testing:queue:configuration:)`, which — unlike the
/// production `init(configuration:)` — does not create a `CentralDelegateProxy` (there's
/// no real `CBCentralManagerDelegate` to install on a `FakeCentral`). Instead, this wires
/// the fakes' `eventSink`s directly to `Central.handle(_:)`/`handle(_:from:)`, via
/// `assumeIsolated` — sound for the same reason the real proxy's use of `assumeIsolated`
/// is sound: fake event delivery is confined to `queue`, the exact `DispatchSerialQueue`
/// backing `Central`'s custom executor, so the sink closures already run on the actor's
/// own executor by construction.
///
/// - Parameter configuration: Passed through to `Central`. Defaults to `Configuration()`.
/// - Returns: The wired `Central`, and the `FakeCentral`/`FakePeripheral` backing it —
///   script these to drive `Central`'s behavior.
/// ``makeTestCentral()`` plus a completed connection: registers the fake peripheral as
/// retrievable, scripts a successful connect, and connects — returning the connected
/// ``Peripheral`` handle alongside the rig. The standard starting point for GATT-level
/// tests (reads/writes/notifications/composites).
func makeConnectedTestCentral() async throws -> (Central, FakeCentral, FakePeripheral, Peripheral) {
    let (central, fakeCentral, fakePeripheral) = makeTestCentral()
    // Power the radio on first: several lifecycle behaviors under test (notably the
    // last-release `setNotifyValue(false)`, which is ledger-guarded on `.poweredOn`) are
    // deliberately skipped while the radio isn't on, exactly as on real hardware.
    fakeCentral.simulateStateChange(.poweredOn)
    fakeCentral.onQueue {
        fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
        fakeCentral.connectBehavior = .succeed
    }
    let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
    return (central, fakeCentral, fakePeripheral, peripheral)
}

/// Polls `condition` until it's `true`, or a generous timeout elapses (the surrounding
/// test's own assertions then report the actual failure).
func waitFor(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func makeTestCentral(
    configuration: Configuration = Configuration(),
    startupBackgroundTask: (any StartupBackgroundTaskRunning)? = nil,
    adoptPeripheral: Bool = false
) -> (Central, FakeCentral, FakePeripheral) {
    let (fakeCentral, fakePeripheral, queue) = makeFakeCentral()
    let central = Central(
        testing: fakeCentral,
        queue: queue,
        configuration: configuration,
        startupBackgroundTask: startupBackgroundTask,
        connectedPeripheral: adoptPeripheral ? fakePeripheral : nil
    )

    fakeCentral.onQueue {
        fakeCentral.eventSink = { event in
            central.assumeIsolated { $0.handle(event) }
        }
    }

    fakePeripheral.onQueue {
        fakePeripheral.eventSink = { event in
            central.assumeIsolated { $0.handle(event, from: fakePeripheral.peripheralIdentifier) }
        }
    }

    return (central, fakeCentral, fakePeripheral)
}
