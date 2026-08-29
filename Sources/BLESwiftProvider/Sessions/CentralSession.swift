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

    nonisolated(unsafe) private var remotes: [UUID: any PeripheralRemote] = [:]
    nonisolated(unsafe) private var pendingWrites: [UUID: [PendingWrite]] = [:]
    nonisolated(unsafe) var pendingOpens: [UUID: [PendingOpen]] = [:]
    nonisolated(unsafe) private var isClosed = false

    /// The L2CAP channels this session is bridging, keyed by the id the client allocated.
    /// Internal so `CentralSession+L2CAP.swift` can service them.
    nonisolated(unsafe) var channels: [UInt32: OpenChannel] = [:]

    /// Creates a session serving `connection` from `backend`.
    ///
    /// The session installs itself as the connection's message handler immediately, then
    /// schedules — on `queue` — attaching to the backend and sending the opening
    /// `didUpdateState`. The caller must have sent its accepted `ServerHello` first: nothing
    /// may precede it on the wire.
    ///
    /// - Parameters:
    ///   - connection: The accepted link connection, already started.
    ///   - backend: The central backend serving this connection. Must be confined to `queue`.
    ///   - queue: This session's own serial queue.
    ///   - ordinal: This session's number, for log lines.
    ///   - log: Receives one line per notable session event.
    init(
        connection: LinkConnection,
        backend: any CentralManaging,
        queue: DispatchSerialQueue,
        ordinal: Int,
        log: (@Sendable (String) -> Void)?
    ) {
        self.connection = connection
        self.backend = backend
        self.queue = queue
        self.label = "central session \(ordinal)"
        self.log = log
        queue.async { [self] in
            guard !isClosed else { return }
            self.backend.eventHandler = { [weak self] event in self?.translate(event) }
            // Installed only once the backend's own handler exists, so no request can reach
            // the backend before its events have somewhere to go. Nothing is lost by the
            // wait: `Provider.handle` sends the `ServerHello` *before* it constructs this
            // session, and a client sends nothing until it has processed that hello — a
            // round trip that cannot beat the single `queue.async` this block is enqueued
            // by. Weak, because the session owns the connection and a strong capture would
            // be a cycle.
            connection.onMessage = { [weak self] message in
                guard let self, case .centralRequest(let request) = message else { return }
                self.queue.async { self.perform(request) }
            }
            send(.didUpdateState(WireCentralState(self.backend.radioState)))
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
            pendingWrites.removeAll()
            pendingOpens.removeAll()
            connection.onMessage = nil
            connection.cancel()
        }
    }

    // MARK: - Requests

    /// Applies one request to the backend. Must be called on ``queue``.
    private func perform(_ request: CentralRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        switch request {

        case .scan(let services, let allowDuplicates):
            backend.scanForPeripherals(
                withServices: services?.map(ServiceIdentifier.init(uuid:)),
                options: ScanOptions(allowDuplicates: allowDuplicates)
            )

        case .stopScan:
            backend.stopScan()

        case .connect(let peripheral, let options, let requiresANCS):
            guard let remote = backend.retrievePeripherals(withIdentifiers: [peripheral]).first else {
                log?("no remote for peripheral \(peripheral); ignoring connect")
                return
            }
            remotes[peripheral] = remote
            attachHandler(to: remote, for: peripheral)
            backend.connect(remote, options: options?.warningOptions, requiresANCS: requiresANCS)

        case .cancelConnection(let peripheral):
            guard let remote = self.remote(peripheral, for: "cancelConnection") else { return }
            backend.cancelPeripheralConnection(remote)

        case .registerForConnectionEvents(let services, let peripherals):
            backend.registerForConnectionEvents(
                services: services?.map(ServiceIdentifier.init(uuid:)),
                peripherals: peripherals
            )

        case .unregisterForConnectionEvents:
            backend.unregisterForConnectionEvents()

        case .discoverServices(let peripheral, let services):
            guard let remote = self.remote(peripheral, for: "discoverServices") else { return }
            remote.discoverServices(services?.map(ServiceIdentifier.init(uuid:)))

        case .discoverCharacteristics(let peripheral, let service, let characteristics):
            guard let remote = self.remote(peripheral, for: "discoverCharacteristics") else { return }
            let identifier = ServiceIdentifier(uuid: service)
            remote.discoverCharacteristics(
                characteristics?.map { CharacteristicIdentifier(uuid: $0, service: identifier) },
                for: identifier
            )

        case .readValue(let peripheral, let characteristic):
            guard let remote = self.remote(peripheral, for: "readValue") else { return }
            remote.readValue(for: characteristic.identifier)

        case .writeValue(let peripheral, let characteristic, let value, let type, let sequence):
            guard let remote = self.remote(peripheral, for: "writeValue") else { return }
            guard type == .withoutResponse else {
                // A `.withResponse` write is acknowledged by `didWriteValue`, so it needs no
                // flow control of its own.
                remote.writeValue(value, for: characteristic.identifier, type: .withResponse)
                return
            }
            pendingWrites[peripheral, default: []].append(
                PendingWrite(sequence: sequence, characteristic: characteristic.identifier, value: value)
            )
            drainWrites(for: peripheral)

        case .setNotifyValue(let peripheral, let characteristic, let enabled):
            guard let remote = self.remote(peripheral, for: "setNotifyValue") else { return }
            remote.setNotifyValue(enabled, for: characteristic.identifier)

        case .discoverDescriptors(let peripheral, let characteristic):
            guard let remote = self.remote(peripheral, for: "discoverDescriptors") else { return }
            remote.discoverDescriptors(for: characteristic.identifier)

        case .readDescriptor(let peripheral, let descriptor):
            guard let remote = self.remote(peripheral, for: "readDescriptor") else { return }
            remote.readValue(for: descriptor.identifier)

        case .writeDescriptor(let peripheral, let descriptor, let value):
            guard let remote = self.remote(peripheral, for: "writeDescriptor") else { return }
            remote.writeValue(value, for: descriptor.identifier)

        case .readRSSI(let peripheral):
            guard let remote = self.remote(peripheral, for: "readRSSI") else { return }
            remote.readRSSI()

        case .openL2CAPChannel(let peripheral, let psm, let channel):
            guard let remote = self.remote(peripheral, for: "openL2CAPChannel") else { return }
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
