//
//  LinkL2CAPChannel.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Foundation
import Synchronization

/// Failures a link-backed L2CAP channel raises on its own behalf, as distinct from the ones
/// the provider reports over the wire.
enum LinkL2CAPError: Error, Equatable {

    /// A write was attempted on a channel that has already been closed — locally, by the
    /// provider, or by the link dropping.
    case closed
}

/// The client half of an L2CAP channel tunnelled over the link: an
/// ``BLESwiftCore/L2CAPChannelRemote`` whose bytes ride the wire as `l2capData` frames under
/// credit-based flow control.
///
/// A channel is never created directly. ``LinkPeripheral/openL2CAPChannel(_:)`` allocates a
/// channel id, registers one of these in ``LinkCentral``'s table, and sends the open request;
/// the central then feeds this object from the provider's wire events —
/// ``receive(_:)``, ``addCredit(bytes:)``, and ``remoteClosed(error:)``.
///
/// **Flow control, outbound.** The channel starts with
/// ``BLESwiftLink/LinkFlowControl/l2capInitialCredit`` bytes of credit. ``write(_:)``
/// consumes credit for each chunk it sends and suspends when there is not enough left; the
/// provider grants credit back only once its own `write` to the real transport has returned,
/// so a slow peer eventually suspends the writer rather than growing an unbounded queue in
/// the provider.
///
/// **Flow control, inbound.** Every ``receive(_:)`` yields to the inbound stream and
/// immediately credits the provider for the bytes taken, since the client-side stream buffers
/// them for a consumer that is under no obligation to be ready.
///
/// **Concurrency.** Every mutable field lives in one `Mutex`-protected ``State``; no
/// continuation is ever resumed and no sink is ever called with the lock held. Every entry
/// point is therefore safe from any isolation domain, as the seam requires.
final class LinkL2CAPChannel: L2CAPChannelRemote {

    /// The largest `l2capData` payload this channel puts on the wire. A quarter of the
    /// initial credit, so a maximal write still takes four chunks before it must wait.
    private static let maximumChunk = LinkFlowControl.l2capInitialCredit / 4

    /// Everything mutable about a channel, under one lock.
    private struct State {
        /// The inbound stream's continuation, created when ``inbound()`` is first called.
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        /// Whether ``inbound()`` has already vended its one stream.
        var didVendStream = false
        /// Bytes received before a consumer asked for the stream, replayed on the first
        /// ``inbound()`` so nothing arriving between the open and the first access is lost.
        var pending: [Data] = []
        /// Bytes this side may still send before it must wait for credit.
        var outboundCredit = LinkFlowControl.l2capInitialCredit
        /// The single suspended writer, if any, and the size it is waiting for.
        var waiter: CheckedContinuation<Void, Error>?
        var waiterBytes = 0
        /// Whether the channel has been torn down, and with what error.
        var isClosed = false
        var closeError: Error?
        /// Whether `l2capClose` has already gone out, keeping ``close(error:)`` idempotent.
        var didSendClose = false
    }

    /// The PSM this channel was opened against.
    let psm: L2CAPPSM

    /// This channel's id on the link — the key both ends route `l2capData`, `l2capCredit`,
    /// and `l2capClosed` by.
    let channel: UInt32

    /// Puts one request on the link. Safe to call from any isolation domain: ``LinkCentral``
    /// supplies a closure that hops onto its own queue.
    private let send: @Sendable (CentralRequest) -> Void

    private let state = Mutex(State())

    /// Creates a channel bound to `channel` on the link.
    ///
    /// - Parameters:
    ///   - channel: The link-wide channel id the provider will tag this channel's frames
    ///     with.
    ///   - psm: The PSM the open was issued against.
    ///   - send: Puts one ``BLESwiftLink/CentralRequest`` on the link, from any isolation
    ///     domain.
    init(channel: UInt32, psm: L2CAPPSM, send: @escaping @Sendable (CentralRequest) -> Void) {
        self.channel = channel
        self.psm = psm
        self.send = send
    }

    // MARK: - L2CAPChannelRemote

    /// The inbound byte stream.
    ///
    /// **Single-consumer.** The first call vends the one real stream — replaying anything
    /// that arrived before it — and every later call returns a stream that finishes
    /// immediately, since a second consumer could only steal bytes from the first.
    func inbound() -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        enum Outcome {
            case vend(replay: [Data], finish: Bool, error: Error?)
            case alreadyVended
        }
        let outcome = state.withLock { state -> Outcome in
            guard !state.didVendStream else { return .alreadyVended }
            state.didVendStream = true
            let replay = state.pending
            state.pending = []
            guard !state.isClosed else { return .vend(replay: replay, finish: true, error: state.closeError) }
            state.continuation = continuation
            return .vend(replay: replay, finish: false, error: nil)
        }
        switch outcome {
        case .alreadyVended:
            continuation.finish()
        case .vend(let replay, let finish, let error):
            for data in replay { continuation.yield(data) }
            if finish { continuation.finish(throwing: error) }
        }
        return stream
    }

    /// Sends `data` outbound, suspending until every byte of it has been handed to the link.
    ///
    /// A payload larger than ``BLESwiftLink/LinkFlowControl/l2capInitialCredit`` is split
    /// into chunks that are credit-gated one at a time, so a single huge write can never
    /// deadlock against a credit window it could not possibly fit in.
    ///
    /// - Parameter data: The bytes to send.
    /// - Throws: ``LinkL2CAPError/closed`` if the channel is closed before or while the write
    ///   is waiting for credit.
    /// - Important: Only one write may be in flight at a time — `BLESwift`'s `L2CAPChannel`
    ///   serializes them — and a write waiting for credit is not cancellable.
    func write(_ data: Data) async throws {
        guard data.count > LinkFlowControl.l2capInitialCredit else {
            try await sendChunk(data)
            return
        }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: Self.maximumChunk, limitedBy: data.endIndex) ?? data.endIndex
            try await sendChunk(Data(data[offset..<end]))
            offset = end
        }
    }

    /// Tears the channel down: tells the provider to close its end (once), finishes
    /// ``inbound()`` — throwing `error` if non-`nil` — and fails a suspended writer.
    /// Idempotent.
    ///
    /// - Parameter error: The error to finish the inbound stream with, or `nil` for a
    ///   graceful close.
    func close(error: Error?) {
        teardown(error: error, notifyingProvider: true)
    }

    // MARK: - Wire events (fed by LinkCentral)

    /// Delivers `data` from the provider to the inbound stream and immediately credits the
    /// provider for it — the client buffers on the consumer's behalf, so the bytes are
    /// "consumed" the moment they land.
    func receive(_ data: Data) {
        let continuation = state.withLock { state -> AsyncThrowingStream<Data, Error>.Continuation? in
            guard !state.isClosed else { return nil }
            guard let continuation = state.continuation else {
                state.pending.append(data)
                return nil
            }
            return continuation
        }
        continuation?.yield(data)
        send(.l2capCredit(channel: channel, bytes: data.count))
    }

    /// Grants `bytes` of outbound credit, resuming a writer that was waiting for room.
    func addCredit(bytes: Int) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
            state.outboundCredit += bytes
            guard let waiter = state.waiter, state.outboundCredit >= state.waiterBytes else { return nil }
            state.outboundCredit -= state.waiterBytes
            state.waiterBytes = 0
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Tears the channel down because the provider (or the link) ended it — the same as
    /// ``close(error:)`` except that no `l2capClose` is sent back for a close that came from
    /// the other side.
    func remoteClosed(error: Error?) {
        teardown(error: error, notifyingProvider: false)
    }

    // MARK: - Internals

    /// Acquires credit for `chunk` and puts it on the wire.
    private func sendChunk(_ chunk: Data) async throws {
        try await acquireCredit(chunk.count)
        send(.l2capData(channel: channel, data: chunk))
    }

    /// Suspends until `count` bytes of outbound credit are available, consuming them.
    ///
    /// The credit is deducted by whoever grants the wait — either this call, inline, or
    /// ``addCredit(bytes:)`` — so a resumed writer can never lose its window to another
    /// caller.
    private func acquireCredit(_ count: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enum Outcome { case granted, closed, waiting }
            let outcome = state.withLock { state -> Outcome in
                guard !state.isClosed else { return .closed }
                guard state.outboundCredit < count else {
                    state.outboundCredit -= count
                    return .granted
                }
                // One writer at a time: `L2CAPChannel.write(_:)` is the only caller and it is
                // serialized by the `Central` actor owning it.
                assert(state.waiter == nil, "LinkL2CAPChannel supports one suspended writer")
                state.waiter = continuation
                state.waiterBytes = count
                return .waiting
            }
            switch outcome {
            case .granted: continuation.resume()
            case .closed: continuation.resume(throwing: LinkL2CAPError.closed)
            case .waiting: break
            }
        }
    }

    /// The one teardown path: marks the channel closed, optionally tells the provider,
    /// finishes the inbound stream, and fails a suspended writer. Idempotent — a second call
    /// does nothing.
    private func teardown(error: Error?, notifyingProvider: Bool) {
        struct Teardown {
            var continuation: AsyncThrowingStream<Data, Error>.Continuation?
            var waiter: CheckedContinuation<Void, Error>?
            var shouldSendClose = false
        }
        let teardown = state.withLock { state -> Teardown? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            state.closeError = error
            var teardown = Teardown()
            teardown.continuation = state.continuation
            teardown.waiter = state.waiter
            teardown.shouldSendClose = notifyingProvider && !state.didSendClose
            if teardown.shouldSendClose { state.didSendClose = true }
            state.continuation = nil
            state.waiter = nil
            state.waiterBytes = 0
            return teardown
        }
        guard let teardown else { return }
        // Every callout happens after the lock is released.
        if teardown.shouldSendClose { send(.l2capClose(channel: channel)) }
        teardown.continuation?.finish(throwing: error)
        teardown.waiter?.resume(throwing: LinkL2CAPError.closed)
    }
}
