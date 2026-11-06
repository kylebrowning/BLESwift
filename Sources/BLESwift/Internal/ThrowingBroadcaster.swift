//
//  ThrowingBroadcaster.swift
//  BLESwift
//

import BLESwiftCompat17

/// The throwing counterpart to ``Broadcaster``. It fans out each `Element` that code yields
/// (see ``yield(_:)``) to every subscribed `AsyncThrowingStream`, and ``finish(throwing:)``
/// can end every subscriber with an error. Notification streams need this, and the
/// `AsyncStream`-based ``Broadcaster`` cannot do it. It uses the same `Mutex`-guarded state.
///
/// It differs from `Broadcaster` in two ways:
///
/// - It has no replay modes, because notifications are live-only.
/// - A stream that is created *after* ``finish(throwing:)`` finishes immediately **with the
///   same terminal error**. A clean end would hide the failure.
final class ThrowingBroadcaster<Element: Sendable>: Sendable {

    /// All the mutable state of a `ThrowingBroadcaster`, guarded as one unit by
    /// ``ThrowingBroadcaster/box``.
    private struct State {
        /// Live subscribers. The key is an increasing token, so `onTermination` removes exactly
        /// its own continuation.
        var continuations: [UInt64: AsyncThrowingStream<Element, Error>.Continuation] = [:]
        /// The next token to give out.
        var nextToken: UInt64 = 0
        /// Set by ``finish(throwing:)``. New subscribers then finish immediately, with
        /// ``terminalError``, and ``yield(_:)`` does nothing.
        var finished = false
        /// The error that ``finish(throwing:)`` received, if any. A stream that is created
        /// after the finish ends with it.
        var terminalError: Error?
    }

    private let box = Mutex<State>(State())

    /// Creates an empty `ThrowingBroadcaster` that is not finished.
    init() {}

    /// Returns a new `AsyncThrowingStream` that is subscribed to every future ``yield(_:)``.
    ///
    /// `onTermination` unregisters the stream when its consuming task is cancelled or its
    /// iterator deinitializes. If this broadcaster already ran ``finish(throwing:)``, the
    /// stream finishes immediately with the same terminal error, or cleanly if there was none.
    func stream(
        policy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream(bufferingPolicy: policy) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let registration = self.box.withLock { state -> (token: UInt64?, terminalError: Error?) in
                if state.finished {
                    return (nil, state.terminalError)
                }
                let token = state.nextToken
                state.nextToken += 1
                state.continuations[token] = continuation
                return (token, nil)
            }

            guard let token = registration.token else {
                // Finish outside the lock, as in `Broadcaster`.
                continuation.finish(throwing: registration.terminalError)
                return
            }

            continuation.onTermination = { [weak self] _ in
                _ = self?.box.withLock { $0.continuations.removeValue(forKey: token) }
            }
        }
    }

    /// Fans `element` out to every stream that is subscribed now. It does nothing after
    /// ``finish(throwing:)``.
    ///
    /// As in `Broadcaster.yield(_:)`, the fan-out runs *outside* the lock. A yield to a
    /// continuation that was removed meanwhile is harmless, because `AsyncThrowingStream`
    /// drops values after termination.
    func yield(_ element: Element) {
        // Same lock-order inversion as `Broadcaster.yield(_:)`: do not yield under the lock.
        let targets: [AsyncThrowingStream<Element, Error>.Continuation] = box.withLock { state in
            guard !state.finished else { return [] }
            return Array(state.continuations.values)
        }

        for continuation in targets {
            continuation.yield(element)
        }
    }

    /// Finishes every subscribed stream with `error`, or cleanly if `error` is `nil`. A stream
    /// that is created later finishes immediately in the same way. It is idempotent. The first
    /// call's `error` wins.
    func finish(throwing error: Error? = nil) {
        // Same reentrancy hazard as `Broadcaster.finish()`: finish the continuations after the
        // lock is released.
        let continuationsToFinish: [AsyncThrowingStream<Element, Error>.Continuation] = box.withLock { state in
            guard !state.finished else { return [] }
            state.finished = true
            state.terminalError = error
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }

        for continuation in continuationsToFinish {
            continuation.finish(throwing: error)
        }
    }
}
