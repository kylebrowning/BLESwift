//
//  BroadcasterTests.swift
//  BLESwiftTests
//

import Dispatch
import BLESwiftCompat17
import Testing
import BLESwiftCore
@testable import BLESwift

/// Tests ``Broadcaster`` alone: the multicast fan-out, every ``ReplayMode``, and
/// `AsyncStream.Continuation.BufferingPolicy`. The `Central` state stream uses this primitive (see
/// `CentralTests`), so the whole event fan-out depends on it.
@Suite("Broadcaster")
struct BroadcasterTests {

    @Test("Multiple concurrent subscribers each see every yielded element, in order")
    func multiConsumerSeesAllElements() async {
        let broadcaster = Broadcaster<Int>(replay: .none)

        let stream1 = broadcaster.stream()
        let stream2 = broadcaster.stream()

        async let collected1 = collect(stream1, count: 3)
        async let collected2 = collect(stream2, count: 3)

        // Give both `for await` loops time to start iterating before the yield. Otherwise the yield
        // could run before a subscriber's first `next()` call.
        await Task.yield()
        await Task.yield()

        broadcaster.yield(1)
        broadcaster.yield(2)
        broadcaster.yield(3)
        broadcaster.finish()

        let (result1, result2) = await (collected1, collected2)
        #expect(result1 == [1, 2, 3])
        #expect(result2 == [1, 2, 3])
    }

    @Test(".none replay: a late subscriber sees nothing yielded before it subscribed")
    func noneReplaySeesNothingPast() async {
        let broadcaster = Broadcaster<Int>(replay: .none)

        broadcaster.yield(1)
        broadcaster.yield(2)

        let stream = broadcaster.stream()
        async let collected = collect(stream, count: 1)

        await Task.yield()
        broadcaster.yield(3)
        broadcaster.finish()

        #expect(await collected == [3])
    }

    @Test(".latest replay: a late subscriber immediately receives the most recent element, then live ones")
    func latestReplaySendsMostRecentValue() async {
        let broadcaster = Broadcaster<Int>(replay: .latest)

        broadcaster.yield(1)
        broadcaster.yield(2)

        let stream = broadcaster.stream()
        async let collected = collect(stream, count: 2)

        await Task.yield()
        broadcaster.yield(3)
        broadcaster.finish()

        #expect(await collected == [2, 3])
    }

    @Test(".latest replay: a subscriber before any yield receives nothing until the first live yield")
    func latestReplayWithNoHistoryYieldsNothingUpfront() async {
        let broadcaster = Broadcaster<Int>(replay: .latest)

        let stream = broadcaster.stream()
        async let collected = collect(stream, count: 1)

        await Task.yield()
        broadcaster.yield(42)
        broadcaster.finish()

        #expect(await collected == [42])
    }

    @Test(".allUntilFirstConsumer: the first subscriber replays the full backlog, then sees live elements")
    func allUntilFirstConsumerReplaysBacklogToFirstSubscriberOnly() async {
        let broadcaster = Broadcaster<Int>(replay: .allUntilFirstConsumer)

        broadcaster.yield(1)
        broadcaster.yield(2)

        let firstStream = broadcaster.stream()
        async let firstCollected = collect(firstStream, count: 3)

        await Task.yield()
        broadcaster.yield(3)
        broadcaster.finish()

        #expect(await firstCollected == [1, 2, 3])
    }

    @Test(".allUntilFirstConsumer: a second subscriber does not see the replayed backlog again")
    func allUntilFirstConsumerDoesNotReplayToSubsequentSubscribers() async {
        let broadcaster = Broadcaster<Int>(replay: .allUntilFirstConsumer)

        broadcaster.yield(1)
        broadcaster.yield(2)

        let firstStream = broadcaster.stream()
        async let firstCollected = collect(firstStream, count: 3)
        await Task.yield() // Let the first subscriber register and drain the replay first.

        let secondStream = broadcaster.stream()
        async let secondCollected = collect(secondStream, count: 1)
        await Task.yield()

        broadcaster.yield(3)
        broadcaster.finish()

        #expect(await firstCollected == [1, 2, 3])
        #expect(await secondCollected == [3])
    }

    @Test(".allUntilFirstConsumer: the buffer is cleared once the first consumer registers — later yields are not buffered")
    func allUntilFirstConsumerClearsBufferOnFirstConsumer() async {
        let broadcaster = Broadcaster<Int>(replay: .allUntilFirstConsumer)

        broadcaster.yield(1)
        broadcaster.yield(2)

        // The first consumer registers, drains and clears the buffer, receives one live element,
        // and terminates.
        let firstStream = broadcaster.stream()
        async let firstCollected = collect(firstStream, count: 3)
        await Task.yield()
        broadcaster.yield(3) // This element is live for the first consumer. The broadcaster must NOT buffer it.
        #expect(await firstCollected == [1, 2, 3])

        // A later subscriber gets no replay. It does not get the original backlog, because the
        // first registration cleared it. It does not get the yield after registration, because the
        // broadcaster never buffered it. It gets only elements yielded live from here on.
        let secondStream = broadcaster.stream()
        async let secondCollected = collect(secondStream, count: 1)
        await Task.yield()
        broadcaster.yield(4)
        broadcaster.finish()

        #expect(await secondCollected == [4])
    }

    @Test(".allUntilFirstConsumer: a subscriber arriving after every previous consumer terminated gets no replay")
    func allUntilFirstConsumerNoReplayAfterAllConsumersTerminate() async {
        let broadcaster = Broadcaster<Int>(replay: .allUntilFirstConsumer)

        broadcaster.yield(1)
        broadcaster.yield(2)

        // The first consumer, the only one, drains the backlog and terminates. The broadcaster then
        // has zero live continuations. The previous implementation treated the next subscriber as a
        // first consumer again and replayed the history.
        let firstStream = broadcaster.stream()
        let firstCollected = await collect(firstStream, count: 2)
        #expect(firstCollected == [1, 2])

        let secondStream = broadcaster.stream()
        async let secondCollected = collect(secondStream, count: 1)
        await Task.yield()
        broadcaster.yield(3)
        broadcaster.finish()

        #expect(await secondCollected == [3])
    }

    @Test("Cancelling a subscriber's task unregisters it: a later yield does not deliver to it")
    func cancellationUnregisters() async {
        let broadcaster = Broadcaster<Int>(replay: .none)
        let stream = broadcaster.stream()

        let task = Task {
            var received: [Int] = []
            for await value in stream {
                received.append(value)
            }
            return received
        }

        broadcaster.yield(1)
        // Wait until the task observes the value, then cancel. This avoids a race between "the task
        // starts to consume" and "cancel".
        try? await Task.sleep(for: .milliseconds(20))

        task.cancel()
        let received = await task.value
        #expect(received == [1])

        // A second subscriber proves that the broadcaster still works after the first unregistered.
        // The proof of unregistration is indirect: if `onTermination` did not remove the cancelled
        // continuation, the test would still pass, because `yield` ignores the stale entry. The
        // test does confirm that the cancellation did not corrupt or hang the broadcaster.
        let secondStream = broadcaster.stream()
        async let secondCollected = collect(secondStream, count: 1)
        await Task.yield()
        broadcaster.yield(2)
        broadcaster.finish()

        #expect(await secondCollected == [2])
    }

    @Test("finish() ends every currently-subscribed stream")
    func finishEndsAllStreams() async {
        let broadcaster = Broadcaster<Int>(replay: .none)

        let stream1 = broadcaster.stream()
        let stream2 = broadcaster.stream()

        async let iterator1Finished: Void = {
            for await _ in stream1 {}
        }()
        async let iterator2Finished: Void = {
            for await _ in stream2 {}
        }()

        await Task.yield()
        broadcaster.finish()

        await iterator1Finished
        await iterator2Finished
    }

    @Test("finish() then stream(): new subscribers finish immediately without yielding anything")
    func streamAfterFinishFinishesImmediately() async {
        let broadcaster = Broadcaster<Int>(replay: .latest)
        broadcaster.yield(1)
        broadcaster.finish()

        let stream = broadcaster.stream()
        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received.isEmpty)
    }

    @Test(".bufferingNewest(1) drops older buffered elements when the consumer is slow")
    func bufferingNewestDropsOlderElements() async {
        let broadcaster = Broadcaster<Int>(replay: .none)
        let stream = broadcaster.stream(policy: .bufferingNewest(1))

        // Yield synchronously before any consumer iterates. All three elements go into the stream's
        // internal buffer, where the buffering policy applies.
        broadcaster.yield(1)
        broadcaster.yield(2)
        broadcaster.yield(3)
        broadcaster.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == [3])
    }

    /// Collects exactly `count` elements from `stream`, then returns without waiting for the stream
    /// to finish. The stream can still have a live producer.
    private func collect(_ stream: AsyncStream<Int>, count: Int) async -> [Int] {
        var results: [Int] = []
        var iterator = stream.makeAsyncIterator()
        while results.count < count, let value = await iterator.next() {
            results.append(value)
        }
        return results
    }

    @Test("Stress: yielding while subscribers cancel never deadlocks")
    func concurrentYieldAndCancellationDoNotDeadlock() async {
        // Regression test for a lock-order inversion. `yield(_:)` must not hold the broadcaster's
        // `Mutex` across `AsyncStream.Continuation.yield`. That call can resume a suspended
        // consumer, which takes the consumer task's status lock. A concurrent cancellation of the
        // same consumer holds that status lock while it runs `onTermination`, which enters the
        // `Mutex` again.
        //
        // The test causes both actions at the same time:
        // - Subscribers stay suspended, so each fan-out resumes several consumers.
        // - Subscribe and cancel calls run continuously.
        //
        // Every call into the broadcaster (yield, subscribe, cancel) comes from a
        // `DispatchQueue.global()` thread. A blocking `DispatchSemaphore.wait` on one more such
        // thread enforces the deadline and returns the result through a continuation. No
        // cooperative thread is blocked, so the workload does not compete with the watchdog for the
        // pool. This matters with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, where the pool has one
        // thread, used only by the subscriber tasks, which only iterate.
        let finishedSignal = DispatchSemaphore(value: 0)
        let stopProducing = Mutex<Bool>(false)

        DispatchQueue.global().async {
            let broadcaster = Broadcaster<Int>(replay: .none)

            // Steady subscribers stay suspended most of the time, so each fan-out resumes them one
            // after another. This is the half of the inversion that touches the consumers' status
            // locks.
            let steady = (0..<8).map { _ -> Task<Void, Never> in
                let stream = broadcaster.stream()
                return Task.detached {
                    for await _ in stream {}
                }
            }

            let producing = DispatchGroup()
            DispatchQueue.global().async(group: producing) {
                var iteration = 0
                while !stopProducing.withLock({ $0 }) {
                    broadcaster.yield(iteration)
                    iteration += 1
                    // Let the consumers drain and suspend again before the next fan-out.
                    usleep(50)
                }
            }

            let churning = DispatchGroup()
            for _ in 0..<4 {
                DispatchQueue.global().async(group: churning) {
                    for _ in 0..<300 {
                        let stream = broadcaster.stream()
                        let consumer = Task.detached {
                            for await _ in stream {}
                        }
                        usleep(100)
                        // Cancel a consumer that is very likely suspended waiting for the producer.
                        // The cancellation runs `onTermination` synchronously on this thread, under
                        // that consumer's status lock.
                        consumer.cancel()
                    }
                }
            }

            churning.wait()
            stopProducing.withLock { $0 = true }
            producing.wait()
            for task in steady {
                task.cancel()
            }
            broadcaster.finish()
            finishedSignal.signal()
        }

        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: finishedSignal.wait(timeout: .now() + 10) == .success)
            }
        }

        #expect(finished, "Broadcaster.yield deadlocked against subscriber cancellation")
    }

}
