//
//  CentralSession+L2CAP.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import BLESwiftCompat17

/// One L2CAP channel that a ``CentralSession`` bridges. It holds these parts:
///
/// - The backend's real transport.
/// - The task that pumps the inbound bytes onto the link.
/// - The chain that keeps the outbound writes in order.
/// - The flow-control credit of this end.
///
/// **Concurrency.** ``remote`` is `Sendable` by protocol. The credit window lives under a
/// `Mutex`, because the pump waits on it from its own task while the session grants against it
/// on the session queue. Code touches ``pump`` and ``writes`` only on the session queue, as for
/// all other session state.
final class OpenChannel: Sendable {

    /// The flow-control window for the direction from provider to client, and the pump that
    /// waits on it.
    struct Credit {
        /// The bytes that the provider can still put on the wire before it must wait.
        var available = LinkFlowControl.l2capInitialCredit
        /// The pump. It is suspended until ``available`` covers ``waitingFor``. Only one pump
        /// exists, because the pump is the only sender of this channel.
        var waiter: CheckedContinuation<Void, Never>?
        var waitingFor = 0
        /// Set when the channel is torn down. Then the code releases a waiting pump and does not
        /// leave it stranded.
        var isClosed = false
    }

    /// The backend's half of the channel.
    let remote: any L2CAPChannelRemote

    /// The peripheral to which this channel belongs, so that a disconnect can close exactly that
    /// peripheral's channels.
    let peripheral: UUID

    /// The outbound credit of this end.
    let credit = Mutex(Credit())

    /// Pumps the inbound stream of ``remote`` onto the link. Code assigns and cancels it only on
    /// the session queue.
    nonisolated(unsafe) var pump: Task<Void, Never>?

    /// The tail of the serial chain of outbound writes, so that the bytes reach ``remote`` in the
    /// order in which the client sent them. Use it only on the session queue.
    nonisolated(unsafe) var writes: Task<Void, Never>?

    /// The number of client-written bytes that are in ``writes`` and have not reached ``remote``
    /// yet. This is the client's outstanding window in this direction.
    ///
    /// The count rises when a `l2capData` frame joins the chain. It falls when that write
    /// completes, which is when the client gets credit for the write. Use it only on the
    /// session queue, as for ``writes`` itself.
    nonisolated(unsafe) var outstanding = 0

    /// Creates a bridge over `remote`, owned by `peripheral`.
    init(remote: any L2CAPChannelRemote, peripheral: UUID) {
        self.remote = remote
        self.peripheral = peripheral
    }

    /// Suspends the pump until `count` bytes of credit are available, and consumes them. When
    /// the channel is closed, it returns immediately so that the pump can unwind.
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
            // Always resume outside the lock.
            if case .granted = outcome { continuation.resume() }
        }
    }

    /// Grants `bytes` of credit. If that is enough for what the pump waits for, it resumes the
    /// pump. The method deducts the credit here, so the resumed pump cannot lose its window.
    ///
    /// - Parameter bytes: The credit to add. It is already known to be in range. See
    ///   ``CentralSession/grantCredit(_:to:)``.
    /// - Returns: `false` if the addition overflowed. No honest peer can cause this. The caller
    ///   closes the channel and does not continue with a wrapped window.
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

    /// Marks the window closed and releases a waiting pump, so a teardown never strands the
    /// pump.
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

/// The L2CAP half of a central-role session. It is the bridge between the link's `l2capData`,
/// `l2capCredit`, and `l2capClose` frames and the backend's ``BLESwiftCore/L2CAPChannelRemote``.
///
/// **Credit, provider to client.** The pump takes bytes off the backend's inbound stream, waits
/// for this end's credit, and sends the bytes as `l2capData`. The client returns credit when it
/// has yielded the bytes to its own stream.
///
/// **Credit, client to provider.** The session writes an `l2capData` request to the backend's
/// transport. Only *then* does it return credit with `l2capCredit`. Thus the client's writer
/// feels the back-pressure of the real transport, and a queue does not fill here.
extension CentralSession {

    /// The largest `l2capData` payload that either end puts on the wire. It is the provider's
    /// chunk size, and a client frame must not exceed it.
    static var maximumChunk: Int { LinkFlowControl.l2capInitialCredit / 4 }

    /// The number of client-written bytes that one channel can have unwritten before this
    /// session stops believing the client.
    ///
    /// The number is a whole credit window plus one chunk of slack. The slack is for the frame
    /// that was already on the wire when the window closed. A client that honors the scheme waits
    /// for `l2capCredit` before it exceeds this number. A client that does not could otherwise
    /// grow the write chain and the provider's memory without bound. Inbound `l2capData` is the
    /// one queue that a client fills entirely at its own pace.
    static var maximumOutstandingWrites: Int { LinkFlowControl.l2capInitialCredit + maximumChunk }

    // MARK: - Open

    /// Completes one `openL2CAPChannel` request. It matches the request to the client's channel id,
    /// registers the bridge, answers the client, and starts the inbound pump. Call it on
    /// ``CentralSession/queue``.
    ///
    /// `didOpenL2CAPChannel` names no open. So a FIFO for each peripheral pairs completions by
    /// arrival order. A completion for an open that was outstanding at disconnect can pair
    /// wrongly. Before the reconnect, it finds an empty FIFO and the session closes its channel.
    /// After the client opens again, it answers the new open with the old transport. The provider
    /// cannot detect this. It is a known limit of passthrough L2CAP on real hardware.
    func bridgeOpenedChannel(_ channel: (any L2CAPChannelRemote)?, error: NSError?, from peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        var queued = pendingOpens[peripheral] ?? []
        let pending = queued.isEmpty ? nil : queued.removeFirst()
        pendingOpens[peripheral] = queued

        guard let pending else {
            // Nothing asked for this channel. It is an open that this session never issued, or
            // an open whose connection the session already discarded. Close it so it does not
            // leak.
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

        // The channel id is the *client's* id. The session takes it unchanged from the request,
        // so two opens can name the same id. An overwrite would orphan the first bridge: every
        // close path iterates ``channels``, so nothing could reach it again. Its pump would keep
        // interleaving frames under an id that now belongs to another channel, and its
        // transport, task, and parked continuation would live for the rest of the session. The
        // session refuses the duplicate and does not touch the channel that is already open
        // under that id.
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

    /// Starts the task that pumps the inbound bytes of `open` onto the link under this end's
    /// credit. The task also reports the end of the stream as `l2capClosed`. Call it on
    /// ``CentralSession/queue``.
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

    /// Splits `data` into pieces of wire size. A backend can hand up a read that is much larger
    /// than one credit window, and a pump that sent it whole would deadlock against a window
    /// that the data could never fit in.
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

    /// Writes `data` to the transport of `channel`. It gives credit to the client when the write
    /// has actually completed. This is the back-pressure signal for which the client's writer
    /// waits.
    ///
    /// The session chains the writes of each channel, so they reach the transport in the order
    /// in which the client sent them, however long any one of them takes. Call it on
    /// ``CentralSession/queue``.
    ///
    /// **The chain is bounded, and so is one frame.** A frame larger than ``maximumChunk`` is
    /// larger than the chunk size on which both ends agreed. A client with more than
    /// ``maximumOutstandingWrites`` bytes unwritten has stopped waiting for the credit that
    /// paces it. In both cases the peer has left the scheme. The link goes, and not this
    /// session's memory.
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

    /// Grants `bytes` of credit to `channel` and wakes its pump. Call it on
    /// ``CentralSession/queue``.
    ///
    /// **The method validates a credit before it applies the credit.** A single grant can never
    /// be zero or negative, and it can never exceed the whole window. The client gives back
    /// exactly what it consumed, and it can never have consumed more than
    /// ``BLESwiftLink/LinkFlowControl/l2capInitialCredit``. Anything else is a protocol
    /// violation, including an addition that would overflow. The peer has stopped following the
    /// scheme. The session closes the channel and does not leave it with a window that could go
    /// negative and block its pump forever.
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

    /// The error with which the session refuses a second open that names a channel id that is
    /// already in use.
    static var l2capDuplicateChannel: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "That L2CAP channel identifier is already open"]
        )
    }

    /// The error with which the session closes a channel when its peer granted a credit that
    /// the scheme does not permit.
    static var l2capCreditRejected: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "The client granted an out-of-range L2CAP credit"]
        )
    }

    /// Closes `channel` at the client's request. It tears down the transport and drops the
    /// bridge. The client already considers the channel gone, so the session does not send
    /// `l2capClosed` back. Call it on ``CentralSession/queue``.
    func closeChannel(_ channel: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let open = channels.removeValue(forKey: channel) else {
            log?("no L2CAP channel \(channel); ignoring l2capClose")
            return
        }
        tearDown(open)
    }

    /// Closes and drops every channel that `predicate` selects, after a disconnect or at the end
    /// of the session. Call it on ``CentralSession/queue``.
    func closeChannels(matching predicate: (OpenChannel) -> Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        let doomed = channels.filter { predicate($0.value) }
        for identifier in doomed.keys { channels.removeValue(forKey: identifier) }
        for open in doomed.values { tearDown(open) }
    }

    /// Cancels the pump of a bridge and its outbound write chain, releases anything that waits
    /// on its credit, and closes the transport.
    ///
    /// **The method drops the write chain. It does not drain it.** `cancel()` reaches only the
    /// *tail* task, and even that task continues, because each link awaits the value of the link
    /// ahead of it and no cancellation interrupts an await. Thus every write that is still in
    /// the chain runs, and each write fails against the transport that this method closes under
    /// it. This is the intended result and not a leak. The channel is out of ``channels`` before
    /// this method runs, so nothing new can join the chain. When the session drops its reference
    /// to the tail, the whole chain goes as those failures unwind it.
    private func tearDown(_ open: OpenChannel) {
        open.pump?.cancel()
        open.pump = nil
        open.writes?.cancel()
        open.writes = nil
        open.releaseWaiter()
        open.remote.close(error: nil)
    }

    // MARK: - Off-queue completions

    /// Whether `channel` still names `open`. Every off-queue completion makes this identity
    /// check before it acts.
    ///
    /// The client chooses a channel id and can reuse it. After the session drops a bridge, the
    /// next open can take the id, while a write or a stream end from the *old* bridge is still in
    /// flight. Without the check, that completion would give credit to, close, or tear down the
    /// live channel that replaced the old bridge. The code captures the bridge that each
    /// completion belongs to when the bridge starts, and never trusts the id alone. Call it on
    /// ``CentralSession/queue``.
    private func isCurrent(_ channel: UInt32, _ open: OpenChannel) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return channels[channel] === open
    }

    /// Sends one event from the pump. It first hops onto ``CentralSession/queue``, which is
    /// serial, so the pump's frames keep their order.
    ///
    /// This method also makes the identity check that every other off-queue completion makes.
    /// The pump checks for cancellation *before* the hop, and a teardown can land in between: it
    /// drops the id, and the id can go to another channel before this code runs. Without the
    /// check, the old bridge's bytes would go on the wire under an id that is no longer its own.
    /// The method is internal so that a test can drive it with a bridge that the session has
    /// already dropped.
    func sendFromPump(_ event: CentralWireEvent, channel: UInt32, open: OpenChannel) {
        queue.async { [self] in
            guard isCurrent(channel, open) else { return }
            send(event)
        }
    }

    /// Releases a completed write's share of the channel's outstanding window, and gives credit
    /// to the client for it.
    private func creditFromWrite(channel: UInt32, open: OpenChannel, bytes: Int) {
        queue.async { [self] in
            guard isCurrent(channel, open) else { return }
            open.outstanding -= bytes
            // A write of nothing consumed no window. The client would not accept `0` as a
            // credit: it treats a non-positive grant as a protocol violation and closes the
            // channel. Clients do not send empty payloads, but a peer that did must not get a
            // frame that tears down its own channel.
            guard bytes > 0 else { return }
            send(.l2capCredit(channel: channel, bytes: bytes))
        }
    }

    /// Reports a failed write as the close of the channel, and drops the bridge.
    private func failFromWrite(channel: UInt32, open: OpenChannel, error: any Error) {
        queue.async { [self] in
            guard isCurrent(channel, open) else { return }
            channels.removeValue(forKey: channel)
            tearDown(open)
            send(.l2capClosed(channel: channel, error: WireError(error as NSError)))
        }
    }

    /// Reports the end of the backend's inbound stream, clean or with `error`. It drops the
    /// bridge. The pump calls it, off ``CentralSession/queue``.
    ///
    /// The write chain goes with it, for the reason that ``tearDown(_:)`` gives. The transport
    /// closes under whatever is still queued. If the tail task stayed alive, it would keep the
    /// chain, and the data that the chain captured, until the write ahead of it fails. The
    /// method drops the pump and does not cancel it, because this *is* the pump that reports its
    /// own end.
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
