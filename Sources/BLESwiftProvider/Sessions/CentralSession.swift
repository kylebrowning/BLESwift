//
//  CentralSession.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// One accepted central-role link connection. One ``BLESwiftCore/CentralManaging`` serves it.
///
/// A session is the translator between the wire and a backend. Every
/// ``BLESwiftLink/CentralRequest`` that arrives becomes a `CentralManaging` call or a
/// `PeripheralRemote` call. Every `CentralEvent` or `PeripheralEvent` that the backend
/// produces becomes a ``BLESwiftLink/CentralWireEvent`` on the way back.
///
/// **Two queues, one hop.** The connection delivers its handlers on the *listener* queue. The
/// backend and its remotes are confined to the serial ``queue`` of this session, and they assert
/// it. Thus every inbound request hops once, with `queue.async`, before it touches the backend.
/// Every outbound event is already on ``queue`` when it arrives, so the session writes it
/// straight to the connection, whose `send` serializes internally.
///
/// **Concurrency: the queue confines the state, and no lock protects it.** Every mutable
/// property is `nonisolated(unsafe)`. Code touches the properties only on ``queue``. This is
/// the same rule as in ``VirtualCentralBackend`` and ``CompositeCentral``.
///
/// - Note: The session holds its ``BLESwiftLink/LinkConnection`` strongly, and nothing else
///   holds it. The listener does not retain the connections that it accepts, and the
///   connection's receive loop refers to itself weakly.
final class CentralSession: Sendable {

    /// One `.withoutResponse` write that waits until the peripheral is ready for it. It is
    /// internal for the reason that ``pendingWrites`` gives.
    struct PendingWrite {
        let sequence: UInt64
        let characteristic: CharacteristicIdentifier
        let value: Data
    }

    /// One `openL2CAPChannel` request that waits for its completion. It lets the code tag the
    /// completion with the channel id that the client allocated.
    struct PendingOpen {
        let channel: UInt32
        let psm: UInt16
    }

    /// The `.withResponse` maximum that the session reports for a connection whose remote it
    /// never saw. It is the ceiling that CoreBluetooth derives from the ATT MTU.
    private static let defaultMaximumWriteWithResponse = 182

    /// The `.withoutResponse` maximum that the session reports for a connection whose remote it
    /// never saw. It is the conservative default that a client assumes before any negotiation.
    private static let defaultMaximumWriteWithoutResponse = 20

    /// The number of unsent `.withoutResponse` writes that this session parks for one
    /// peripheral. After this number, it gives up on that peripheral's queue.
    ///
    /// This number is much more than the window that a client agreed to honor. A client that
    /// exceeds the window is not necessarily dishonest.
    /// `Central.awaitWriteWithoutResponseReadiness` resumes every parked writer on one readiness
    /// signal, so a few hundred writers can legitimately fire at once, and CoreBluetooth would
    /// queue them. The session parks them and drains them on the backend's readiness.
    ///
    /// A thousand writes for one peripheral is a different case. The client has stopped consuming
    /// acknowledgements altogether. Then *this peripheral's* queue goes, and neither the
    /// provider's memory nor the whole link goes. The session drops those writes and reports
    /// nothing. CoreBluetooth also drops a `.withoutResponse` write that it cannot send.
    static let maximumPendingWrites = 1024

    /// The number of bytes of unsent `.withoutResponse` writes that this session parks for one
    /// peripheral. The session applies the cap that it reaches first.
    ///
    /// ``maximumPendingWrites`` alone bounds the count and not the memory. One frame can carry
    /// up to ``BLESwiftLink/LinkFraming/maximumPayloadLength``, so a thousand frames are much
    /// more than a megabyte.
    static let maximumPendingWriteBytes = 1 << 20

    /// The number of `openL2CAPChannel` completions for which this session waits, for one
    /// peripheral, before it stops believing the client.
    ///
    /// Exactly one completion answers a channel open. A client with sixteen opens outstanding on
    /// one peripheral is not waiting for a Bluetooth stack. It fills this session's memory with
    /// tags that nothing will consume. Sixteen is more simultaneous opens than any honest client
    /// has, and no window exists here to give slack for.
    static let maximumPendingOpens = 16

    /// The number of peripheral remotes that a session keeps by default.
    ///
    /// It is the same 1024 at which the client's mirror table is capped, for the same reason: a
    /// long-lived client can connect across a busy room, and without a cap this table would grow
    /// with one remote for each identifier ever connected. Tests override it, because otherwise
    /// a test must connect a thousand peripherals to force an eviction.
    static let defaultMaximumRemotes = 1024

    /// The error that a channel-open completion reports when the backend reported neither a
    /// channel nor an error of its own.
    static var l2capOpenFailed: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "The peripheral reported no L2CAP channel"]
        )
    }

    /// The connection that this session serves. The session holds it strongly for its whole
    /// lifetime.
    private let connection: LinkConnection

    /// The serial queue to which the backend, its remotes, and all session state are confined.
    /// It is internal so that the L2CAP bridge in `CentralSession+L2CAP.swift` shares it.
    let queue: DispatchQueue

    /// Receives one line for each notable session event. It is internal for the same reason as
    /// ``queue``.
    let log: (@Sendable (String) -> Void)?

    /// How this session names itself in the provider's log.
    let label: String

    /// The backend that this session drives. It is `nonisolated(unsafe)` because
    /// `any CentralManaging` is not `Sendable`. It is immutable. Code touches it only on
    /// ``queue``.
    nonisolated(unsafe) private let backend: any CentralManaging

    /// Every remote that this session has connected, keyed by identifier. The client's requests
    /// go to these objects, and their events come back from them.
    ///
    /// **The table is bounded. The least recently connected remote goes first.** It mirrors the
    /// cap on the client's `LinkCentral` table. When there are more than ``maximumRemotes``
    /// entries, the session drops the least recently connected entries. It drops only remotes
    /// that are `.disconnected` and have nothing of this session in flight: no queued writes, no
    /// channel open that waits for its completion, and no bridged L2CAP channel. Any other remote
    /// stays however old it is, because a live operation still references it and its events must
    /// reach the instance that the client talks about. When the session forgets a remote, the
    /// client loses nothing that it has not finished with. The next `connect` retrieves the
    /// remote from the backend again.
    nonisolated(unsafe) private var remotes: [UUID: any PeripheralRemote] = [:]

    /// The keys of ``remotes`` in order of least recent connection. The cap evicts from this
    /// order. An update is linear, over a list that ``maximumRemotes`` bounds.
    nonisolated(unsafe) private var connectOrder: [UUID] = []

    /// The number of remotes that this session keeps. It is ``defaultMaximumRemotes``, unless a
    /// test asked for a smaller table.
    private let maximumRemotes: Int

    /// The `.withoutResponse` writes that are parked for each peripheral, oldest first. They
    /// count against ``maximumPendingWrites`` and ``maximumPendingWriteBytes``. It is internal so
    /// that a test can watch a burst arrive and does not need to guess when it has arrived. Use
    /// it only on the session ``queue``.
    nonisolated(unsafe) var pendingWrites: [UUID: [PendingWrite]] = [:]

    /// The number of payload bytes that ``pendingWrites`` holds for each peripheral. They count
    /// against ``maximumPendingWriteBytes``. The session keeps this count and does not sum the
    /// bytes at each arrival, because a sum would be quadratic over a queue this long. Use it
    /// only on the session ``queue``.
    nonisolated(unsafe) private var pendingWriteBytes: [UUID: Int] = [:]
    nonisolated(unsafe) var pendingOpens: [UUID: [PendingOpen]] = [:]
    nonisolated(unsafe) private var isClosed = false

    /// The L2CAP channels that this session bridges, keyed by the id that the client allocated.
    /// It is internal so that `CentralSession+L2CAP.swift` can service them.
    nonisolated(unsafe) var channels: [UInt32: OpenChannel] = [:]

    /// Creates a session that serves `connection` from `backend`.
    ///
    /// **Ordering.** The initializer first schedules the opening work on `queue`. That work writes
    /// `hello`, attaches to the backend, and sends the first `didUpdateState`. Then the
    /// initializer calls `install` synchronously. Thus the hello is the first frame. `install`
    /// replays the requests that arrived behind the `ClientHello`. They hop onto the same serial
    /// `queue`, behind the opening work.
    ///
    /// - Parameters:
    ///   - connection: The accepted link connection. It is already started.
    ///   - backend: The central backend that serves this connection. It must be confined to
    ///     `queue`.
    ///   - queue: This session's own serial queue.
    ///   - ordinal: The number of this session, for log lines.
    ///   - hello: The accepted `ServerHello`. The session writes it as its first frame.
    ///   - install: Gives this session the connection's messages. It replays any message that
    ///     arrived behind the hello. The initializer calls it once, synchronously.
    ///   - log: Receives one line for each notable session event.
    ///   - maximumRemotes: The number of peripheral remotes that this session keeps.
    init(
        connection: LinkConnection,
        backend: any CentralManaging,
        queue: DispatchQueue,
        ordinal: Int,
        hello: ServerHello,
        install: (@escaping @Sendable (LinkMessage) -> Void) -> Void,
        log: (@Sendable (String) -> Void)?,
        maximumRemotes: Int = CentralSession.defaultMaximumRemotes
    ) {
        self.connection = connection
        self.backend = backend
        self.queue = queue
        self.maximumRemotes = maximumRemotes
        self.label = "central session \(ordinal)"
        self.log = log
        queue.async { [self] in
            guard !isClosed else { return }
            // Nothing can precede the hello on the wire, so it goes out from here, ahead of every
            // event that this session can produce. It does not go out from the provider, because
            // the provider would race with this block.
            connection.send(.serverHello(hello))
            self.backend.eventHandler = { [weak self] event in self?.translate(event) }
            send(.didUpdateState(WireCentralState(self.backend.radioState)))
        }
        // The capture is weak. The session owns the connection, and a strong capture would be a
        // cycle.
        install { [weak self] message in
            guard let self, case .centralRequest(let request) = message else { return }
            self.queue.async {
                do {
                    try self.perform(request)
                } catch {
                    self.failProtocol(error)
                }
            }
        }
    }

    /// Tears the session down. It stops the scan, cancels every live connection, detaches every
    /// event handler, and closes the link connection. Repeated calls are safe. It is safe to
    /// call from any thread.
    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            backend.stopScan()
            for remote in remotes.values where remote.connectionState != .disconnected {
                backend.cancelPeripheralConnection(remote)
            }
            backend.unregisterForConnectionEvents()
            for remote in remotes.values {
                remote.eventHandler = nil
            }
            backend.eventHandler = nil
            closeChannels(matching: { _ in true })
            remotes.removeAll()
            connectOrder.removeAll()
            pendingWrites.removeAll()
            pendingWriteBytes.removeAll()
            pendingOpens.removeAll()
            // There is nothing to detach on the connection. The provider's table routes its
            // messages and drops this session's handler when the link ends. The cancel below
            // ends the link.
            connection.cancel()
        }
    }

    // MARK: - Requests

    /// Applies one request to the backend. Call it on ``queue``.
    ///
    /// - Throws: ``BLESwiftLink/WireDecodingError`` for a request that carries a field that no
    ///   BLESwift type can represent, for example a malformed UUID string. The caller treats this
    ///   as a protocol violation and drops the connection.
    private func perform(_ request: CentralRequest) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        switch request {

        case .scan(let services, let allowDuplicates):
            backend.scanForPeripherals(
                withServices: try services?.map(Self.service(_:)),
                options: ScanOptions(allowDuplicates: allowDuplicates)
            )

        case .stopScan:
            backend.stopScan()

        case .connect(let peripheral, let options, let requiresANCS):
            guard let remote = backend.retrievePeripherals(withIdentifiers: [peripheral]).first else {
                // Answer, and do not ignore. The client's `connect` waits for an event, and no
                // backend knows the identifier, so no event would come. The client would wait for
                // the full connect timeout for a failure that is already certain.
                log?("no remote for peripheral \(peripheral); failing the connect")
                send(.didFailToConnect(peripheral: peripheral, error: WireError(VirtualRadio.unknownDeviceError)))
                return
            }
            // Evict *before* the insert and never after. The session has only just filed a
            // remote, which is disconnected with nothing in flight, so the cap would call it
            // idle. If a table is full of busy remotes, an overflow would then drop the very
            // peripheral that the session connects. `LinkCentral.connect` fixes the same ordering
            // when it marks its mirror as connecting first. The session reserves a slot for the
            // insert, so the table still settles at `maximumRemotes`.
            evictStaleRemotes(reserving: remotes[peripheral] == nil ? 1 : 0)
            remotes[peripheral] = remote
            touch(peripheral)
            attachHandler(to: remote, for: peripheral)
            backend.connect(remote, options: options?.warningOptions, requiresANCS: requiresANCS)

        case .cancelConnection(let peripheral):
            guard let remote = self.remote(peripheral, for: "cancelConnection") else { return }
            backend.cancelPeripheralConnection(remote)

        case .registerForConnectionEvents(let services, let peripherals):
            backend.registerForConnectionEvents(
                services: try services?.map(Self.service(_:)),
                peripherals: peripherals
            )

        case .unregisterForConnectionEvents:
            backend.unregisterForConnectionEvents()

        // Each of these cases converts *before* it looks up the remote. A malformed identifier
        // is a protocol violation even when this session does not know the peripheral for which
        // the client sent it. Otherwise a client could get away with it for an unknown
        // peripheral, and the session would tell it nothing.
        case .discoverServices(let peripheral, let services):
            let requested = try services?.map(Self.service(_:))
            guard let remote = self.remote(peripheral, for: "discoverServices") else { return }
            remote.discoverServices(requested)

        case .discoverCharacteristics(let peripheral, let service, let characteristics):
            let identifier = try Self.service(service)
            let requested = try characteristics?.map {
                CharacteristicIdentifier(uuid: try WireIdentifierValidation.validated($0), service: identifier)
            }
            guard let remote = self.remote(peripheral, for: "discoverCharacteristics") else { return }
            remote.discoverCharacteristics(requested, for: identifier)

        case .readValue(let peripheral, let characteristic):
            let identifier = try characteristic.identifier
            guard let remote = self.remote(peripheral, for: "readValue") else { return }
            remote.readValue(for: identifier)

        case .writeValue(let peripheral, let characteristic, let value, let type, let sequence):
            let identifier = try characteristic.identifier
            guard let remote = self.remote(peripheral, for: "writeValue") else {
                // Drop the write, but still acknowledge it. A `.withoutResponse` write uses a
                // slot in the client's window until `writeWithoutResponseAccepted` reopens it.
                // Without the acknowledgement, the client would lose that slot for the life of the
                // session, and enough lost slots would block its writer for good. A `.withResponse`
                // write has no window to reopen: `didWriteValue` answers its caller, or the
                // disconnect that follows an unreachable peripheral answers it.
                if type == .withoutResponse {
                    send(.writeWithoutResponseAccepted(peripheral: peripheral, sequence: sequence))
                }
                return
            }
            guard type == .withoutResponse else {
                // `didWriteValue` acknowledges a `.withResponse` write, so it needs no flow
                // control of its own.
                remote.writeValue(value, for: identifier, type: .withResponse)
                return
            }
            // Park the write, however far past its window the client is. Writers that one
            // readiness signal releases together are honest, and CoreBluetooth would queue them.
            // Only a queue past both caps shows a client that has stopped consuming
            // acknowledgements. Then this peripheral's queue goes and not the link. The session
            // drops it silently, as it always drops a `.withoutResponse` write.
            guard pendingWrites[peripheral, default: []].count < Self.maximumPendingWrites,
                  pendingWriteBytes[peripheral, default: 0] + value.count <= Self.maximumPendingWriteBytes else {
                discardPendingWrites(for: peripheral, including:
                    PendingWrite(sequence: sequence, characteristic: identifier, value: value))
                return
            }
            pendingWrites[peripheral, default: []].append(
                PendingWrite(sequence: sequence, characteristic: identifier, value: value)
            )
            pendingWriteBytes[peripheral, default: 0] += value.count
            drainWrites(for: peripheral)

        case .setNotifyValue(let peripheral, let characteristic, let enabled):
            let identifier = try characteristic.identifier
            guard let remote = self.remote(peripheral, for: "setNotifyValue") else { return }
            remote.setNotifyValue(enabled, for: identifier)

        case .discoverDescriptors(let peripheral, let characteristic):
            let identifier = try characteristic.identifier
            guard let remote = self.remote(peripheral, for: "discoverDescriptors") else { return }
            remote.discoverDescriptors(for: identifier)

        case .readDescriptor(let peripheral, let descriptor):
            let identifier = try descriptor.identifier
            guard let remote = self.remote(peripheral, for: "readDescriptor") else { return }
            remote.readValue(for: identifier)

        case .writeDescriptor(let peripheral, let descriptor, let value):
            let identifier = try descriptor.identifier
            guard let remote = self.remote(peripheral, for: "writeDescriptor") else { return }
            remote.writeValue(value, for: identifier)

        case .readRSSI(let peripheral):
            guard let remote = self.remote(peripheral, for: "readRSSI") else { return }
            remote.readRSSI()

        case .openL2CAPChannel(let peripheral, let psm, let channel):
            guard let remote = self.remote(peripheral, for: "openL2CAPChannel") else {
                // Answer, and do not ignore, as `.connect` does. The client's open waits for a
                // completion, and this session has no remote for the peripheral, so none would
                // come. The caller would wait for its whole open timeout, and the client's
                // half-channel would stay filed until then.
                send(.didOpenL2CAPChannel(
                    peripheral: peripheral,
                    channel: channel,
                    psm: psm,
                    error: WireError(VirtualRadio.unknownDeviceError)
                ))
                return
            }
            // Exactly one completion answers every open. A client with more opens than this
            // outstanding on one peripheral has stopped consuming them. The link goes, and not
            // this session's memory.
            guard pendingOpens[peripheral, default: []].count < Self.maximumPendingOpens else {
                failProtocol(ProtocolViolation.openWindowExceeded(peripheral: peripheral))
                return
            }
            pendingOpens[peripheral, default: []].append(PendingOpen(channel: channel, psm: psm))
            remote.openL2CAPChannel(L2CAPPSM(psm))

        case .l2capData(let channel, let data):
            write(data, to: channel)

        case .l2capCredit(let channel, let bytes):
            grantCredit(bytes, to: channel)

        case .l2capClose(let channel):
            closeChannel(channel)
        }
    }

    /// The client actions that the protocol does not permit, in addition to the malformed fields
    /// that the wire boundary rejects.
    enum ProtocolViolation: Error, Equatable {
        /// More `openL2CAPChannel` completions than ``maximumPendingOpens`` allows were
        /// outstanding for one peripheral. The client has stopped consuming them.
        case openWindowExceeded(peripheral: UUID)

        /// A `l2capData` frame was larger than the chunk size to which both ends chunk. See
        /// ``maximumChunk``.
        case l2capFrameTooLarge(channel: UInt32, bytes: Int)

        /// More client-written bytes than ``maximumOutstandingWrites`` allows were unwritten on
        /// one channel. The client has ignored its credit window.
        case l2capWriteWindowExceeded(channel: UInt32)
    }

    /// `uuid` as a `ServiceIdentifier`. The method rejects a string that no `ServiceIdentifier`
    /// could represent and does not trap on it.
    private static func service(_ uuid: String) throws -> ServiceIdentifier {
        ServiceIdentifier(uuid: try WireIdentifierValidation.validated(uuid))
    }

    /// Drops the client's link because the client sent something that the protocol does not
    /// allow, such as a malformed identifier or more outstanding channel opens than any honest
    /// client has. The provider's termination path then closes this session. Call it on
    /// ``queue``. It is internal so that the L2CAP bridge can refuse a client on the same
    /// terms.
    func failProtocol(_ error: some Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        log?("\(label): protocol violation (\(error)); closing the connection")
        connection.cancel()
    }

    /// Moves `identifier` to the most recently connected end of ``connectOrder``. Call it on
    /// ``queue``.
    private func touch(_ identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let index = connectOrder.firstIndex(of: identifier) {
            connectOrder.remove(at: index)
        }
        connectOrder.append(identifier)
    }

    /// Drops the least recently connected idle remotes until the table is within
    /// ``maximumRemotes`` again. It detaches each remote's event handler on the way out, so a
    /// backend that still holds the remote cannot deliver into a session that has forgotten it.
    /// A remote is idle only when it is `.disconnected` and this session has nothing in flight
    /// for it. The method leaves any other remote alone however old it is. Call it on ``queue``.
    ///
    /// - Parameter reserving: The number of slots that the caller is about to fill. The method
    ///   keeps these slots free, in addition to the entries that are already in the table.
    private func evictStaleRemotes(reserving: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        let limit = maximumRemotes - reserving
        guard remotes.count > limit else { return }
        var overflow = remotes.count - limit
        var kept: [UUID] = []
        kept.reserveCapacity(connectOrder.count)
        for identifier in connectOrder {
            guard let candidate = remotes[identifier] else { continue }
            guard overflow > 0, isIdle(candidate, identifier) else {
                kept.append(identifier)
                continue
            }
            candidate.eventHandler = nil
            remotes.removeValue(forKey: identifier)
            // Both are empty, and that is what made the remote idle. The keys would otherwise
            // outlive the remote, so this table bounds the side tables.
            pendingWrites.removeValue(forKey: identifier)
            pendingWriteBytes.removeValue(forKey: identifier)
            pendingOpens.removeValue(forKey: identifier)
            overflow -= 1
        }
        connectOrder = kept
    }

    /// Whether `remote` is disconnected and has nothing of this session in flight. This is the
    /// one state in which the client loses nothing if the session forgets the remote. Call it on
    /// ``queue``.
    private func isIdle(_ remote: any PeripheralRemote, _ identifier: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard remote.connectionState == .disconnected else { return false }
        // A queue that is emptied but not removed is idle too, because a drained queue leaves
        // its key behind.
        guard pendingWrites[identifier]?.isEmpty ?? true, pendingOpens[identifier]?.isEmpty ?? true else {
            return false
        }
        return !channels.values.contains { $0.peripheral == identifier }
    }

    /// The write maximum to put on the wire for `peripheral`, given what the backend reported.
    ///
    /// The client applies ``BLESwiftLink/WireLengthValidation`` to whatever arrives, and a
    /// maximum that it refuses costs it the whole session. Thus the session applies the same
    /// rule before it sends the value. If a backend reports an unusable maximum, only the
    /// connection loses its negotiated maxima and the session continues. A non-positive maximum
    /// is one that no caller could divide a payload by, and the conservative default replaces
    /// it. The method clamps a maximum that is too large to be plausible, as the client clamps
    /// it.
    ///
    /// - Parameters:
    ///   - reported: What the remote reported. The value is `nil` when this session has no
    ///     remote.
    ///   - fallback: The default for this write type.
    ///   - type: The name of the write type, for the log line.
    ///   - peripheral: The peripheral for which the remote reported the maximum, for the log
    ///     line.
    /// - Returns: A maximum that the client will accept. Call it on ``queue``.
    private func reportableMaximum(
        _ reported: Int?,
        default fallback: Int,
        for type: String,
        peripheral: UUID
    ) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let reported else { return fallback }
        guard reported > 0 else {
            log?("peripheral \(peripheral) reported \(type) maximum \(reported); reporting the default")
            return fallback
        }
        return min(reported, WireLengthValidation.maximumLength)
    }

    /// The remote for `peripheral`. The value is `nil`, with a log line, if this session never
    /// connected it. Call it on ``queue``.
    private func remote(_ peripheral: UUID, for request: String) -> (any PeripheralRemote)? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let remote = remotes[peripheral] else {
            log?("no remote for peripheral \(peripheral); ignoring \(request)")
            return nil
        }
        return remote
    }

    /// Sends as many queued `.withoutResponse` writes as the peripheral can take now. It
    /// acknowledges each write as it sends it. Call it on ``queue``.
    private func drainWrites(for peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let remote = remotes[peripheral] else { return }
        while let next = pendingWrites[peripheral]?.first, remote.canSendWriteWithoutResponse {
            pendingWrites[peripheral]?.removeFirst()
            pendingWriteBytes[peripheral] = max(0, (pendingWriteBytes[peripheral] ?? 0) - next.value.count)
            remote.writeValue(next.value, for: next.characteristic, type: .withoutResponse)
            send(.writeWithoutResponseAccepted(peripheral: peripheral, sequence: next.sequence))
        }
    }

    /// Gives up on everything that is queued for `peripheral`, and on the write that would not
    /// fit. It tells the client. Call it on ``queue``.
    ///
    /// The session still *acknowledges* each discarded write. A `.withoutResponse` write uses a
    /// slot in the client's window until `writeWithoutResponseAccepted` reopens it, and enough
    /// unreturned slots block its writer for good. For the same reason, the session acknowledges
    /// a write that it cannot route and does not drop it in silence.
    ///
    /// **The session reports nothing else.** A `.withoutResponse` write has no completion in
    /// CoreBluetooth. The payload is dropped and the caller is told nothing, as for a write that
    /// is too large for one packet on a device. A synthesized `didWriteValue` would put an event
    /// on the wire that no real write of this type produces. A client with a live
    /// `.withResponse` write outstanding on the same characteristic would take it for that
    /// write's completion. The discard is a fault of the provider, and the provider logs it.
    ///
    /// - Parameters:
    ///   - peripheral: The peripheral whose queue the session gives up on.
    ///   - including: The write that did not fit. The session discards it with the other
    ///     writes.
    private func discardPendingWrites(for peripheral: UUID, including overflow: PendingWrite) {
        dispatchPrecondition(condition: .onQueue(queue))
        let discarded = (pendingWrites.removeValue(forKey: peripheral) ?? []) + [overflow]
        pendingWriteBytes.removeValue(forKey: peripheral)
        log?(
            "\(label): discarding \(discarded.count) queued write(s) for peripheral \(peripheral); "
                + "the client queued past \(Self.maximumPendingWrites) writes or "
                + "\(Self.maximumPendingWriteBytes) bytes without consuming its acknowledgements"
        )
        for write in discarded {
            send(.writeWithoutResponseAccepted(peripheral: peripheral, sequence: write.sequence))
        }
    }

    // MARK: - Events

    /// Installs the translator for one peripheral's events on `remote`. Call it on ``queue``.
    private func attachHandler(to remote: any PeripheralRemote, for peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        remote.eventHandler = { [weak self] event in self?.translate(event, from: peripheral) }
    }

    /// Translates one backend-level ``BLESwiftCore/CentralEvent`` and sends it. The event arrives
    /// on ``queue``, as the backend's delivery contract states.
    private func translate(_ event: CentralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        switch event {

        case .didUpdateState(let state):
            send(.didUpdateState(WireCentralState(state)))

        case .didDiscover(let peripheral, let advertisement, let rssi):
            send(.didDiscover(
                peripheral: peripheral.uuid,
                name: peripheral.name,
                advertisement: WireAdvertisement(advertisement),
                rssi: rssi
            ))

        case .didConnect(let peripheral):
            let remote = remotes[peripheral.uuid]
            if remote == nil {
                log?("no remote for peripheral \(peripheral.uuid); reporting default write maxima")
            }
            send(.didConnect(
                peripheral: peripheral.uuid,
                name: remote?.name ?? peripheral.name,
                maximumWriteWithResponse: reportableMaximum(
                    remote?.maximumWriteValueLength(for: .withResponse),
                    default: Self.defaultMaximumWriteWithResponse,
                    for: "withResponse",
                    peripheral: peripheral.uuid
                ),
                maximumWriteWithoutResponse: reportableMaximum(
                    remote?.maximumWriteValueLength(for: .withoutResponse),
                    default: Self.defaultMaximumWriteWithoutResponse,
                    for: "withoutResponse",
                    peripheral: peripheral.uuid
                )
            ))

        case .didFailToConnect(let peripheral, let error):
            discardPerConnectionState(for: peripheral.uuid)
            send(.didFailToConnect(peripheral: peripheral.uuid, error: error.wire))

        case .didDisconnect(let peripheral, let error):
            discardPerConnectionState(for: peripheral.uuid)
            send(.didDisconnect(peripheral: peripheral.uuid, error: error.wire))

        case .connectionEventDidOccur(let peripheral, let kind):
            send(.connectionEventDidOccur(peripheral: peripheral, connected: kind == .peerConnected))

        case .didUpdateANCSAuthorization(let peripheral, let authorized):
            send(.didUpdateANCSAuthorization(peripheral: peripheral, authorized: authorized))

        case .willRestoreState:
            // State restoration belongs to the provider process. The client's `Central` has its
            // own lifecycle and nothing to restore from this one.
            break
        }
    }

    /// Translates one ``BLESwiftCore/PeripheralEvent`` from `peripheral` and sends it. It adds
    /// data to each discovery completion from the remote's caches. The event arrives on
    /// ``queue``, as the backend's delivery contract states.
    private func translate(_ event: PeripheralEvent, from peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, let remote = remotes[peripheral] else { return }
        switch event {

        // The completion carries the backend's whole service cache, not the answer to the
        // request that produced it. `discoveredServices` is `CBPeripheral.services` for the
        // passthrough backend and the union cache for the virtual backend. Thus a filtered
        // discovery reports every service that is known. The client's rule for filtered joins
        // then folds this list into its mirror, and the two halves of the seam agree on the
        // same list.
        case .didDiscoverServices(let error):
            send(.didDiscoverServices(
                peripheral: peripheral,
                services: remote.discoveredServices.map(\.uuidString),
                error: error.wire
            ))

        case .didDiscoverCharacteristics(let service, let error):
            let discovered = remote.discoveredCharacteristics(for: service).map {
                WireDiscoveredCharacteristic(uuid: $0.uuidString, properties: remote.properties(of: $0).rawValue)
            }
            send(.didDiscoverCharacteristics(
                peripheral: peripheral,
                service: service.uuidString,
                characteristics: discovered,
                error: error.wire
            ))

        case .didDiscoverDescriptors(let characteristic, let error):
            send(.didDiscoverDescriptors(
                peripheral: peripheral,
                characteristic: WireCharacteristicRef(characteristic),
                descriptors: remote.discoveredDescriptors(for: characteristic).map(\.uuidString),
                error: error.wire
            ))

        case .didWriteValue(let characteristic, let error):
            send(.didWriteValue(
                peripheral: peripheral,
                characteristic: WireCharacteristicRef(characteristic),
                error: error.wire
            ))

        case .didUpdateValue(let characteristic, let value, let error):
            send(.didUpdateValue(
                peripheral: peripheral,
                characteristic: WireCharacteristicRef(characteristic),
                value: value,
                error: error.wire
            ))

        case .didUpdateNotificationState(let characteristic, let isNotifying, let error):
            send(.didUpdateNotificationState(
                peripheral: peripheral,
                characteristic: WireCharacteristicRef(characteristic),
                isNotifying: isNotifying,
                error: error.wire
            ))

        case .didUpdateValueForDescriptor(let descriptor, let value, let error):
            send(.didUpdateValueForDescriptor(
                peripheral: peripheral,
                descriptor: WireDescriptorRef(descriptor),
                value: value,
                error: error.wire
            ))

        case .didWriteValueForDescriptor(let descriptor, let error):
            send(.didWriteValueForDescriptor(
                peripheral: peripheral,
                descriptor: WireDescriptorRef(descriptor),
                error: error.wire
            ))

        case .didReadRSSI(let rssi, let error):
            send(.didReadRSSI(peripheral: peripheral, rssi: rssi, error: error.wire))

        case .didModifyServices(let services):
            send(.didModifyServices(peripheral: peripheral, invalidated: services.map(\.uuidString)))

        case .isReadyToSendWriteWithoutResponse:
            // Never forward it. The client synthesizes its own readiness from the
            // acknowledgements that this drain produces.
            drainWrites(for: peripheral)

        case .didOpenL2CAPChannel(let channel, let error):
            bridgeOpenedChannel(channel, error: error, from: peripheral)
        }
    }

    /// Drops everything that belonged to a connection that just ended. Call it on ``queue``.
    private func discardPerConnectionState(for peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingWrites.removeValue(forKey: peripheral)
        pendingWriteBytes.removeValue(forKey: peripheral)
        // Drop it and do not remember it. The backend can still deliver a completion for an
        // open that this connection issued. That completion finds no pending open, and the
        // session closes its channel. See ``CentralSession/bridgeOpenedChannel(_:error:from:)``
        // for what this cannot catch.
        pendingOpens.removeValue(forKey: peripheral)
        // The client tears down its own halves when it sees the disconnect. Closing the
        // backend's ends here stops their pumps and releases the transports.
        closeChannels(matching: { $0.peripheral == peripheral })
    }

    /// Writes one event to the link. Call it on ``queue``. It is internal so that the L2CAP
    /// bridge can answer on the same path.
    func send(_ event: CentralWireEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.send(.centralEvent(event))
    }
}
#endif
