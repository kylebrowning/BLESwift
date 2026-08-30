//
//  CentralSession+L2CAP.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import Synchronization

/// One L2CAP channel a ``CentralSession`` is bridging: the backend's real transport, the
/// task pumping its inbound bytes onto the link, the chain keeping outbound writes ordered,
/// and this end's flow-control credit.
///
/// **Concurrency.** ``remote`` is `Sendable` by protocol and the credit window lives under a
/// `Mutex` because the pump waits on it from its own task while the session grants against
/// it on the session queue. ``pump`` and ``writes`` are touched only on the session queue,
/// like every other piece of session state.
final class OpenChannel: Sendable {

    /// The flow-control window for the provider→client direction, plus the pump waiting on
    /// it.
    struct Credit {
        /// Bytes the provider may still put on the wire before it must wait.
        var available = LinkFlowControl.l2capInitialCredit
        /// The pump, suspended until ``available`` covers ``waitingFor``. There is only ever
        /// one: the pump is this channel's sole sender.
        var waiter: CheckedContinuation<Void, Never>?
        var waitingFor = 0
        /// Set once the channel is torn down, so a waiting pump is released rather than
        /// stranded.
        var isClosed = false
    }

    /// The backend's half of the channel.
    let remote: any L2CAPChannelRemote

    /// The peripheral this channel belongs to, so a disconnect can close exactly its
    /// channels.
    let peripheral: UUID

    /// This end's outbound credit.
    let credit = Mutex(Credit())

    /// Pumps ``remote``'s inbound stream onto the link. Assigned and cancelled on the session
    /// queue only.
    nonisolated(unsafe) var pump: Task<Void, Never>?

    /// The tail of the serial chain of outbound writes, so bytes reach ``remote`` in the
    /// order the client sent them. Session queue only.
    nonisolated(unsafe) var writes: Task<Void, Never>?

    /// How many client-written bytes are sitting in ``writes`` without having reached
    /// ``remote`` yet — the client's outstanding window in this direction.
    ///
    /// Raised when a `l2capData` frame joins the chain and lowered when that write completes,
    /// which is the same moment the client is credited for it. Session queue only, like
    /// ``writes`` itself.
    nonisolated(unsafe) var outstanding = 0

    /// Creates a bridge over `remote`, owned by `peripheral`.
    init(remote: any L2CAPChannelRemote, peripheral: UUID) {
        self.remote = remote
        self.peripheral = peripheral
    }

    /// Suspends the pump until `count` bytes of credit are available, consuming them.
    /// Returns immediately once the channel is closed, letting the pump unwind.
    func waitForCredit(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enum Outcome { case granted, waiting }
            let outcome = credit.withLock { credit -> Outcome in
                guard !credit.isClosed else { return .granted }
                guard credit.available < count else {
                    credit.available -= count
                    return .granted
                }
                credit.waiter = continuation
                credit.waitingFor = count
                return .waiting
            }
            // Resumed outside the lock, always.
            if case .granted = outcome { continuation.resume() }
        }
    }

    /// Grants `bytes` of credit, resuming the pump if that is enough for what it is waiting
    /// on. The credit is deducted here, so the resumed pump cannot lose its window.
    ///
    /// - Parameter bytes: The credit to add. Already known to be in range — see
    ///   ``CentralSession/grantCredit(_:to:)``.
    /// - Returns: `false` if the addition overflowed, which no honest peer can bring about:
    ///   the caller closes the channel rather than carry on with a wrapped window.
    func grant(_ bytes: Int) -> Bool {
        enum Outcome { case overflow, granted(CheckedContinuation<Void, Never>?) }
        let outcome = credit.withLock { credit -> Outcome in
            let sum = credit.available.addingReportingOverflow(bytes)
            guard !sum.overflow else { return .overflow }
            credit.available = sum.partialValue
            guard let waiter = credit.waiter, credit.available >= credit.waitingFor else { return .granted(nil) }
            credit.available -= credit.waitingFor
            credit.waitingFor = 0
            credit.waiter = nil
            return .granted(waiter)
        }
        guard case .granted(let waiter) = outcome else { return false }
        waiter?.resume()
        return true
    }

    /// Marks the window closed and releases a waiting pump, so teardown never strands it.
    func releaseWaiter() {
        let waiter = credit.withLock { credit -> CheckedContinuation<Void, Never>? in
            credit.isClosed = true
            let waiter = credit.waiter
            credit.waiter = nil
            credit.waitingFor = 0
            return waiter
        }
        waiter?.resume()
    }
}

/// The L2CAP half of a central-role session: the bridge between the link's `l2capData`,
/// `l2capCredit`, and `l2capClose` frames and the backend's
/// ``BLESwiftCore/L2CAPChannelRemote``.
///
/// **Credit, provider→client.** The pump takes bytes off the backend's inbound stream, waits
/// for this end's credit, and sends them as `l2capData`; the client credits back the moment
/// it has yielded them to its own stream.
///
/// **Credit, client→provider.** A `l2capData` request is written to the backend's transport
/// and only *then* credited back with `l2capCredit`, so the client's writer feels the real
/// transport's back-pressure rather than filling a queue here.
extension CentralSession {

    /// The largest `l2capData` payload either end puts on the wire — the provider's own
    /// chunking, and the size a client's frame may not exceed.
    static var maximumChunk: Int { LinkFlowControl.l2capInitialCredit / 4 }

    /// How many client-written bytes one channel may have unwritten before this session stops
    /// believing the client.
    ///
    /// A whole credit window, plus one chunk of slack for the frame that was already on the
    /// wire when the window closed. A client honoring the scheme waits for `l2capCredit`
    /// before it exceeds this; one that does not can otherwise grow the write chain — and the
    /// provider's memory — without bound, because inbound `l2capData` is the one queue a
    /// client fills entirely at its own pace.
    static var maximumOutstandingWrites: Int { LinkFlowControl.l2capInitialCredit + maximumChunk }

    // MARK: - Open

    /// Completes one `openL2CAPChannel` request: matches it to the client's channel id,
    /// registers the bridge, answers the client, and starts the inbound pump.
    ///
    /// The backend's completions for one peripheral arrive in the order the opens were
    /// issued, so a FIFO per peripheral is enough to pair them up. Must be called on
    /// ``CentralSession/queue``.
    func bridgeOpenedChannel(_ channel: (any L2CAPChannelRemote)?, error: NSError?, from peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        var queued = pendingOpens[peripheral] ?? []
        let pending = queued.isEmpty ? nil : queued.removeFirst()
        pendingOpens[peripheral] = queued

        guard let pending else {
            // Nothing asked for this channel — an open this session never issued (or one
            // whose connection has already been discarded). Close it rather than leak it.
            log?("no pending L2CAP open for peripheral \(peripheral); closing the channel")
            channel?.close(error: nil)
            return
        }

        guard let channel, error == nil else {
            channel?.close(error: nil)
            send(.didOpenL2CAPChannel(
                peripheral: peripheral,
                channel: pending.channel,
                psm: pending.psm,
                error: WireError(error ?? CentralSession.l2capOpenFailed)
            ))
            return
        }

        // The channel id is the *client's*, carried verbatim from its request, so two opens
        // can name the same one. Overwriting orphaned the first bridge: nothing could reach it
        // again — every close path iterates ``channels`` — so its pump kept interleaving frames
        // under an id that now belonged to another channel, and its transport, its task and its
        // parked continuation lived on for the session. The duplicate is refused instead, and
        // the channel already open under that id is untouched.
        guard channels[pending.channel] == nil else {
            log?("L2CAP channel \(pending.channel) is already open; refusing the duplicate open")
            channel.close(error: nil)
            send(.didOpenL2CAPChannel(
                peripheral: peripheral,
                channel: pending.channel,
                psm: pending.psm,
                error: WireError(CentralSession.l2capDuplicateChannel)
            ))
            return
        }
        let open = OpenChannel(remote: channel, peripheral: peripheral)
        channels[pending.channel] = open
        send(.didOpenL2CAPChannel(
            peripheral: peripheral,
            channel: pending.channel,
            psm: channel.psm.rawValue,
            error: nil
        ))
        startPump(for: pending.channel, open: open)
    }

    /// Starts the task pumping `open`'s inbound bytes onto the link under this end's credit,
    /// and reporting the stream's end as `l2capClosed`. Must be called on ``CentralSession/queue``.
    private func startPump(for channel: UInt32, open: OpenChannel) {
        dispatchPrecondition(condition: .onQueue(queue))
        open.pump = Task { [weak self] in
            do {
                for try await data in open.remote.inbound() {
                    for piece in CentralSession.pieces(of: data) {
                        guard !Task.isCancelled else { return }
                        await open.waitForCredit(piece.count)
                        guard !Task.isCancelled else { return }
                        self?.sendFromPump(.l2capData(channel: channel, data: piece), channel: channel, open: open)
                    }
                }
                self?.finishChannel(channel, open: open, error: nil)
            } catch {
                self?.finishChannel(channel, open: open, error: error)
            }
        }
    }

    /// Splits `data` into wire-sized pieces. A backend is free to hand up a read far larger
    /// than one credit window; sending it whole would deadlock the pump against a window it
    /// could never fit in.
    private static func pieces(of data: Data) -> [Data] {
        guard data.count > maximumChunk else { return [data] }
        var pieces: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: maximumChunk, limitedBy: data.endIndex) ?? data.endIndex
            pieces.append(Data(data[offset..<end]))
            offset = end
        }
        return pieces
    }

    // MARK: - Requests

    /// Writes `data` to `channel`'s transport and credits the client for it once the write
    /// has actually completed — the back-pressure signal the client's writer waits on.
    ///
    /// Writes are chained per channel so they reach the transport in the order the client
    /// sent them, however long any one of them takes. Must be called on
    /// ``CentralSession/queue``.
    ///
    /// **The chain is bounded, and so is one frame.** A frame larger than ``maximumChunk`` is
    /// larger than the chunk size both ends agreed on, and a client with more than
    /// ``maximumOutstandingWrites`` bytes unwritten has stopped waiting for the credit that
    /// paces it. Either is a peer that has left the scheme behind, and the link goes rather
    /// than this session's memory.
    func write(_ data: Data, to channel: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let open = channels[channel] else {
            log?("no L2CAP channel \(channel); ignoring l2capData")
            return
        }
        guard data.count <= Self.maximumChunk else {
            failProtocol(ProtocolViolation.l2capFrameTooLarge(channel: channel, bytes: data.count))
            return
        }
        guard open.outstanding + data.count <= Self.maximumOutstandingWrites else {
            failProtocol(ProtocolViolation.l2capWriteWindowExceeded(channel: channel))
            return
        }
        open.outstanding += data.count
        let previous = open.writes
        open.writes = Task { [weak self] in
            await previous?.value
            do {
                try await open.remote.write(data)
                self?.creditFromWrite(channel: channel, open: open, bytes: data.count)
            } catch {
                self?.failFromWrite(channel: channel, open: open, error: error)
            }
        }
    }

    /// Grants `bytes` of credit to `channel`, waking its pump. Must be called on
    /// ``CentralSession/queue``.
    ///
    /// **A credit is validated before it is applied.** A single grant can never be zero or
    /// negative, and can never exceed the whole window — the client credits back exactly what
    /// it has consumed, and it can never have consumed more than
    /// ``BLESwiftLink/LinkFlowControl/l2capInitialCredit``. Anything else, including an
    /// addition that would overflow, is a protocol violation from a peer that has stopped
    /// following the scheme; the channel is closed rather than left with a window that could
    /// go negative and wedge its pump forever.
    func grantCredit(_ bytes: Int, to channel: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let open = channels[channel] else {
            log?("no L2CAP channel \(channel); ignoring l2capCredit")
            return
        }
        guard bytes > 0, bytes <= LinkFlowControl.l2capInitialCredit, open.grant(bytes) else {
            log?("invalid L2CAP credit \(bytes) on channel \(channel); closing it")
            channels.removeValue(forKey: channel)
            tearDown(open)
            send(.l2capClosed(channel: channel, error: WireError(CentralSession.l2capCreditRejected)))
            return
        }
    }

    /// The error a second open naming a channel id that is already in use is refused with.
    static var l2capDuplicateChannel: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "That L2CAP channel identifier is already open"]
        )
    }

    /// The error a channel is closed with when its peer granted a credit the scheme does not
    /// permit.
    static var l2capCreditRejected: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "The client granted an out-of-range L2CAP credit"]
        )
    }

    /// Closes `channel` at the client's request: tears down the transport and drops the
    /// bridge. The client already considers the channel gone, so no `l2capClosed` is sent
    /// back. Must be called on ``CentralSession/queue``.
    func closeChannel(_ channel: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let open = channels.removeValue(forKey: channel) else {
            log?("no L2CAP channel \(channel); ignoring l2capClose")
            return
        }
        tearDown(open)
    }

    /// Closes and drops every channel `predicate` selects — a disconnect, or the session
    /// itself ending. Must be called on ``CentralSession/queue``.
    func closeChannels(matching predicate: (OpenChannel) -> Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        let doomed = channels.filter { predicate($0.value) }
        for identifier in doomed.keys { channels.removeValue(forKey: identifier) }
        for open in doomed.values { tearDown(open) }
    }

    /// Cancels a bridge's pump and its outbound write chain, releases anything waiting on its
    /// credit, and closes the transport.
    ///
    /// **The write chain is dropped, not drained.** `cancel()` reaches only the *tail* task,
    /// and even that one keeps going: each link awaits the value of the link ahead of it, an
    /// await no cancellation interrupts. Every write still in the chain therefore runs, and
    /// each fails against the transport this closes under it — which is the intended outcome,
    /// not a leak. The channel is out of ``channels`` before this runs, so nothing new can
    /// join the chain, and dropping the session's reference to the tail lets the whole chain
    /// go as those failures unwind it.
    private func tearDown(_ open: OpenChannel) {
        open.pump?.cancel()
        open.pump = nil
        open.writes?.cancel()
        open.writes = nil
        open.releaseWaiter()
        open.remote.close(error: nil)
    }

    // MARK: - Off-queue completions

    /// Whether `channel` still names `open` — the identity check every off-queue completion
    /// makes before it acts.
    ///
    /// A channel id is the client's to choose and to reuse: once a bridge has been dropped, the
    /// next open may take its id, and a write or a stream end from the *old* bridge, which was
    /// already in flight, would otherwise credit, close, or tear down the live channel that
    /// replaced it. The bridge each completion belongs to is captured at the point it was
    /// started, so the id alone is never trusted. Must be called on ``CentralSession/queue``.
    private func isCurrent(_ channel: UInt32, _ open: OpenChannel) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return channels[channel] === open
    }

    /// Sends one event from the pump, hopping onto ``CentralSession/queue`` first. The queue
    /// is serial, so the pump's frames keep their order.
    ///
    /// The identity check every other off-queue completion makes is made here too: the pump
    /// clears its cancellation check *before* the hop, so a teardown landing in between —
    /// which drops the id, and may have re-issued it to another channel by the time this runs
    /// — would otherwise put the old bridge's bytes on the wire under an id that is no longer
    /// its own. Internal so a test can drive it with a bridge the session has already
    /// dropped.
    func sendFromPump(_ event: CentralWireEvent, channel: UInt32, open: OpenChannel) {
        queue.async { [self] in
            guard isCurrent(channel, open) else { return }
            send(event)
        }
    }

    /// Releases a completed write's share of the channel's outstanding window and credits the
    /// client for it.
    private func creditFromWrite(channel: UInt32, open: OpenChannel, bytes: Int) {
        queue.async { [self] in
            guard isCurrent(channel, open) else { return }
            open.outstanding -= bytes
            // A write of nothing consumed no window, and `0` is not a credit the client would
            // accept: it treats a non-positive grant as a protocol violation and closes the
            // channel. Clients do not send empty payloads, but a peer that did should not be
            // answered with a frame that tears its own channel down.
            guard bytes > 0 else { return }
            send(.l2capCredit(channel: channel, bytes: bytes))
        }
    }

    /// Reports a failed write as the channel closing, and drops the bridge.
    private func failFromWrite(channel: UInt32, open: OpenChannel, error: any Error) {
        queue.async { [self] in
            guard isCurrent(channel, open) else { return }
            channels.removeValue(forKey: channel)
            tearDown(open)
            send(.l2capClosed(channel: channel, error: WireError(error as NSError)))
        }
    }

    /// Reports the backend's inbound stream ending — cleanly or on `error` — and drops the
    /// bridge. Called from the pump, off ``CentralSession/queue``.
    ///
    /// The write chain goes with it, for ``tearDown(_:)``'s reason: the transport is closing
    /// under whatever is still queued, so leaving the tail task alive would only keep the
    /// chain — and the data it captured — around until the write ahead of it fails. The pump
    /// is dropped rather than cancelled because this *is* the pump reporting its own end.
    private func finishChannel(_ channel: UInt32, open: OpenChannel, error: (any Error)?) {
        queue.async { [self] in
            guard isCurrent(channel, open) else { return }
            channels.removeValue(forKey: channel)
            open.releaseWaiter()
            open.pump = nil
            open.writes?.cancel()
            open.writes = nil
            open.remote.close(error: nil)
            send(.l2capClosed(channel: channel, error: (error as NSError?).wire))
        }
    }
}
#endif
