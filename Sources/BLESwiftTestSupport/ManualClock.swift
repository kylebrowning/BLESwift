//
//  ManualClock.swift
//  BLESwiftTestSupport
//

import BLESwiftCompat17

/// A `Clock` that moves only when a test tells it to.
///
/// Hand one to `Configuration(clock:)` or `VirtualRadio(clock:)` and every timer behind
/// them — a connect timeout, a scan timeout, a reconnect backoff, a virtual device's
/// latency — sleeps on it instead of wall time. ``now`` stays put until ``advance(by:)``
/// moves it, which resumes every sleeper whose deadline it reached, so a 60-second timeout
/// is crossed, or missed by a millisecond, in no time at all and with no race.
///
/// The deterministic pattern is three steps: wait until the code under test has gone to
/// sleep, move the clock, then await the outcome.
///
/// ```swift
/// let clock = ManualClock()
/// let central = Central(backend: backend, queue: queue, configuration: Configuration(clock: clock))
/// let attempt = Task { try await central.connect(id, timeout: .seconds(30)) }
/// await clock.waitForSleepers(1)      // the timeout timer is parked
/// clock.advance(by: .seconds(30))     // and now it has fired
/// await #expect(throws: BLESwiftError.connectionTimedOut) { try await attempt.value }
/// ```
///
/// ``waitForSleepers(_:)`` is the step that makes it deterministic: ``advance(by:)`` resumes
/// only sleepers that are already suspended, so advancing before the code under test has
/// reached its `sleep` would move the clock past a deadline that nobody is waiting on yet.
/// It is woken by registration, never by polling.
///
/// `Mutex`-guarded, not queue-confined, like ``FakeStartupBackgroundTask``: a clock is slept
/// on from whatever task the code under test runs its timer in, and advanced from the test.
public final class ManualClock: Clock, Sendable {

    /// A point on a ``ManualClock``'s timeline: how far it has been advanced since it was
    /// created.
    public struct Instant: InstantProtocol, Sendable, Hashable {

        /// The distance from the clock's starting point.
        public var offset: Duration

        /// Creates an instant `offset` past the clock's starting point.
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

    /// One suspended `sleep`, keyed so a cancellation can find exactly it.
    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// One ``waitForSleepers(_:)`` call, parked until ``State/sleepers`` reaches `count`,
    /// keyed so a cancellation can find exactly it.
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
    }

    private let state = Mutex<State>(State())

    /// Creates a clock at its starting point, with nothing sleeping on it.
    public init() {}

    /// The current time: the sum of every ``advance(by:)`` so far.
    public var now: Instant {
        state.withLock { $0.now }
    }

    /// Zero — a manual clock resolves exactly the instants it is advanced to.
    public var minimumResolution: Duration { .zero }

    /// How many `sleep` calls are currently suspended on this clock.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Suspends until `deadline` is reached by ``advance(by:)``, or the task is cancelled.
    ///
    /// Returns at once for a deadline already reached, and throws `CancellationError` at once
    /// for a task already cancelled, registering no sleeper either way. Otherwise the sleeper
    /// is registered and resumed exactly once: by the ``advance(by:)`` that reaches its
    /// deadline, or — throwing `CancellationError` — by the cancellation that removes it. The
    /// lock is what decides which, so a cancel and an advance racing for the same sleeper
    /// cannot both resume it.
    ///
    /// - Parameters:
    ///   - deadline: The instant to sleep until.
    ///   - tolerance: Ignored; a manual clock has no scheduling slack.
    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        guard deadline > now else { return }
        try Task.checkCancellation()
        let id = state.withLock { (state: inout State) -> UInt64 in
            state.nextSleeperID += 1
            return state.nextSleeperID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Decided under the lock: whether the deadline has been reached since the check
                // above, whether the task was cancelled before the sleeper could be registered
                // — the handler below has then already run and found nothing to remove — and,
                // once registered, which waiters the new count satisfies.
                enum Outcome { case registered([Waiter]), elapsed, cancelled }
                let outcome = state.withLock { (state: inout State) -> Outcome in
                    if deadline <= state.now { return .elapsed }
                    if Task.isCancelled { return .cancelled }
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

    /// Moves ``now`` forward by `duration` and resumes every sleeper whose deadline is now
    /// reached, earliest deadline first (ties in the order they went to sleep).
    ///
    /// Synchronous: it only resumes the continuations, in that order. The resumed tasks then
    /// run concurrently, in no guaranteed order, so a test awaits the outcome it expects
    /// rather than assuming it has happened when this returns.
    ///
    /// - Parameter duration: How far to move the clock. Must not be negative.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "ManualClock cannot run backwards; got \(duration)")
        let due = state.withLock { (state: inout State) -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
        }
        // Resumed outside the lock: a resumed sleeper may go straight back to sleep on this
        // clock, and would take the lock to do it.
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Suspends until at least `count` sleepers are suspended on this clock.
    ///
    /// Returns at once when they already are. Otherwise it is woken by the registration
    /// that brings the count up to `count`, never by polling — which is what lets a test
    /// advance the clock only once the code under test has really gone to sleep. Cancelling
    /// the waiting task returns early (it does not throw), exactly once, under the same lock
    /// discipline as ``sleep(until:tolerance:)``; the sleepers are untouched.
    ///
    /// - Parameter count: How many sleepers to wait for.
    public func waitForSleepers(_ count: Int) async {
        let id = state.withLock { (state: inout State) -> UInt64 in
            state.nextWaiterID += 1
            return state.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Decided under the lock, as a sleeper's registration is: already satisfied,
                // cancelled before the waiter could be registered, or registered.
                let ready = state.withLock { (state: inout State) -> Bool in
                    if state.sleepers.count >= count || Task.isCancelled { return true }
                    state.waiters.append(Waiter(id: id, count: count, continuation: continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { (state: inout State) -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            cancelled?.continuation.resume()
        }
    }
}
