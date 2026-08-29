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

    /// The provider granted a credit the scheme does not permit — zero, negative, larger than
    /// the whole window, or one that would overflow it. The channel is closed rather than
    /// carried on with a window that could go negative.
    case invalidCredit(Int)

    /// The provider sent an inbound frame larger than the chunk size both ends split their
    /// writes into. The session is dropped rather than the frame buffered.
    case frameTooLarge(Int)
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
/// ``BLESwiftLink/LinkFlowControl/l2capInitialCredit`` bytes of credit. ``write(_:)`` splits
/// its payload into chunks of at most ``maximumChunk`` bytes, consumes credit for each one,
/// and suspends when there is not enough left; the provider grants credit back only once its
/// own `write` to the real transport has returned, so a slow peer eventually suspends the
/// writer rather than growing an unbounded queue in the provider. Writers that must wait are
/// queued and served in arrival order, so concurrent writers neither starve nor lose each
/// other's continuations.
///
/// **Flow control, inbound — a wire window, not back-pressure.** Every ``receive(_:)``
/// credits the provider the moment the bytes arrive, whether they were yielded to a waiting
/// consumer or buffered for one that has not asked yet. So the provider→client direction has
/// **no end-to-end back-pressure by design**: a consumer that never reads does not slow the
/// provider down, it simply grows this channel's `pending` buffer. The credit window bounds
/// how much is in flight on the wire at once — the provider stops sending until it is
/// credited — and nothing more. Only the client→provider direction carries back-pressure all
/// the way to the peer, because the provider credits a write only once its own write to the
/// real transport has returned.
///
/// **Concurrency.** Every mutable field lives in one `Mutex`-protected ``State``; no
/// continuation is ever resumed and no sink is ever called with the lock held. Every entry
/// point is therefore safe from any isolation domain, as the seam requires.
final class LinkL2CAPChannel: L2CAPChannelRemote {

    /// The largest `l2capData` payload this channel puts on the wire. A quarter of the
    /// initial credit, so a maximal write still takes four chunks before it must wait.
    private static let maximumChunk = LinkFlowControl.l2capInitialCredit / 4

    /// One writer suspended until the credit window has room for its chunk.
    private struct Waiter {
        /// The chunk size this writer is waiting to be granted.
        let bytes: Int
        /// Resumed once that credit has been deducted on its behalf, or failed on teardown.
        let continuation: CheckedContinuation<Void, Error>
    }

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
        /// Writers suspended for credit, oldest first. `L2CAPChannel` is a `Sendable` struct
        /// whose `write(_:)` reaches this object directly, so any number of concurrent
        /// writers is legal and each one must keep its own continuation.
        var waiters: [Waiter] = []
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

    /// How many writers are currently suspended waiting for outbound credit.
    ///
    /// A test hook: a writer has to be *parked* before the teardown that must resume it, and
    /// nothing else about a suspended writer is observable from outside.
    var suspendedWriterCount: Int { state.withLock { $0.waiters.count } }

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
    /// A payload larger than one wire chunk (a quarter of the initial credit, matching the
    /// provider's own chunking) is split into chunks that are credit-gated one at a time, so
    /// a single huge write can never deadlock against a credit window it could not possibly
    /// fit in.
    ///
    /// An empty payload is a no-op that succeeds, matching what a `CBL2CAPChannel`'s stream
    /// does with a zero-length write. Putting it on the wire would not be: the provider
    /// credits back exactly what it wrote, and a credit of `0` is a protocol violation that
    /// costs the channel.
    ///
    /// - Parameter data: The bytes to send.
    /// - Throws: ``LinkL2CAPError/closed`` if the channel is closed before or while the write
    ///   is waiting for credit.
    /// - Important: Concurrent writes are safe — each waits its turn in the credit queue —
    ///   but the *interleaving* of two concurrent writes' chunks is unspecified. Serialize
    ///   them yourself when a payload must arrive contiguously. A write waiting for credit is
    ///   not cancellable.
    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard data.count > Self.maximumChunk else {
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
    ///
    /// A closed channel takes neither: the bytes are dropped, and dropped bytes are not
    /// credited — crediting them would re-open the provider's window on a channel that will
    /// never read another byte.
    ///
    /// An empty frame is dropped for the same reason ``write(_:)`` never puts one on the
    /// wire: crediting it would send `l2capCredit` with `0` bytes, which the provider treats
    /// as a protocol violation and answers by closing the channel. Nothing is yielded for it
    /// either — an empty element is not a byte a consumer can read.
    ///
    /// **One frame is bounded.** A frame larger than ``maximumChunk`` is larger than the chunk
    /// size both ends split their writes into, so no honest provider can produce one — the
    /// mirror of the provider's own cap on an inbound `l2capData`. It is a protocol violation,
    /// and it is thrown rather than buffered: the caller drops the session, which closes every
    /// channel on it, instead of letting a peer that has left the scheme behind name this
    /// client's buffer size.
    ///
    /// - Throws: ``LinkL2CAPError/frameTooLarge(_:)`` for an over-large frame.
    func receive(_ data: Data) throws {
        guard data.count <= Self.maximumChunk else {
            throw LinkL2CAPError.frameTooLarge(data.count)
        }
        guard !data.isEmpty else { return }
        enum Delivery {
            case buffered
            case yield(AsyncThrowingStream<Data, Error>.Continuation)
            case closed
        }
        let delivery = state.withLock { state -> Delivery in
            guard !state.isClosed else { return .closed }
            guard let continuation = state.continuation else {
                state.pending.append(data)
                return .buffered
            }
            return .yield(continuation)
        }
        switch delivery {
        case .closed:
            return
        case .buffered:
            break
        case .yield(let continuation):
            continuation.yield(data)
        }
        send(.l2capCredit(channel: channel, bytes: data.count))
    }

    /// Grants `bytes` of outbound credit, resuming a writer that was waiting for room.
    ///
    /// **A credit is validated before it is applied.** The provider credits back exactly what
    /// it has written to the real transport, which can never be zero, negative, or more than
    /// ``BLESwiftLink/LinkFlowControl/l2capInitialCredit`` at once. Anything else — an
    /// addition that would overflow included — is a protocol violation, and the channel is
    /// closed with ``LinkL2CAPError/invalidCredit(_:)`` rather than left with a window that
    /// could go negative and suspend its writers forever.
    func addCredit(bytes: Int) {
        guard bytes > 0, bytes <= LinkFlowControl.l2capInitialCredit else {
            teardown(error: LinkL2CAPError.invalidCredit(bytes), notifyingProvider: true)
            return
        }
        let overflowed = state.withLock { state -> Bool in
            let sum = state.outboundCredit.addingReportingOverflow(bytes)
            guard !sum.overflow else { return true }
            state.outboundCredit = sum.partialValue
            return false
        }
        guard !overflowed else {
            teardown(error: LinkL2CAPError.invalidCredit(bytes), notifyingProvider: true)
            return
        }
        resumeGrantableWaiters()
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
    /// The credit is deducted by whoever grants the wait — this call, inline, or
    /// ``addCredit(bytes:)`` on behalf of a queued writer — so a resumed writer can never
    /// lose its window to another caller. A writer that arrives while others are already
    /// queued joins the back of the queue even if there is credit to spare, so waiters are
    /// served strictly in order and none can be starved by a steady stream of newcomers.
    private func acquireCredit(_ count: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enum Outcome { case granted, closed, waiting }
            let outcome = state.withLock { state -> Outcome in
                guard !state.isClosed else { return .closed }
                guard state.waiters.isEmpty, state.outboundCredit >= count else {
                    state.waiters.append(Waiter(bytes: count, continuation: continuation))
                    return .waiting
                }
                state.outboundCredit -= count
                return .granted
            }
            switch outcome {
            case .granted: continuation.resume()
            case .closed: continuation.resume(throwing: LinkL2CAPError.closed)
            case .waiting: break
            }
        }
    }

    /// Resumes queued writers, oldest first, for as long as the credit window covers the one
    /// at the head. Each waiter's credit is deducted under the lock and the continuation is
    /// resumed after it is released, with the queue re-examined afterwards.
    private func resumeGrantableWaiters() {
        while true {
            let waiter = state.withLock { state -> Waiter? in
                guard !state.isClosed,
                      let head = state.waiters.first,
                      state.outboundCredit >= head.bytes
                else { return nil }
                state.outboundCredit -= head.bytes
                state.waiters.removeFirst()
                return head
            }
            guard let waiter else { return }
            waiter.continuation.resume()
        }
    }

    /// The one teardown path: marks the channel closed, optionally tells the provider,
    /// finishes the inbound stream, and fails a suspended writer. Idempotent — a second call
    /// does nothing.
    private func teardown(error: Error?, notifyingProvider: Bool) {
        struct Teardown {
            var continuation: AsyncThrowingStream<Data, Error>.Continuation?
            var waiters: [Waiter] = []
            var shouldSendClose = false
        }
        let teardown = state.withLock { state -> Teardown? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            state.closeError = error
            var teardown = Teardown()
            teardown.continuation = state.continuation
            teardown.waiters = state.waiters
            teardown.shouldSendClose = notifyingProvider && !state.didSendClose
            if teardown.shouldSendClose { state.didSendClose = true }
            state.continuation = nil
            state.waiters = []
            return teardown
        }
        guard let teardown else { return }
        // Every callout happens after the lock is released.
        if teardown.shouldSendClose { send(.l2capClose(channel: channel)) }
        teardown.continuation?.finish(throwing: error)
        for waiter in teardown.waiters { waiter.continuation.resume(throwing: LinkL2CAPError.closed) }
    }
}
