//
//  TestHelpers.swift
//  BLESwiftTests
//

import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch
import Foundation

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
/// Uses `Central`'s public `init(backend:queue:configuration:startupBackgroundTask:connectedPeripherals:)`
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
        connectedPeripherals: adoptPeripheral ? [fakePeripheral] : []
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
    await fakeCentral.onQueue {
        fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
        fakeCentral.connectBehavior = .succeed
    }
    let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
    return (central, fakeCentral, fakePeripheral, peripheral)
}

/// Creates an additional `FakePeripheral` on the same queue as `fakeCentral` and registers
/// it as retrievable — the multi-peripheral test workhorse: feed the identifier it reports
/// to `central.connect(_:)`, which wires the peripheral's `eventHandler` (and so its GATT/
/// notification event delivery) itself, on initiation, exactly as it does for the primary
/// fake peripheral `makeTestCentral()` returns — no separate wiring step is needed here.
///
/// - Parameters:
///   - central: The `Central` this peripheral will eventually be connected through. Not
///     used to wire anything directly (see above); accepted so call sites read as
///     unambiguously "one more peripheral for this rig", matching `makeTestCentral()`'s own
///     shape.
///   - fakeCentral: The fake backing `central`, which the new peripheral is registered
///     retrievable on.
///   - identifier: The new peripheral's identifier. Defaults to a fresh `UUID`.
///   - name: The new peripheral's advertised/cached name.
/// - Returns: The newly created, already-registered `FakePeripheral`.
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

/// Polls `condition` until it's `true`, or a generous timeout elapses (the surrounding
/// test's own assertions then report the actual failure).
func waitFor(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
