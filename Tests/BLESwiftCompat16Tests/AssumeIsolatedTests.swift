//
//  AssumeIsolatedTests.swift
//  BLESwiftCompat16Tests
//

import Dispatch
import Testing
@_spi(Testing) import BLESwiftCompat16

/// Bound through `QueueExecutor`, as `Central` and `PeripheralHost` are. `forceCompat16` defaults
/// to the 16-tier `SerialQueueExecutor`. If it is `false`, the actor takes the production path,
/// which is `DispatchSerialQueue`'s executor on the 17 tier and later.
actor Recorder {
    nonisolated let queue: DispatchQueue
    nonisolated let executor: QueueExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var events: [String] = []
    init(queue: DispatchQueue, forceCompat16: Bool = true) {
        self.queue = queue
        executor = QueueExecutor(queue: queue, forceCompat16: forceCompat16)
    }
    func record(_ s: String) { events.append(s) }

    /// Simulates a delegate callback that arrives on the queue outside any task.
    nonisolated func simulateCallback(_ s: String) {
        queue.async { self.assumeIsolated(onQueue: self.queue) { $0.record(s) } }
    }
}

@Suite("BLESwiftCompat16.assumeIsolated(onQueue:)")
struct AssumeIsolatedTests {

    @Test("runs synchronously on the queue and returns the closure's value")
    func returnsValue() async {
        let queue = DispatchQueue(label: "compat16.tests.assume")
        let recorder = Recorder(queue: queue)
        let value = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            queue.async {
                let v = recorder.assumeIsolated(onQueue: queue) { r in r.record("x"); return r.events.count }
                c.resume(returning: v)
            }
        }
        #expect(value == 1)
        #expect(await recorder.events == ["x"])
    }

    /// Runs under both executors: the forced 16-tier executor, and the production executor on the
    /// 17 tier and later (`DispatchSerialQueue`'s executor). Central's delegate callbacks take this
    /// path on every current OS.
    @Test("callbacks from the queue interleave in order with actor calls", arguments: [true, false])
    func ordering(forceCompat16: Bool) async {
        let queue = DispatchQueue(label: "compat16.tests.order")
        let recorder = Recorder(queue: queue, forceCompat16: forceCompat16)
        recorder.simulateCallback("a")
        await recorder.record("b")
        recorder.simulateCallback("c")
        await recorder.record("d")
        #expect(await recorder.events == ["a", "b", "c", "d"])
    }

    @Test("rethrows")
    func rethrowsFromClosure() async {
        struct Boom: Error {}
        let queue = DispatchQueue(label: "compat16.tests.throw")
        let recorder = Recorder(queue: queue)
        let threw = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async {
                do { try recorder.assumeIsolated(onQueue: queue) { _ in throw Boom() }; c.resume(returning: false) }
                catch { c.resume(returning: true) }
            }
        }
        #expect(threw)
    }

    #if os(macOS)
    @Test("traps when called off the queue")
    func trapsOffQueue() async {
        await #expect(processExitsWith: .failure) {
            let queue = DispatchQueue(label: "compat16.tests.trap")
            let recorder = Recorder(queue: queue)
            _ = recorder.assumeIsolated(onQueue: queue) { $0.events.count }
        }
    }
    #endif
}
