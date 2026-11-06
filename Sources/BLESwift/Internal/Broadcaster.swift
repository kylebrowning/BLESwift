//
//  Broadcaster.swift
//  BLESwift
//

import BLESwiftCompat17

/// How a ``Broadcaster`` replays earlier elements (see ``yield(_:)``) to a later stream.
enum ReplayMode: Sendable {

    /// New subscribers see only the elements that are yielded after they subscribe.
    case none

    /// New subscribers first receive the most recent element, if any. Then they see every
    /// later element. Use it for state streams, where a late subscriber must learn the
    /// current value.
    case latest

    /// The first subscriber receives every element yielded so far, in order, and then every
    /// later element. When it registers, the broadcaster clears the replay buffer and stops
    /// buffering for good. Later subscribers behave as with ``none``. Use it for
    /// buffered-replay event streams, such as background restoration, where exactly one
    /// consumer drains the backlog.
    case allUntilFirstConsumer
}

/// A multicast primitive. It fans out each `Element` that code yields (see ``yield(_:)``) to
/// every subscribed `AsyncStream`, with a configurable replay for late subscribers.
/// `AsyncStream` itself supports only one consumer.
///
/// A `Mutex` guards the state, not actor confinement, because `onTermination` runs on an
/// arbitrary thread and must unregister its continuation synchronously.
final class Broadcaster<Element: Sendable>: Sendable {

    /// All the mutable state of a `Broadcaster`, guarded as one unit by ``Broadcaster/box``.
    private struct State {
        /// Live subscribers. The key is an increasing token, so `onTermination` removes exactly
        /// its own continuation.
        var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
        /// The next token to give out.
        var nextToken: UInt64 = 0
        /// Replay history, as ``ReplayMode`` specifies:
        ///
        /// - `.none`: not used.
        /// - `.latest`: at most one element.
        /// - `.allUntilFirstConsumer`: every element yielded *until the first subscriber
        ///   registers*. The first subscriber drains it, and it is never filled again (see
        ///   ``replayConsumed``).
        var replayBuffer: [Element] = []
        /// `.allUntilFirstConsumer` only: set when the first subscriber registers and drains
        /// the replay buffer. After that, `yield(_:)` does not buffer and later subscribers get
        /// no replay, even if every earlier consumer has terminated.
        var replayConsumed = false
        /// Set by ``finish()``. New subscribers then finish immediately and ``yield(_:)`` does
        /// nothing.
        var finished = false
    }

    private let replay: ReplayMode
    private let box: Mutex<State>

    /// Creates a `Broadcaster` with the given replay policy for late subscribers.
    init(replay: ReplayMode) {
        self.replay = replay
        self.box = Mutex(State())
    }

    /// Returns a new `AsyncStream` that is subscribed to every future ``yield(_:)``. It
    /// replays as this broadcaster's ``ReplayMode`` specifies.
    ///
    /// `onTermination` unregisters the stream when its consuming task is cancelled or its
    /// iterator deinitializes. If this broadcaster already ran ``finish()``, the stream
    /// finishes immediately and yields nothing.
    func stream(policy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: policy) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let token = self.box.withLock { state -> UInt64? in
                if state.finished {
                    return nil
                }

                switch self.replay {
                case .none:
                    break
                case .latest:
                    if let last = state.replayBuffer.last {
                        continuation.yield(last)
                    }
                case .allUntilFirstConsumer:
                    if !state.replayConsumed {
                        for element in state.replayBuffer {
                            continuation.yield(element)
                        }
                        state.replayBuffer.removeAll()
                        state.replayConsumed = true
                    }
                }

                let token = state.nextToken
                state.nextToken += 1
                state.continuations[token] = continuation
                return token
            }

            guard let token else {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                _ = self?.box.withLock { $0.continuations.removeValue(forKey: token) }
            }
        }
    }

    /// Fans `element` out to every subscribed stream. As ``ReplayMode`` specifies, it also
    /// records the element for future subscribers. It does nothing after ``finish()``.
    ///
    /// The replay bookkeeping runs under the lock. The fan-out runs *outside* it. A yield to a
    /// continuation that was removed meanwhile is harmless, because `AsyncStream` drops values
    /// after termination.
    func yield(_ element: Element) {
        // `continuation.yield` takes the consuming task's status lock. A concurrent cancellation
        // of that task holds the status lock and then enters `box.withLock` through
        // `onTermination`. Yielding under the lock would invert the lock order and deadlock.
        // So take a snapshot under the lock and deliver after releasing it. `finish()` does the
        // same. The snapshot keeps the per-caller order, which is the only order we guarantee.
        let targets: [AsyncStream<Element>.Continuation] = box.withLock { state in
            guard !state.finished else { return [] }

            switch replay {
            case .none:
                break
            case .latest:
                state.replayBuffer = [element]
            case .allUntilFirstConsumer:
                if !state.replayConsumed {
                    state.replayBuffer.append(element)
                }
            }

            return Array(state.continuations.values)
        }

        for continuation in targets {
            continuation.yield(element)
        }
    }

    /// Finishes every subscribed stream. A stream that is created later finishes immediately
    /// and yields nothing. It is idempotent.
    func finish() {
        // `continuation.finish()` re-enters `box.withLock` synchronously through `onTermination`
        // (see `stream(policy:)`), and `Mutex` is not reentrant. So take the continuations out
        // under the lock and finish them after releasing it.
        let continuationsToFinish: [AsyncStream<Element>.Continuation] = box.withLock { state in
            guard !state.finished else { return [] }
            state.finished = true
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }

        for continuation in continuationsToFinish {
            continuation.finish()
        }
    }
}
