//
//  TestHelpers.swift
//  BLESwiftTests
//

import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch
import Foundation

/// Creates a new ``FakeCentral`` and ``FakePeripheral`` pair that share one `DispatchQueue`, so a
/// test can script the pair.
///
/// - Parameter label: A label for the underlying `DispatchQueue`, visible in thread names in
///   Instruments or lldb.
/// - Returns: A fake central, a fake peripheral, and the queue both were created with.
func makeFakeCentral(label: String = "BLESwiftTests.FakeCentral") -> (FakeCentral, FakePeripheral, DispatchQueue) {
    let queue = DispatchQueue(label: label)
    let central = FakeCentral(queue: queue)
    let peripheral = FakePeripheral(queue: queue)
    return (central, peripheral, queue)
}

/// Creates a real ``Central`` actor wired to a new ``FakeCentral`` and ``FakePeripheral`` pair. Use
/// it for tests that exercise `Central` itself and not the fakes directly.
///
/// It uses the public
/// `init(backend:queue:configuration:startupBackgroundTask:connectedPeripherals:)` of `Central`,
/// which does the wiring internally. It needs no `@testable import`.
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
        connectedPeripherals: adoptPeripheral ? [fakePeripheral] : []
    )
    return (central, fakeCentral, fakePeripheral)
}

/// ``makeTestCentral()`` plus a completed connection. It registers the fake peripheral as
/// retrievable, scripts a successful connect, and connects. This is the standard start point for
/// GATT-level tests (reads, writes, notifications, and composites).
///
/// - Returns: The wired `Central`, the `FakeCentral` and `FakePeripheral` that support it, and the
///   connected `Peripheral` handle.
func makeConnectedTestCentral() async throws -> (Central, FakeCentral, FakePeripheral, Peripheral) {
    let (central, fakeCentral, fakePeripheral) = makeTestCentral()
    // Power the radio on first. Several lifecycle behaviors under test are skipped on purpose while
    // the radio is not on, as on real hardware. One example is the `setNotifyValue(false)` at the
    // last release, which the ledger guards on `.poweredOn`.
    fakeCentral.simulateStateChange(.poweredOn)
    await fakeCentral.onQueue {
        fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
        fakeCentral.connectBehavior = .succeed
    }
    let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
    return (central, fakeCentral, fakePeripheral, peripheral)
}

/// Creates an additional `FakePeripheral` on the same queue as `fakeCentral` and registers it as
/// retrievable. This is the main helper for multi-peripheral tests. Pass the identifier that it
/// reports to `central.connect(_:)`, which wires the peripheral's `eventHandler` itself, as for the
/// primary fake peripheral. The helper needs no separate wiring step.
///
/// - Parameters:
///   - central: The `Central` that will later connect this peripheral. The helper does not use it
///     to wire anything. It accepts it so that call sites read "one more peripheral for this rig".
///   - fakeCentral: The fake that supports `central`. The helper registers the new peripheral as
///     retrievable on it.
///   - identifier: The identifier of the new peripheral. It defaults to a new `UUID`.
///   - name: The advertised or cached name of the new peripheral.
/// - Returns: The new `FakePeripheral`, already registered.
func addFakePeripheral(
    to central: Central,
    fakeCentral: FakeCentral,
    identifier: UUID = UUID(),
    name: String? = "Fake Peripheral 2"
) async -> FakePeripheral {
    let peripheral = FakePeripheral(identifier: identifier, name: name, queue: fakeCentral.queue)
    await fakeCentral.onQueue {
        fakeCentral.retrievablePeripherals[identifier] = peripheral
    }
    return peripheral
}

/// Polls `condition` until it is `true` or a long timeout ends. After a timeout the test's
/// assertions report the actual failure.
func waitFor(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
