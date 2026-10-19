//
//  SerialQueueExecutorTests.swift
//  BLESwiftCompat16Tests
//

import Dispatch
import Testing
import BLESwiftCompat16

/// An actor whose isolation is the executor under test.
actor Counter {
    nonisolated let executor: SerialQueueExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var values: [Int] = []
    init(queue: DispatchQueue) { executor = SerialQueueExecutor(queue: queue) }
    func append(_ n: Int) { values.append(n) }
    func assertOnQueue() { dispatchPrecondition(condition: .onQueue(executor.queue)) }
}

@Suite("BLESwiftCompat16.SerialQueueExecutor")
struct SerialQueueExecutorTests {

    @Test("actor-isolated code runs on the executor's queue")
    func runsOnQueue() async {
        let counter = Counter(queue: DispatchQueue(label: "compat16.tests.runsOnQueue"))
        await counter.assertOnQueue()
    }

    @Test("10 000 jobs from one task keep FIFO order")
    func fifoFromOneTask() async {
        let counter = Counter(queue: DispatchQueue(label: "compat16.tests.fifo"))
        for n in 0..<10_000 { await counter.append(n) }
        #expect(await counter.values == Array(0..<10_000))
    }

    @Test("jobs from 50 concurrent tasks all land, none lost, none duplicated")
    func manyTasks() async {
        let counter = Counter(queue: DispatchQueue(label: "compat16.tests.many"))
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<50 {
                group.addTask { for i in 0..<200 { await counter.append(t * 200 + i) } }
            }
        }
        #expect(await counter.values.sorted() == Array(0..<10_000))
    }

    @Test("isolation holds after a suspension inside a Task")
    func taskHopsBack() async {
        let counter = Counter(queue: DispatchQueue(label: "compat16.tests.hop"))
        let done = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            Task {
                await counter.append(1)
                await counter.assertOnQueue()
                c.resume(returning: true)
            }
        }
        #expect(done)
    }

    // `checkIsolated()` is the only isolation check that works from a non-task context. The
    // method is declared at the module floor, but the runtime only consults it from the 18
    // tier up (Swift 6.0 runtimes; macOS 15 here). These two pin both of its answers.
    #if os(macOS)
    @Test("preconditionIsolated succeeds on the queue from a non-task context")
    func preconditionIsolatedOnQueue() async {
        guard #available(macOS 15, *) else { return }
        let queue = DispatchQueue(label: "compat16.tests.precondition")
        let counter = Counter(queue: queue)
        let returned = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async {
                counter.preconditionIsolated()
                c.resume(returning: true)
            }
        }
        #expect(returned)
    }

    @Test("preconditionIsolated traps off the queue")
    func preconditionIsolatedOffQueue() async {
        guard #available(macOS 15, *) else { return }
        await #expect(processExitsWith: .failure) {
            let counter = Counter(queue: DispatchQueue(label: "compat16.tests.preconditionTrap"))
            counter.preconditionIsolated()
        }
    }
    #endif
}
