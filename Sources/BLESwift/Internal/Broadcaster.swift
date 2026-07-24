//
//  Broadcaster.swift
//  BLESwift
//

import Synchronization

/// How a ``Broadcaster`` replays previously-``yield(_:)``ed elements to a stream created
/// after those elements were yielded.
enum ReplayMode: Sendable {

    /// New subscribers see only elements yielded after they subscribe.
    case none

    /// New subscribers are immediately sent the most recently yielded element (if any),
    /// then see every element yielded after that. Used for state streams, where a late
    /// subscriber should still learn the current value.
    case latest

    /// The first subscriber (and only the first — ever) is sent every element yielded so
    /// far, in order, before seeing anything yielded after that live. The moment that
    /// first subscriber registers, the replay buffer is cleared and buffering stops for
    /// good — later subscribers see only elements yielded after they subscribe, as with
    /// ``none`` (this also bounds memory). Intended for buffered-replay event streams
    /// (e.g. background restoration) where exactly one consumer drains the backlog.
    case allUntilFirstConsumer
}

/// A multicast primitive: fans out each ``yield(_:)``ed `Element` to every currently
/// subscribed `AsyncStream`, with configurable replay semantics for late subscribers.
/// `AsyncStream` itself supports only one consumer; this is BLESwift's own multicast layer
/// built on top of it.
///
/// State is `Mutex`-guarded rather than actor-confined: `AsyncStream.Continuation`'s
/// `onTermination` handler fires on an arbitrary thread and must be able to unregister its
/// continuation synchronously, without an actor hop.
final class Broadcaster<Element: Sendable>: Sendable {

    /// All of a `Broadcaster`'s mutable state, guarded as one unit by ``Broadcaster/box``.
    private struct State {
        /// Live subscribers, keyed by a monotonically increasing token so
        /// `onTermination` can remove exactly the continuation it was handed.
        var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
        /// The next token to hand out.
        var nextToken: UInt64 = 0
        /// Replay history, maintained per ``ReplayMode``: unused for `.none`, at most one
        /// element for `.latest`, and — for `.allUntilFirstConsumer` — every element
        /// yielded *until the first subscriber registers*, at which point it is drained
        /// to that subscriber, cleared, and never populated again (see ``replayConsumed``).
        var replayBuffer: [Element] = []
        /// `.allUntilFirstConsumer` only: set once the first subscriber has registered
        /// (and drained the replay buffer). From then on `yield(_:)` stops buffering and
        /// later subscribers get no replay — even if every earlier consumer has since
        /// terminated.
        var replayConsumed = false
        /// Set by ``finish()``; once `true`, new subscribers are immediately finished and
        /// ``yield(_:)`` is a no-op.
        var finished = false
    }

    private let replay: ReplayMode
    private let box: Mutex<State>

    /// Creates a `Broadcaster` with the given replay policy for late subscribers.
    init(replay: ReplayMode) {
        self.replay = replay
        self.box = Mutex(State())
    }

    /// Returns a fresh `AsyncStream` subscribed to every future ``yield(_:)``, replayed to
    /// this new subscriber per this broadcaster's ``ReplayMode``.
    ///
    /// Cancelling the stream's consuming task — or otherwise letting the stream's
    /// `AsyncIterator` deinit — unregisters it via `onTermination`; no explicit unsubscribe
    /// call is needed. If this broadcaster has already ``finish()``ed, the returned stream
    /// finishes immediately without yielding anything.
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

    /// Fans `element` out to every currently subscribed stream and, per ``ReplayMode``,
    /// records it for future subscribers. A no-op after ``finish()``.
    func yield(_ element: Element) {
        box.withLock { state in
            guard !state.finished else { return }

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

            for continuation in state.continuations.values {
                continuation.yield(element)
            }
        }
    }

    /// Finishes every currently subscribed stream. Every stream created after this call
    /// finishes immediately without yielding anything. Idempotent.
    func finish() {
        // `continuation.finish()` synchronously re-enters `box.withLock` via `onTermination`
        // (see `stream(policy:)`), and `Mutex` isn't reentrant — so pull continuations out
        // under the lock, then finish each one after it's released.
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
