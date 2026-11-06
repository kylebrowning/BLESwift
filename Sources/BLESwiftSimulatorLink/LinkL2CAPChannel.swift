//
//  LinkL2CAPChannel.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Foundation
import BLESwiftCompat17

/// Failures that a link-backed L2CAP channel raises by itself, as distinct from the failures
/// that the provider reports over the wire.
enum LinkL2CAPError: Error, Equatable {

    /// The caller wrote to a channel that is already closed. The channel closed locally, the
    /// provider closed it, or the link dropped.
    case closed

    /// The provider granted a credit that the scheme does not permit: zero, negative, larger
    /// than the whole window, or a credit that would overflow the window. The channel closes and
    /// does not continue with a window that could go negative.
    case invalidCredit(Int)

    /// The provider sent an inbound frame that is larger than the chunk size. Both ends split
    /// their writes into chunks of this size. The channel drops the session and does not buffer
    /// the frame.
    case frameTooLarge(Int)
}

/// The client half of a tunneled L2CAP channel, an ``BLESwiftCore/L2CAPChannelRemote``. Its bytes
/// travel as `l2capData` frames under credit-based flow control.
///
/// ``LinkPeripheral/openL2CAPChannel(_:)`` creates a channel. ``LinkCentral`` then feeds it
/// through ``receive(_:)``, ``addCredit(bytes:)``, and ``remoteClosed(error:)``.
///
/// - Outbound: ``write(_:)`` splits its payload into chunks of at most ``maximumChunk`` bytes. It
///   uses credit for each chunk and suspends if credit is short. The provider returns credit only
///   after its own transport write returns. Waiting writers resume in arrival order.
/// - Inbound: ``receive(_:)`` credits the provider when bytes arrive, even if no consumer reads.
///   This window limits the data on the wire. It is not back-pressure, and `pending` can grow.
/// - One `Mutex` protects all mutable state in ``State``. The code never resumes a continuation or
///   calls a sink while it holds the lock.
final class LinkL2CAPChannel: L2CAPChannelRemote {

    /// The largest `l2capData` payload that this channel puts on the wire. It is a quarter of the
    /// initial credit, so a maximal write takes four chunks before it must wait.
    private static let maximumChunk = LinkFlowControl.l2capInitialCredit / 4

    /// One writer that is suspended until the credit window has room for its chunk.
    private struct Waiter {
        /// The chunk size that this writer waits to get.
        let bytes: Int
        /// Resumed after the code deducted that credit for this writer. Fails on teardown.
        let continuation: CheckedContinuation<Void, Error>
    }

    /// All mutable data of a channel. One lock guards it.
    private struct State {
        /// The continuation of the inbound stream. The code creates it when ``inbound()`` is first
        /// called.
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        /// Whether ``inbound()`` already gave out its one stream.
        var didVendStream = false
        /// Bytes that arrived before a consumer asked for the stream. The first ``inbound()``
        /// replays them, so the channel loses nothing that arrives between the open and the first
        /// access.
        var pending: [Data] = []
        /// The number of bytes that this side can still send before it must wait for credit.
        var outboundCredit = LinkFlowControl.l2capInitialCredit
        /// Writers that are suspended for credit, oldest first. `L2CAPChannel` is a `Sendable`
        /// struct whose `write(_:)` reaches this object directly, so any number of concurrent
        /// writers is legal. Each writer must keep its own continuation.
        var waiters: [Waiter] = []
        /// Whether the channel is torn down, and the error that caused it.
        var isClosed = false
        var closeError: Error?
        /// Whether `l2capClose` was already sent. This keeps ``close(error:)`` idempotent.
        var didSendClose = false
    }

    /// The PSM against which the code opened this channel.
    let psm: L2CAPPSM

    /// The id of this channel on the link. Both ends use it as the key to route `l2capData`,
    /// `l2capCredit`, and `l2capClosed`.
    let channel: UInt32

    /// Puts one request on the link. It is safe to call from any isolation domain. ``LinkCentral``
    /// supplies a closure that hops onto its own queue.
    private let send: @Sendable (CentralRequest) -> Void

    private let state = Mutex(State())

    /// The number of writers that are suspended and wait for outbound credit.
    ///
    /// This is a test hook. A test must *park* a writer before the teardown that must resume it,
    /// and nothing else about a suspended writer is observable from outside.
    var suspendedWriterCount: Int { state.withLock { $0.waiters.count } }

    /// Creates a channel bound to `channel` on the link.
    ///
    /// - Parameters:
    ///   - channel: The link-wide channel id. The provider tags the frames of this channel with it.
    ///   - psm: The PSM against which the code issued the open.
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
    /// **Single-consumer.** The first call gives out the one real stream and replays anything
    /// that arrived before the call. Every later call returns a stream that finishes at once,
    /// because a second consumer could only take bytes from the first.
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

    /// Sends `data` outbound. It suspends until the link has received every byte of `data`.
    ///
    /// If a payload is larger than one wire chunk, the function splits it into chunks. One wire
    /// chunk is a quarter of the initial credit, which matches the provider's chunking. The
    /// function gates the chunks on credit one at a time, so one huge write cannot deadlock
    /// against a credit window in which it can never fit.
    ///
    /// An empty payload is a no-op that succeeds, as for a zero-length write on a
    /// `CBL2CAPChannel` stream. The function does not put an empty payload on the wire, because
    /// the provider credits back exactly what it wrote and a credit of `0` is a protocol
    /// violation that costs the channel.
    ///
    /// - Parameter data: The bytes to send.
    /// - Throws: ``LinkL2CAPError/closed`` if the channel is closed before the write or while the
    ///   write waits for credit.
    /// - Important: Concurrent writes are safe. Each write waits its turn in the credit queue,
    ///   but the *interleaving* of the chunks of two concurrent writes is unspecified. If a
    ///   payload must arrive in one piece, serialize the writes yourself. A write that waits for
    ///   credit is not cancellable.
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

    /// Tears down the channel. It tells the provider to close its end (once), finishes
    /// ``inbound()`` and throws `error` if `error` is not `nil`, and fails a suspended writer.
    /// Repeated calls are safe.
    ///
    /// - Parameter error: The error with which the function finishes the inbound stream. Use
    ///   `nil` for a graceful close.
    func close(error: Error?) {
        teardown(error: error, notifyingProvider: true)
    }

    // MARK: - Wire events (fed by LinkCentral)

    /// Delivers `data` from the provider to the inbound stream and credits the provider at once.
    ///
    /// A closed channel drops the bytes and sends no credit, so the provider's window stays shut.
    ///
    /// The channel drops an empty frame and sends no credit. `write(_:)` never sends an empty
    /// frame, and a credit of `0` bytes is a protocol violation that closes the channel.
    ///
    /// A frame larger than ``maximumChunk`` is also a protocol violation. It mirrors the provider's
    /// cap on an inbound `l2capData`. The function throws and does not buffer it. The caller drops
    /// the session. This stops a peer from choosing this client's buffer size.
    ///
    /// - Throws: ``LinkL2CAPError/frameTooLarge(_:)`` for a frame that is too large.
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

    /// Grants `bytes` of outbound credit and resumes a writer that waited for room.
    ///
    /// **The function validates a credit before it applies the credit.** The provider credits back
    /// exactly what it wrote to the real transport. That amount can never be zero, negative, or
    /// more than ``BLESwiftLink/LinkFlowControl/l2capInitialCredit`` at one time. Anything else is
    /// a protocol violation, including an addition that would overflow. The channel closes with
    /// ``LinkL2CAPError/invalidCredit(_:)`` and does not keep a window that could go negative
    /// and suspend its writers forever.
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

    /// Tears down the channel because the provider or the link ended it. This is the same as
    /// ``close(error:)``, but the channel sends no `l2capClose` back for a close that came from
    /// the other side.
    func remoteClosed(error: Error?) {
        teardown(error: error, notifyingProvider: false)
    }

    // MARK: - Internals

    /// Acquires credit for `chunk` and puts the chunk on the wire.
    private func sendChunk(_ chunk: Data) async throws {
        try await acquireCredit(chunk.count)
        send(.l2capData(channel: channel, data: chunk))
    }

    /// Suspends until `count` bytes of outbound credit are available, and then consumes them.
    ///
    /// The code that grants the wait deducts the credit: this call, inline, or
    /// ``addCredit(bytes:)`` for a queued writer. Thus a resumed writer can never lose its window
    /// to another caller. A writer that arrives while others are in the queue joins the back of
    /// the queue even if credit is available. Thus the queue serves waiters strictly in order,
    /// and a steady stream of new writers cannot starve any of them.
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

    /// Resumes queued writers, oldest first, while the credit window covers the writer at the
    /// head. The code deducts each waiter's credit under the lock, resumes the continuation after
    /// it releases the lock, and then examines the queue again.
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

    /// The one teardown path. It marks the channel closed, optionally tells the provider,
    /// finishes the inbound stream, and fails a suspended writer. A second call does nothing.
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
        // Make every callout after the lock is released.
        if teardown.shouldSendClose { send(.l2capClose(channel: channel)) }
        teardown.continuation?.finish(throwing: error)
        for waiter in teardown.waiters { waiter.continuation.resume(throwing: LinkL2CAPError.closed) }
    }
}
