//
//  ThrowingBroadcasterTests.swift
//  BLESwiftTests
//

import Dispatch
import BLESwiftCompat17
import Testing
import BLESwiftCore
@testable import BLESwift

/// Tests ``ThrowingBroadcaster`` alone. The tests mirror `BroadcasterTests` where that applies:
/// multicast fan-out, unregistration at cancellation, and the buffering policy. There are no replay
/// modes to mirror. The tests also cover the cases that finish with an error, which is why this
/// type exists. The notification engine multicasts raw `Data` through it, so every notification
/// stream depends on it.
@Suite("ThrowingBroadcaster")
struct ThrowingBroadcasterTests {

    @Test("Multiple concurrent subscribers each see every yielded element, in order")
    func multiConsumerSeesAllElements() async throws {
        let broadcaster = ThrowingBroadcaster<Int>()

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

        let (result1, result2) = try await (collected1, collected2)
        #expect(result1 == [1, 2, 3])
        #expect(result2 == [1, 2, 3])
    }

    @Test("A late subscriber sees nothing yielded before it subscribed (live-only, no replay)")
    func lateSubscriberSeesNothingPast() async throws {
        let broadcaster = ThrowingBroadcaster<Int>()

        broadcaster.yield(1)
        broadcaster.yield(2)

        let stream = broadcaster.stream()
        async let collected = collect(stream, count: 1)

        await Task.yield()
        broadcaster.yield(3)
        broadcaster.finish()

        #expect(try await collected == [3])
    }

    @Test("Cancelling a subscriber's task unregisters it; the broadcaster stays functional for others")
    func cancellationUnregisters() async throws {
        let broadcaster = ThrowingBroadcaster<Int>()
        let stream = broadcaster.stream()

        let task = Task {
            var received: [Int] = []
            do {
                for try await value in stream {
                    received.append(value)
                }
            } catch {}
            return received
        }

        broadcaster.yield(1)
        // Wait until the test observes the value, then cancel. This avoids a race between "the task
        // starts to consume" and "cancel".
        try? await Task.sleep(for: .milliseconds(20))

        task.cancel()
        let received = await task.value
        #expect(received == [1])

        let secondStream = broadcaster.stream()
        async let secondCollected = collect(secondStream, count: 1)
        await Task.yield()
        broadcaster.yield(2)
        broadcaster.finish()

        #expect(try await secondCollected == [2])
    }

    @Test("finish() (no error) ends every currently-subscribed stream cleanly")
    func finishEndsAllStreamsCleanly() async {
        let broadcaster = ThrowingBroadcaster<Int>()

        let stream1 = broadcaster.stream()
        let stream2 = broadcaster.stream()

        async let error1 = terminalError(of: stream1)
        async let error2 = terminalError(of: stream2)

        await Task.yield()
        broadcaster.finish()

        let (result1, result2) = await (error1, error2)
        #expect(result1 == nil)
        #expect(result2 == nil)
    }

    @Test("finish(throwing:) delivers the error to every subscriber")
    func finishThrowingDeliversErrorToEverySubscriber() async {
        let broadcaster = ThrowingBroadcaster<Int>()

        let stream1 = broadcaster.stream()
        let stream2 = broadcaster.stream()

        async let error1 = terminalError(of: stream1)
        async let error2 = terminalError(of: stream2)

        await Task.yield()
        broadcaster.yield(1)
        broadcaster.finish(throwing: BLESwiftError.unexpectedDisconnect)

        let (result1, result2) = await (error1, error2)
        #expect(result1 as? BLESwiftError == .unexpectedDisconnect)
        #expect(result2 as? BLESwiftError == .unexpectedDisconnect)
    }

    @Test("finish(throwing:) then stream(): a late subscriber finishes immediately with the same terminal error")
    func streamAfterFinishThrowingReplaysTerminalError() async {
        let broadcaster = ThrowingBroadcaster<Int>()
        broadcaster.finish(throwing: BLESwiftError.explicitDisconnect)

        let stream = broadcaster.stream()
        let error = await terminalError(of: stream)
        #expect(error as? BLESwiftError == .explicitDisconnect)
    }

    @Test("finish() (no error) then stream(): a late subscriber finishes immediately, cleanly, with no elements")
    func streamAfterCleanFinishFinishesImmediately() async throws {
        let broadcaster = ThrowingBroadcaster<Int>()
        broadcaster.yield(1)
        broadcaster.finish()

        let stream = broadcaster.stream()
        var received: [Int] = []
        for try await value in stream {
            received.append(value)
        }
        #expect(received.isEmpty)
    }

    @Test("A second finish(throwing:) is a no-op: the first terminal error wins")
    func firstFinishWins() async {
        let broadcaster = ThrowingBroadcaster<Int>()
        broadcaster.finish(throwing: BLESwiftError.unexpectedDisconnect)
        broadcaster.finish(throwing: BLESwiftError.explicitDisconnect)

        let stream = broadcaster.stream()
        let error = await terminalError(of: stream)
        #expect(error as? BLESwiftError == .unexpectedDisconnect)
    }

    @Test(".bufferingNewest(1) drops older buffered elements when the consumer is slow")
    func bufferingNewestDropsOlderElements() async throws {
        let broadcaster = ThrowingBroadcaster<Int>()
        let stream = broadcaster.stream(policy: .bufferingNewest(1))

        // Yield synchronously before any consumer iterates. All three elements go into the stream's
        // internal buffer, where the buffering policy applies.
        broadcaster.yield(1)
        broadcaster.yield(2)
        broadcaster.yield(3)
        broadcaster.finish()

        var received: [Int] = []
        for try await value in stream {
            received.append(value)
        }

        #expect(received == [3])
    }

    /// Collects exactly `count` elements from `stream`, then returns without waiting for the stream
    /// to finish. The stream can still have a live producer.
    private func collect(_ stream: AsyncThrowingStream<Int, Error>, count: Int) async throws -> [Int] {
        var results: [Int] = []
        var iterator = stream.makeAsyncIterator()
        while results.count < count, let value = try await iterator.next() {
            results.append(value)
        }
        return results
    }

    /// Drains `stream` to its end and returns the error it finished with, if any.
    private func terminalError(of stream: AsyncThrowingStream<Int, Error>) async -> Error? {
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }

    @Test("Stress: yielding while subscribers cancel never deadlocks")
    func concurrentYieldAndCancellationDoNotDeadlock() async {
        // Mirrors the `Broadcaster` regression test for the same lock-order inversion. `yield(_:)`
        // must not hold this broadcaster's `Mutex` across `AsyncThrowingStream.Continuation.yield`.
        // That call can resume a suspended consumer, which takes the consumer task's status lock. A
        // concurrent cancellation holds that status lock and enters the `Mutex` again from
        // `onTermination`.
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
            let broadcaster = ThrowingBroadcaster<Int>()

            // Steady subscribers stay suspended most of the time, so each fan-out resumes them one
            // after another. This is the half of the inversion that touches the consumers' status
            // locks.
            let steady = (0..<8).map { _ -> Task<Void, Error> in
                let stream = broadcaster.stream()
                return Task.detached {
                    for try await _ in stream {}
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
                            for try await _ in stream {}
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

        #expect(finished, "ThrowingBroadcaster.yield deadlocked against subscriber cancellation")
    }

}
