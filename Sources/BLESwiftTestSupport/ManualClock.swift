//
//  ManualClock.swift
//  BLESwiftTestSupport
//

import BLESwiftCompat17

/// A `Clock` that moves only when a test tells it to.
///
/// Give a clock to `Configuration(clock:)` or `VirtualRadio(clock:)`. Every timer behind them
/// then sleeps on this clock and not on wall time. ``now`` stays the same until
/// ``advance(by:)`` moves it. ``advance(by:)`` then resumes every sleeper whose deadline it
/// reached. A test can cross a 60-second timeout, or miss it by a millisecond, instantly and
/// with no race.
///
/// - Important: ``advance(by:)`` resumes only the sleepers that are already suspended. Call
///   ``waitForSleepers(_:)`` first. If you advance before the code under test reaches its
///   `sleep`, the clock moves past a deadline that nobody waits on yet.
///
/// A `Mutex` guards the clock. No queue confines it.
/// See <doc:TestingYourBLECode#Testing-timeouts>.
public final class ManualClock: Clock, Sendable {

    /// A point on a ``ManualClock``'s timeline: the total time that the clock has advanced since
    /// its creation.
    public struct Instant: InstantProtocol, Sendable, Hashable {

        /// The distance from the clock's starting point.
        public var offset: Duration

        /// Creates an instant `offset` after the clock's starting point.
        public init(offset: Duration = .zero) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    /// One suspended `sleep`. Its `id` lets a cancellation find exactly this sleeper.
    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// One ``waitForSleepers(_:)`` call that waits until ``State/sleepers`` reaches `count`, or
    /// one ``waitForWaiters(_:)`` call that waits until ``State/waiters`` reaches `count`. Its `id`
    /// lets a cancellation find exactly this call.
    private struct Waiter {
        let id: UInt64
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant()
        var nextSleeperID: UInt64 = 0
        var nextWaiterID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []
        /// ``waitForWaiters(_:)`` calls that wait until ``waiters`` reaches their count. The `id`
        /// values come from the same counter as ``waiters``.
        var waiterWatchers: [Waiter] = []
    }

    private let state = Mutex<State>(State())

    /// Creates a clock at its starting point, with nothing that sleeps on it.
    public init() {}

    /// The current time: the sum of every ``advance(by:)`` so far.
    public var now: Instant {
        state.withLock { $0.now }
    }

    /// Zero. A manual clock resolves exactly the instants that it is advanced to.
    public var minimumResolution: Duration { .zero }

    /// The number of `sleep` calls that are now suspended on this clock.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// The number of ``waitForSleepers(_:)`` calls that are now suspended on this clock.
    ///
    /// This is not public API. It lets a test of the clock itself tell a registered waiter from
    /// one that returned, or was cancelled, before it could register.
    package var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    /// Suspends until ``advance(by:)`` reaches `deadline`, or until the task is cancelled.
    ///
    /// **Cancellation wins.** If the task is already cancelled, the function throws
    /// `CancellationError` at once, before it looks at the deadline, as `ContinuousClock` does. A
    /// zero-delay sleep on a cancelled task therefore throws here as it does on wall time. If the
    /// deadline is already reached, the function returns at once. In neither case does it register
    /// a sleeper.
    ///
    /// Otherwise the function registers the sleeper and resumes it exactly once:
    /// - The ``advance(by:)`` that reaches its deadline resumes it.
    /// - A cancellation removes and resumes it, and it throws `CancellationError`.
    ///
    /// The lock decides which of the two happens, so a cancel and an advance that race for the same
    /// sleeper cannot both resume it.
    ///
    /// - Parameters:
    ///   - deadline: The instant to sleep until.
    ///   - tolerance: Ignored. A manual clock has no scheduling slack.
    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        let id = state.withLock { (state: inout State) -> UInt64 in
            state.nextSleeperID += 1
            return state.nextSleeperID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Decide under the lock, in this order:
                // 1. Was the task cancelled before registration? The handler below already ran and
                //    found nothing to remove. Check this first so that cancellation wins, as above.
                // 2. Was the deadline reached since the check above?
                // 3. After registration, which waiters does the new count satisfy?
                enum Outcome { case registered([Waiter]), elapsed, cancelled }
                let outcome = state.withLock { (state: inout State) -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= state.now { return .elapsed }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    let count = state.sleepers.count
                    let satisfied = state.waiters.filter { $0.count <= count }
                    state.waiters.removeAll { $0.count <= count }
                    return .registered(satisfied)
                }
                switch outcome {
                case .registered(let satisfied):
                    for waiter in satisfied { waiter.continuation.resume() }
                case .elapsed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let cancelled = state.withLock { (state: inout State) -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves ``now`` forward by `duration` and resumes every sleeper whose deadline is now reached.
    /// The earliest deadline resumes first. Sleepers with the same deadline resume in the order
    /// that they went to sleep.
    ///
    /// This function is synchronous. It only resumes the continuations, in that order. The resumed
    /// tasks then run concurrently, in no guaranteed order. Await the outcome that you expect. Do
    /// not assume that it exists when this function returns.
    ///
    /// - Parameter duration: How far to move the clock. It must not be negative.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "ManualClock cannot run backwards; got \(duration)")
        let due = state.withLock { (state: inout State) -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
        }
        // Resume outside the lock. A resumed sleeper can sleep on this clock again at once, and
        // that takes the lock.
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Suspends until at least `count` sleepers are suspended on this clock.
    ///
    /// It returns at once if they already are. Otherwise the registration that brings the count up
    /// to `count` wakes it. It never polls, so a test can advance the clock only after the code
    /// under test has really gone to sleep. If the waiting task is cancelled, the function returns
    /// early and does not throw. It returns exactly once, under the same lock discipline as
    /// ``sleep(until:tolerance:)``, and leaves the sleepers unchanged.
    ///
    /// - Parameter count: The number of sleepers to wait for.
    public func waitForSleepers(_ count: Int) async {
        let id = state.withLock { (state: inout State) -> UInt64 in
            state.nextWaiterID += 1
            return state.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Decide under the lock, as for a sleeper: the condition already holds, the task
                // was cancelled before registration, or the waiter registers. After registration,
                // decide which ``waitForWaiters(_:)`` calls the new count satisfies.
                enum Outcome { case ready, registered([Waiter]) }
                let outcome = state.withLock { (state: inout State) -> Outcome in
                    if state.sleepers.count >= count || Task.isCancelled { return .ready }
                    state.waiters.append(Waiter(id: id, count: count, continuation: continuation))
                    let registered = state.waiters.count
                    let satisfied = state.waiterWatchers.filter { $0.count <= registered }
                    state.waiterWatchers.removeAll { $0.count <= registered }
                    return .registered(satisfied)
                }
                switch outcome {
                case .ready:
                    continuation.resume()
                case .registered(let satisfied):
                    for watcher in satisfied { watcher.continuation.resume() }
                }
            }
        } onCancel: {
            let cancelled = state.withLock { (state: inout State) -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            cancelled?.continuation.resume()
        }
    }

    /// Suspends until at least `count` ``waitForSleepers(_:)`` calls are suspended on this clock.
    /// It is ``waitForSleepers(_:)`` one level up. A waiter's registration wakes it, not a
    /// sleeper's. It never polls.
    ///
    /// This is not public API. A test of the clock itself uses it to cancel a waiter only after the
    /// waiter is registered. The test can then exercise the cancellation path that removes and
    /// resumes a registered waiter. That path differs from the check for a task that was cancelled
    /// before registration.
    ///
    /// If the watching task is cancelled, the function returns early and does not throw. It returns
    /// exactly once, under the same lock discipline as the waiters that it watches.
    ///
    /// - Parameter count: The number of waiters to wait for.
    package func waitForWaiters(_ count: Int) async {
        let id = state.withLock { (state: inout State) -> UInt64 in
            state.nextWaiterID += 1
            return state.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { (state: inout State) -> Bool in
                    if state.waiters.count >= count || Task.isCancelled { return true }
                    state.waiterWatchers.append(Waiter(id: id, count: count, continuation: continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { (state: inout State) -> Waiter? in
                guard let index = state.waiterWatchers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiterWatchers.remove(at: index)
            }
            cancelled?.continuation.resume()
        }
    }
}
