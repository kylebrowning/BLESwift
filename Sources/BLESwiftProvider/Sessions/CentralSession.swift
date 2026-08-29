//
//  CentralSession.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// One accepted central-role link connection, served by one ``BLESwiftCore/CentralManaging``.
///
/// A session is the translator sitting between the wire and a backend: every
/// ``BLESwiftLink/CentralRequest`` that arrives becomes a `CentralManaging` or
/// `PeripheralRemote` call, and every `CentralEvent`/`PeripheralEvent` the backend produces
/// becomes a ``BLESwiftLink/CentralWireEvent`` on the way back.
///
/// **Two queues, one hop.** The connection's handlers are delivered on the *listener*
/// queue; the backend and its remotes are confined to this session's own serial ``queue``
/// and assert it. So every inbound request hops once — `queue.async` — before touching the
/// backend, and every outbound event is already on ``queue`` when it arrives and is written
/// straight to the connection, whose `send` serializes internally.
///
/// **Concurrency — queue-confined, not lock-protected.** Every mutable property is
/// `nonisolated(unsafe)` and touched only on ``queue``, exactly as ``VirtualCentralBackend``
/// and ``CompositeCentral`` do.
///
/// - Note: The session holds its ``BLESwiftLink/LinkConnection`` strongly: nothing else
///   does — the listener does not retain what it accepts, and the connection's own receive
///   loop refers to itself weakly.
final class CentralSession: Sendable {

    /// One `.withoutResponse` write waiting for the peripheral to be ready for it.
    private struct PendingWrite {
        let sequence: UInt64
        let characteristic: CharacteristicIdentifier
        let value: Data
    }

    /// One `openL2CAPChannel` request waiting for its completion, so the completion can be
    /// tagged with the channel id the client allocated.
    struct PendingOpen {
        let channel: UInt32
        let psm: UInt16
    }

    /// The `.withResponse` maximum reported for a connection whose remote this session never
    /// saw — CoreBluetooth's own ATT-MTU-derived ceiling, not a zero-length write budget.
    private static let defaultMaximumWriteWithResponse = 182

    /// The `.withoutResponse` maximum reported for a connection whose remote this session
    /// never saw — the conservative default a client assumes before any negotiation.
    private static let defaultMaximumWriteWithoutResponse = 20

    /// How many unsent `.withoutResponse` writes this session holds for one peripheral before
    /// it stops believing the client.
    ///
    /// Four times the window the client agreed to honor: a client that has stopped waiting
    /// for `writeWithoutResponseAccepted` can otherwise grow this queue — and the provider's
    /// memory — without bound, and there is no answer to that but to disbelieve it. The
    /// factor of four is slack for the acknowledgements still in flight, not a second window.
    static let maximumPendingWrites = 4 * LinkFlowControl.writeWithoutResponseWindow

    /// How many `openL2CAPChannel` completions this session waits on for one peripheral before
    /// it stops believing the client.
    ///
    /// A channel open is answered by exactly one completion, and a client with sixteen opens
    /// outstanding on a single peripheral is not waiting on a Bluetooth stack — it is filling
    /// this session's memory with tags nothing will ever consume. Sixteen rather than a
    /// multiple of a window because there is no window here to be slack for: it is simply more
    /// simultaneous opens than any honest client has.
    static let maximumPendingOpens = 16

    /// How many peripheral remotes this session keeps.
    ///
    /// The same 1024 the client's own mirror table is capped at, for the same reason: a
    /// long-lived client that connects across a busy room would otherwise grow this table
    /// without limit, one remote per identifier ever connected.
    static let maximumRemotes = 1024

    /// The error a channel-open completion reports when the backend reported neither a
    /// channel nor an error of its own.
    static var l2capOpenFailed: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "The peripheral reported no L2CAP channel"]
        )
    }

    /// The connection this session serves, held strongly for its whole lifetime.
    private let connection: LinkConnection

    /// The serial queue the backend, its remotes, and every piece of session state are
    /// confined to. Internal rather than private so the L2CAP bridge in
    /// `CentralSession+L2CAP.swift` shares it.
    let queue: DispatchSerialQueue

    /// Receives one line per notable session event. Internal for the same reason as
    /// ``queue``.
    let log: (@Sendable (String) -> Void)?

    /// How this session names itself in the provider's log.
    let label: String

    /// The backend this session drives. `nonisolated(unsafe)` because `any CentralManaging`
    /// is not `Sendable`; it is immutable and only ever touched on ``queue``.
    nonisolated(unsafe) private let backend: any CentralManaging

    /// Every remote this session has connected, keyed by identifier — the object the client's
    /// requests are routed to and whose events are routed back.
    ///
    /// **Bounded, least-recently-connected first.** Mirrors the cap on the client's own
    /// `LinkCentral` table: beyond ``maximumRemotes`` entries the least recently connected are
    /// dropped, and only ones that are `.disconnected` and have nothing of this session's in
    /// flight for them — no queued writes, no channel open awaiting its completion, no bridged
    /// L2CAP channel. Anything else is still referenced by a live operation whose events must
    /// reach the instance the client is talking about, so it is kept however old it is.
    /// Forgetting a remote costs the client nothing it has not already finished with: the next
    /// `connect` retrieves it from the backend again.
    nonisolated(unsafe) private var remotes: [UUID: any PeripheralRemote] = [:]

    /// ``remotes``' keys in least-recently-connected order, which is what the cap evicts from.
    /// Linear to update, over a list bounded by ``maximumRemotes``.
    nonisolated(unsafe) private var connectOrder: [UUID] = []
    nonisolated(unsafe) private var pendingWrites: [UUID: [PendingWrite]] = [:]
    nonisolated(unsafe) var pendingOpens: [UUID: [PendingOpen]] = [:]
    nonisolated(unsafe) private var isClosed = false

    /// The L2CAP channels this session is bridging, keyed by the id the client allocated.
    /// Internal so `CentralSession+L2CAP.swift` can service them.
    nonisolated(unsafe) var channels: [UInt32: OpenChannel] = [:]

    /// Creates a session serving `connection` from `backend`.
    ///
    /// **Ordering.** The session first schedules its own opening work on `queue` — writing
    /// the accepted `hello`, attaching to the backend, and sending the opening
    /// `didUpdateState` — and only then, synchronously, installs its message handler with
    /// `install`. So the hello is still the first frame on the wire, while every request the
    /// client sent behind its `ClientHello` is handed over (and replayed by `install`) with
    /// no window in which it has nowhere to go. Requests reach the backend behind the opening
    /// block because they hop onto the same serial `queue`, which it is already enqueued on.
    ///
    /// - Parameters:
    ///   - connection: The accepted link connection, already started.
    ///   - backend: The central backend serving this connection. Must be confined to `queue`.
    ///   - queue: This session's own serial queue.
    ///   - ordinal: This session's number, for log lines.
    ///   - hello: The accepted `ServerHello`, written as this session's first frame.
    ///   - install: Hands this session the connection's messages, replaying any that arrived
    ///     behind the hello. Called once, synchronously.
    ///   - log: Receives one line per notable session event.
    init(
        connection: LinkConnection,
        backend: any CentralManaging,
        queue: DispatchSerialQueue,
        ordinal: Int,
        hello: ServerHello,
        install: (@escaping @Sendable (LinkMessage) -> Void) -> Void,
        log: (@Sendable (String) -> Void)?
    ) {
        self.connection = connection
        self.backend = backend
        self.queue = queue
        self.label = "central session \(ordinal)"
        self.log = log
        queue.async { [self] in
            guard !isClosed else { return }
            // Nothing may precede the hello on the wire, so it goes out from here — ahead of
            // every event this session can produce — rather than from the provider, which
            // would be racing this block.
            connection.send(.serverHello(hello))
            self.backend.eventHandler = { [weak self] event in self?.translate(event) }
            send(.didUpdateState(WireCentralState(self.backend.radioState)))
        }
        // Weak, because the session owns the connection and a strong capture would be a cycle.
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

    /// Tears the session down: stops the scan, cancels every live connection, detaches every
    /// event handler, and closes the link connection. Idempotent, and safe to call from any
    /// thread.
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
            pendingOpens.removeAll()
            // Nothing to detach on the connection: the provider's table routes its
            // messages, and it drops this session's handler when the link ends — which
            // cancelling it below is what brings about.
            connection.cancel()
        }
    }

    // MARK: - Requests

    /// Applies one request to the backend. Must be called on ``queue``.
    ///
    /// - Throws: ``BLESwiftLink/WireDecodingError`` for a request carrying a field no
    ///   BLESwift type can represent — a malformed UUID string, say. The caller treats it as
    ///   a protocol violation and drops the connection.
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
                // Answered rather than ignored: the client's `connect` is waiting on an
                // event, and an identifier no backend knows will never produce one, so
                // silence would cost it the full connect timeout for a failure that is
                // already certain.
                log?("no remote for peripheral \(peripheral); failing the connect")
                send(.didFailToConnect(peripheral: peripheral, error: WireError(VirtualRadio.unknownDeviceError)))
                return
            }
            remotes[peripheral] = remote
            touch(peripheral)
            evictStaleRemotes()
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

        // Each of these converts *before* looking the remote up: a malformed identifier is a
        // protocol violation whether or not this session happens to know the peripheral it
        // was sent for, and a client that gets away with it for an unknown peripheral would
        // simply be told nothing.
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
            guard let remote = self.remote(peripheral, for: "writeValue") else { return }
            guard type == .withoutResponse else {
                // A `.withResponse` write is acknowledged by `didWriteValue`, so it needs no
                // flow control of its own.
                remote.writeValue(value, for: identifier, type: .withResponse)
                return
            }
            // A client that keeps queueing past the window it agreed to has stopped following
            // the protocol; the link goes rather than this session's memory.
            guard pendingWrites[peripheral, default: []].count < Self.maximumPendingWrites else {
                failProtocol(ProtocolViolation.writeWindowExceeded(peripheral: peripheral))
                return
            }
            pendingWrites[peripheral, default: []].append(
                PendingWrite(sequence: sequence, characteristic: identifier, value: value)
            )
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
            guard let remote = self.remote(peripheral, for: "openL2CAPChannel") else { return }
            // Every open is answered by exactly one completion, so a client with more than
            // this many outstanding on one peripheral has stopped consuming them; the link
            // goes rather than this session's memory.
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

    /// What a client did that the protocol does not permit, beyond the malformed fields the
    /// wire boundary itself rejects.
    enum ProtocolViolation: Error, Equatable {
        /// More `.withoutResponse` writes were queued for one peripheral than
        /// ``maximumPendingWrites`` allows — the client has ignored its flow-control window.
        case writeWindowExceeded(peripheral: UUID)

        /// More `openL2CAPChannel` completions were outstanding for one peripheral than
        /// ``maximumPendingOpens`` allows — the client has stopped consuming them.
        case openWindowExceeded(peripheral: UUID)
    }

    /// `uuid` as a `ServiceIdentifier`, rejecting a string no `ServiceIdentifier` could
    /// represent rather than trapping on it.
    private static func service(_ uuid: String) throws -> ServiceIdentifier {
        ServiceIdentifier(uuid: try WireIdentifierValidation.validated(uuid))
    }

    /// Drops the client's link because it sent something the protocol does not allow — a
    /// malformed identifier, or more queued writes than the window can ever have permitted.
    /// The provider's own termination path then closes this session. Must be called on
    /// ``queue``.
    private func failProtocol(_ error: some Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        log?("\(label): protocol violation (\(error)); closing the connection")
        connection.cancel()
    }

    /// Moves `identifier` to the most-recently-connected end of ``connectOrder``. Must be
    /// called on ``queue``.
    private func touch(_ identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let index = connectOrder.firstIndex(of: identifier) {
            connectOrder.remove(at: index)
        }
        connectOrder.append(identifier)
    }

    /// Drops the least recently connected idle remotes until the table is back within
    /// ``maximumRemotes``, detaching each one's event handler on the way out so a backend that
    /// still holds it cannot deliver into a session that has forgotten it. A remote is idle
    /// only when it is `.disconnected` and this session has nothing in flight for it; anything
    /// else is left alone however old it is. Must be called on ``queue``.
    private func evictStaleRemotes() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard remotes.count > Self.maximumRemotes else { return }
        var overflow = remotes.count - Self.maximumRemotes
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
            // Both are empty — that is what made the remote idle — but the keys would
            // otherwise outlive it, so the side tables stay bounded by this one.
            pendingWrites.removeValue(forKey: identifier)
            pendingOpens.removeValue(forKey: identifier)
            overflow -= 1
        }
        connectOrder = kept
    }

    /// Whether `remote` is disconnected and has nothing of this session's in flight — the one
    /// state in which forgetting it costs the client nothing. Must be called on ``queue``.
    private func isIdle(_ remote: any PeripheralRemote, _ identifier: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard remote.connectionState == .disconnected else { return false }
        // Emptied rather than removed is idle too: a drained queue leaves the key behind.
        guard pendingWrites[identifier]?.isEmpty ?? true, pendingOpens[identifier]?.isEmpty ?? true else {
            return false
        }
        return !channels.values.contains { $0.peripheral == identifier }
    }

    /// The remote for `peripheral`, or `nil` — with a log line — if this session has never
    /// connected it. Must be called on ``queue``.
    private func remote(_ peripheral: UUID, for request: String) -> (any PeripheralRemote)? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let remote = remotes[peripheral] else {
            log?("no remote for peripheral \(peripheral); ignoring \(request)")
            return nil
        }
        return remote
    }

    /// Sends as many queued `.withoutResponse` writes as the peripheral will currently take,
    /// acknowledging each one as it goes. Must be called on ``queue``.
    private func drainWrites(for peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let remote = remotes[peripheral] else { return }
        while let next = pendingWrites[peripheral]?.first, remote.canSendWriteWithoutResponse {
            pendingWrites[peripheral]?.removeFirst()
            remote.writeValue(next.value, for: next.characteristic, type: .withoutResponse)
            send(.writeWithoutResponseAccepted(peripheral: peripheral, sequence: next.sequence))
        }
    }

    // MARK: - Events

    /// Installs the per-peripheral event translator on `remote`. Must be called on ``queue``.
    private func attachHandler(to remote: any PeripheralRemote, for peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        remote.eventHandler = { [weak self] event in self?.translate(event, from: peripheral) }
    }

    /// Translates one backend-level ``BLESwiftCore/CentralEvent`` and sends it. Arrives on
    /// ``queue``, per the backend delivery contract.
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
                maximumWriteWithResponse: remote?.maximumWriteValueLength(for: .withResponse)
                    ?? Self.defaultMaximumWriteWithResponse,
                maximumWriteWithoutResponse: remote?.maximumWriteValueLength(for: .withoutResponse)
                    ?? Self.defaultMaximumWriteWithoutResponse
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
            // State restoration is the provider process's own business: the client's
            // `Central` has its own lifecycle and nothing to restore from this one.
            break
        }
    }

    /// Translates one ``BLESwiftCore/PeripheralEvent`` from `peripheral` and sends it,
    /// enriching each discovery completion from the remote's own caches. Arrives on
    /// ``queue``, per the backend delivery contract.
    private func translate(_ event: PeripheralEvent, from peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, let remote = remotes[peripheral] else { return }
        switch event {

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
            // Never forwarded: the client synthesizes its own readiness from the
            // acknowledgements this drain produces.
            drainWrites(for: peripheral)

        case .didOpenL2CAPChannel(let channel, let error):
            bridgeOpenedChannel(channel, error: error, from: peripheral)
        }
    }

    /// Drops everything that belonged to a connection that has just ended. Must be called on
    /// ``queue``.
    private func discardPerConnectionState(for peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingWrites.removeValue(forKey: peripheral)
        pendingOpens.removeValue(forKey: peripheral)
        // The client tears its own halves down off the disconnect; closing the backend's
        // ends here is what stops their pumps and releases the transports.
        closeChannels(matching: { $0.peripheral == peripheral })
    }

    /// Writes one event to the link. Must be called on ``queue``. Internal so the L2CAP
    /// bridge can answer on the same path.
    func send(_ event: CentralWireEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.send(.centralEvent(event))
    }
}
#endif
