//
//  QueueExecutorTests.swift
//  BLESwiftCompat16Tests
//

import Dispatch
import Foundation
import Testing
@_spi(Testing) import BLESwiftCompat16

@Suite("BLESwiftCompat16.QueueExecutor")
struct QueueExecutorTests {

    @Test("selects the platform serial-queue executor on the 17 tier by default")
    func modernByDefault() {
        let executor = QueueExecutor(queue: DispatchQueue(label: "compat16.tests.modern"), forceCompat16: false)
        if #available(iOS 17, macOS 14, watchOS 10, tvOS 17, visionOS 1, *) {
            #expect(!executor.usesCompat16Executor)
        } else {
            #expect(executor.usesCompat16Executor)
        }
    }

    @Test("forceCompat16 selects SerialQueueExecutor on every OS")
    func forced() {
        let executor = QueueExecutor(queue: DispatchQueue(label: "compat16.tests.forced"), forceCompat16: true)
        #expect(executor.usesCompat16Executor)
    }

    @Test("ExecutorPolicy.forceCompat16 mirrors BLESWIFT_FORCE_COMPAT16_EXECUTOR")
    func policyReadsEnvironment() {
        let env = ProcessInfo.processInfo.environment["BLESWIFT_FORCE_COMPAT16_EXECUTOR"]
        #expect(ExecutorPolicy.forceCompat16 == (env == "1"))
    }

    @Test("an actor works identically under both selections")
    func actorUnderBoth() async {
        for force in [false, true] {
            let a = SelectingActor(queue: DispatchQueue(label: "compat16.tests.both"), force: force)
            for n in 0..<100 { await a.append(n) }
            #expect(await a.values.count == 100)
            await a.assertOnQueue()
        }
    }

    #if os(macOS)
    @Test("a concurrent queue is rejected on the 17 tier")
    func concurrentQueueTraps() async {
        guard #available(macOS 14, *) else { return }
        await #expect(processExitsWith: .failure) {
            _ = QueueExecutor(queue: DispatchQueue(label: "c", attributes: .concurrent), forceCompat16: false)
        }
    }
    #endif
}

actor SelectingActor {
    nonisolated let executor: QueueExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var values: [Int] = []
    init(queue: DispatchQueue, force: Bool) { executor = QueueExecutor(queue: queue, forceCompat16: force) }
    func append(_ n: Int) { values.append(n) }
    func assertOnQueue() { dispatchPrecondition(condition: .onQueue(executor.queue)) }
}
