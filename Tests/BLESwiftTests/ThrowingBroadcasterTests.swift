//
//  ThrowingBroadcasterTests.swift
//  BLESwiftTests
//

import Dispatch
import Testing
import BLESwiftCore
@testable import BLESwift

/// Exercises ``ThrowingBroadcaster`` in isolation, mirroring `BroadcasterTests` where
/// applicable (multicast fan-out, cancellation unregistration, buffering policy — there
/// are no replay modes to mirror) plus the finish-with-error cases that are this type's
/// entire reason to exist. The Phase 7 notification engine multicasts raw `Data` through
/// this primitive, so correctness here is load-bearing for every notification stream.
@Suite("ThrowingBroadcaster")
struct ThrowingBroadcasterTests {

    @Test("Multiple concurrent subscribers each see every yielded element, in order")
    func multiConsumerSeesAllElements() async throws {
        let broadcaster = ThrowingBroadcaster<Int>()

        let stream1 = broadcaster.stream()
        let stream2 = broadcaster.stream()

        async let collected1 = collect(stream1, count: 3)
        async let collected2 = collect(stream2, count: 3)

        // Give both `for await` loops a chance to start iterating before yielding —
        // otherwise a yield could race ahead of a subscriber's first `next()` call.
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
        // Wait for the value to be observed before cancelling, so this isn't a race
        // between "task starts consuming" and "cancel".
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

        // Yield synchronously before any consumer iterates, so all three elements land in
        // the stream's internal buffer, where the buffering policy applies.
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

    /// Collects exactly `count` elements from `stream`, then returns without waiting for
    /// it to finish (the stream may still have a live producer).
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
    func concurrentYieldAndCancellationDoNotDeadlock() {
        // Mirrors the `Broadcaster` regression test for the same lock-order inversion:
        // `yield(_:)` must not hold this broadcaster's `Mutex` across
        // `AsyncThrowingStream.Continuation.yield`, which — when it resumes a suspended
        // consumer — takes that consumer task's status lock, while a concurrent cancellation
        // holds that status lock and re-enters the `Mutex` from `onTermination`.
        //
        // A deadlock parks every cooperative thread rather than suspending tasks, so an
        // `await`-based watchdog would never be scheduled to notice it. The stress work runs
        // detached and signals a `DispatchSemaphore`; this test blocks on that semaphore with
        // a deadline, so the inversion surfaces as a failed expectation, not a hung suite.
        let finishedSignal = DispatchSemaphore(value: 0)

        let stress = Task.detached {
            let broadcaster = ThrowingBroadcaster<Int>()

            // Steady subscribers spend most of their time suspended, so each fan-out
            // resumes them one after another — the half of the inversion that touches
            // consumer status locks.
            let steady = (0..<8).map { _ in
                Task.detached {
                    for try await _ in broadcaster.stream() {}
                }
            }

            let producer = Task.detached {
                var iteration = 0
                while !Task.isCancelled {
                    broadcaster.yield(iteration)
                    iteration += 1
                    // Let the consumers drain and suspend again before the next fan-out.
                    await Task.yield()
                }
            }

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        for _ in 0..<150 {
                            let consumer = Task.detached {
                                for try await _ in broadcaster.stream() {}
                            }
                            await Task.yield()
                            // Cancelling a consumer that is very likely suspended awaiting
                            // the producer: cancellation runs `onTermination` synchronously,
                            // under that consumer's status lock, on this thread.
                            consumer.cancel()
                            _ = try? await consumer.value
                        }
                    }
                }
            }

            producer.cancel()
            await producer.value
            for task in steady {
                task.cancel()
            }
            for task in steady {
                _ = try? await task.value
            }
            broadcaster.finish()
            finishedSignal.signal()
        }

        let finished = finishedSignal.wait(timeout: .now() + 10) == .success
        stress.cancel()

        #expect(finished, "ThrowingBroadcaster.yield deadlocked against subscriber cancellation")
    }

}
