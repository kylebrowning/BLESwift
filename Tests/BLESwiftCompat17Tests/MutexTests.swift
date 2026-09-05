//
//  MutexTests.swift
//  BLESwiftCompat17Tests
//

import Foundation
import Testing
import BLESwiftCompat17

@Suite("BLESwiftCompat17.Mutex")
struct MutexTests {

    /// `Mutex` is `~Copyable`, so a concurrent closure borrows rather than copies a local one —
    /// which the compiler rejects, for this shim and for `Synchronization.Mutex` alike. Shared
    /// mutexes are reached through a reference type instead, as production code does.
    private final class Counter: Sendable {
        let value = Mutex<Int>(0)
    }

    @Test("withLock serialises 100 tasks × 1000 increments to exactly 100 000")
    func exclusivityUnderContention() async {
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    for _ in 0..<1000 { counter.value.withLock { $0 += 1 } }
                }
            }
        }
        #expect(counter.value.withLock { $0 } == 100_000)
    }

    @Test("withLock returns the closure's value")
    func withLockReturnsValue() {
        let box = Mutex<[String]>(["a"])
        let joined = box.withLock { $0.append("b"); return $0.joined() }
        #expect(joined == "ab")
    }

    @Test("withLockIfAvailable is nil while held elsewhere and a value when free")
    func withLockIfAvailable() {
        let box = Mutex<Int>(1)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Thread {
            box.withLock { _ in
                held.signal()
                release.wait()
            }
        }
        holder.start()
        held.wait()
        #expect(box.withLockIfAvailable { $0 } == nil)
        release.signal()
        // Spin briefly until the holder has released.
        var free: Int? = nil
        for _ in 0..<1000 where free == nil {
            free = box.withLockIfAvailable { $0 }
            if free == nil { usleep(100) }
        }
        #expect(free == 1, "lock never became available within ~100 ms")
    }

    struct Boom: Error {}

    @Test("an error thrown inside withLock propagates and releases the lock")
    func throwingReleases() {
        let box = Mutex<Int>(0)
        #expect(throws: Boom.self) {
            try box.withLock { _ in throw Boom() }
        }
        #expect(box.withLockIfAvailable { $0 } == 0)
    }

    @Test("a non-Sendable closure can be stored (compile-time check)")
    func storesNonSendableClosure() {
        final class NotSendable { var n = 0 }
        let box = Mutex<(() -> Int)?>(nil)
        let ns = NotSendable()
        box.withLock { $0 = { ns.n } }
        #expect(box.withLock { $0?() } == 0)
    }
}
