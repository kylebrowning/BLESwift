//
//  ThrowingBroadcaster.swift
//  BLESwift
//

import Synchronization

/// The throwing counterpart to ``Broadcaster``: a multicast primitive that fans out each
/// ``yield(_:)``ed `Element` to every currently subscribed `AsyncThrowingStream`, and can
/// ``finish(throwing:)`` every subscriber with an error.
///
/// Exists because notification streams MUST be able to finish with
/// ``BLESwiftError/unexpectedDisconnect``/decode errors, while ``Broadcaster`` is
/// `AsyncStream`-based and structurally cannot carry a terminal error. Modeled directly on
/// `Broadcaster`: the same `Mutex`-guarded state (rather than actor confinement, so
/// `onTermination` — which fires on an arbitrary thread — can unregister synchronously
/// without an actor hop), the same tokened continuation registry, and the same
/// lock-then-callback-after-release discipline on the finish path (see ``finish(throwing:)``).
///
/// Unlike `Broadcaster` there are no replay modes: BLESwift's one use for this type is the raw
/// notification multicast, and notifications are live-only — there is no meaningful
/// "current value" for a late subscriber to learn. One deliberate difference from
/// `Broadcaster`'s post-finish behavior: a stream created *after* ``finish(throwing:)``
/// finishes immediately **with the same terminal error** (a `Broadcaster` finishes late
/// streams cleanly) — for an error-carrying stream, silently ending a late subscriber would
/// hide the very failure this type exists to deliver.
final class ThrowingBroadcaster<Element: Sendable>: Sendable {

    /// All of a `ThrowingBroadcaster`'s mutable state, guarded as one unit by
    /// ``ThrowingBroadcaster/box``.
    private struct State {
        /// Live subscribers, keyed by a monotonically increasing token so
        /// `onTermination` can remove exactly the continuation it was handed.
        var continuations: [UInt64: AsyncThrowingStream<Element, Error>.Continuation] = [:]
        /// The next token to hand out.
        var nextToken: UInt64 = 0
        /// Set by ``finish(throwing:)``; once `true`, new subscribers are immediately
        /// finished (with ``terminalError``) and ``yield(_:)`` is a no-op.
        var finished = false
        /// The error ``finish(throwing:)`` was called with, if any — replayed as the
        /// immediate terminal error of any stream created after finishing.
        var terminalError: Error?
    }

    private let box = Mutex<State>(State())

    /// Creates an empty, unfinished `ThrowingBroadcaster`.
    init() {}

    /// Returns a fresh `AsyncThrowingStream` subscribed to every future ``yield(_:)``.
    ///
    /// Cancelling the stream's consuming task — or otherwise letting the stream's iterator
    /// deinit — unregisters it via `onTermination`; no explicit unsubscribe call is needed.
    /// If this broadcaster has already ``finish(throwing:)``ed, the returned stream
    /// finishes immediately with the same terminal error (or cleanly, if it finished
    /// without one).
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
                // Outside the lock, mirroring `Broadcaster` — `finish(throwing:)` on a
                // continuation synchronously invokes its `onTermination` (none installed
                // yet here, but the discipline is uniform: never finish under `box`'s lock).
                continuation.finish(throwing: registration.terminalError)
                return
            }

            continuation.onTermination = { [weak self] _ in
                _ = self?.box.withLock { $0.continuations.removeValue(forKey: token) }
            }
        }
    }

    /// Fans `element` out to every currently subscribed stream. A no-op after
    /// ``finish(throwing:)``.
    ///
    /// Safe to call while holding no other locks; `yield` on a live continuation never
    /// re-enters `onTermination` (unlike `finish`), so fanning out under `box`'s lock is
    /// sound — the same reasoning as `Broadcaster.yield(_:)`.
    func yield(_ element: Element) {
        box.withLock { state in
            guard !state.finished else { return }
            for continuation in state.continuations.values {
                continuation.yield(element)
            }
        }
    }

    /// Finishes every currently subscribed stream — throwing `error`, or cleanly if `nil`.
    /// Every stream created after this call finishes immediately the same way. Idempotent:
    /// the first call's `error` wins; later calls are no-ops.
    func finish(throwing error: Error? = nil) {
        // `AsyncThrowingStream.Continuation.finish(throwing:)` synchronously invokes that
        // continuation's `onTermination` handler on the calling thread — which, for a
        // continuation this broadcaster handed out, re-enters `box.withLock` (see
        // `stream(policy:)`). `Mutex` is not reentrant, so finishing under the lock would
        // deadlock/abort (the `Broadcaster` reentrancy lesson). So: pull the continuations
        // out (and mark `finished`/record the terminal error) under the lock, then finish
        // each one only after the lock has been released.
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
