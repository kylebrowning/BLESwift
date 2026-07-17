//
//  TestHelpers.swift
//  BLESwiftTests
//

import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

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
/// Uses `Central`'s public `init(backend:queue:configuration:startupBackgroundTask:connectedPeripheral:)`
/// — no `@testable import` and no direct `handle(_:)`/`handle(_:from:)` wiring needed here;
/// that initializer does the wiring internally.
func makeTestCentral(
    configuration: Configuration = Configuration(),
    startupBackgroundTask: (any StartupBackgroundTaskRunning)? = nil,
    adoptPeripheral: Bool = false
) -> (Central, FakeCentral, FakePeripheral) {
    let (fakeCentral, fakePeripheral, queue) = makeFakeCentral()
    let central = Central(
        backend: fakeCentral,
        queue: queue,
        configuration: configuration,
        startupBackgroundTask: startupBackgroundTask,
        connectedPeripheral: adoptPeripheral ? fakePeripheral : nil
    )
    return (central, fakeCentral, fakePeripheral)
}

/// ``makeTestCentral()`` plus a completed connection: registers the fake peripheral as
/// retrievable, scripts a successful connect, and connects — returning the connected
/// ``Peripheral`` handle alongside the rig. The standard starting point for GATT-level
/// tests (reads/writes/notifications/composites).
///
/// - Returns: The wired `Central`, the `FakeCentral`/`FakePeripheral` backing it, and the
///   connected `Peripheral` handle.
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
