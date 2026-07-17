//
//  BroadcasterTests.swift
//  BLESwiftTests
//

import Testing
@testable import BLESwift

/// Exercises ``Broadcaster`` in isolation: multicast fan-out, every ``ReplayMode``, and
/// `AsyncStream.Continuation.BufferingPolicy` handling. `Central`'s own state stream reuses
/// this primitive (see `CentralTests`), so correctness here is load-bearing for the whole
/// event-fan-out story.
@Suite("Broadcaster")
struct BroadcasterTests {

    @Test("Multiple concurrent subscribers each see every yielded element, in order")
    func multiConsumerSeesAllElements() async {
        let broadcaster = Broadcaster<Int>(replay: .none)

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
        await Task.yield() // let the first subscriber register (and drain replay) first

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

        // First consumer registers (draining and clearing the buffer), receives one live
        // element, then terminates.
        let firstStream = broadcaster.stream()
        async let firstCollected = collect(firstStream, count: 3)
        await Task.yield()
        broadcaster.yield(3) // live for the first consumer; must NOT be buffered
        #expect(await firstCollected == [1, 2, 3])

        // A later subscriber gets no replay of anything — not the original backlog
        // (cleared at first registration) and not the post-registration yield (never
        // buffered) — only what is yielded live from here on.
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

        // The first (and only) consumer drains the backlog and terminates, leaving the
        // broadcaster with zero live continuations — the previous implementation treated
        // the next subscriber as a "first consumer" again and re-replayed history.
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
        // Wait for the value to be observed before cancelling, so this isn't a race
        // between "task starts consuming" and "cancel".
        try? await Task.sleep(for: .milliseconds(20))

        task.cancel()
        let received = await task.value
        #expect(received == [1])

        // A second subscriber proves the broadcaster itself is still alive and
        // functional after the first unregistered; if `onTermination` had failed to
        // remove the cancelled continuation from the broadcaster's dictionary, this
        // would still pass (the stale entry is silently ignored by `yield`), so the real
        // proof of unregistration is indirect — but this at minimum confirms cancellation
        // didn't corrupt or hang the broadcaster.
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

        // Yield synchronously before any consumer iterates, so all three elements land in
        // the stream's internal buffer, where the buffering policy applies.
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

    /// Collects exactly `count` elements from `stream`, then returns without waiting for
    /// it to finish (the stream may still have a live producer).
    private func collect(_ stream: AsyncStream<Int>, count: Int) async -> [Int] {
        var results: [Int] = []
        var iterator = stream.makeAsyncIterator()
        while results.count < count, let value = await iterator.next() {
            results.append(value)
        }
        return results
    }
}
