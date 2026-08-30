//
//  HostSession.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// One accepted peripheral-role link connection, served by one
/// ``BLESwiftCore/PeripheralManaging``.
///
/// The peripheral-role counterpart to ``CentralSession``: every
/// ``BLESwiftLink/HostRequest`` that arrives becomes a `PeripheralManaging` call, and every
/// `PeripheralHostEvent` the backend produces becomes a ``BLESwiftLink/HostWireEvent`` on
/// the way back. Because that backend is a ``VirtualPeripheralManagerBackend``, the client's
/// `PeripheralHost` becomes a device on the provider's ``VirtualRadio`` — which is exactly
/// where another client's ``CentralSession`` is scanning.
///
/// **Two queues, one hop.** Identical to ``CentralSession``: the connection's handlers are
/// delivered on the *listener* queue, the backend is confined to this session's own serial
/// ``queue``, so every inbound request hops once before touching the backend and every
/// outbound event is already on ``queue`` when it arrives.
///
/// **Notification back-pressure.** Pushes are queued FIFO and offered to the backend one at
/// a time. Each one the backend accepts is acknowledged to the client with
/// `updateValueDelivered`, which is what advances the client's own window; a refusal parks
/// the drain until the backend reports `readyToUpdateSubscribers`. The queue is bounded at
/// ``maximumPendingUpdates``: a client that keeps pushing past the window it agreed to loses
/// its link rather than the provider losing its memory. The hosted database is bounded the
/// same way, at ``maximumHostedServices``.
///
/// - Note: The session holds its ``BLESwiftLink/LinkConnection`` strongly, for the same
///   reason ``CentralSession`` does.
final class HostSession: Sendable {

    /// One `updateValue` push waiting for the backend to accept it.
    private struct PendingUpdate {
        let sequence: UInt64
        let value: Data
        let characteristic: CharacteristicIdentifier
        let centrals: [Subscriber]?
    }

    /// How many unsent `updateValue` pushes this session holds before it stops believing the
    /// client.
    ///
    /// Four times the window the client agreed to honor, for the same reason
    /// ``CentralSession/maximumPendingWrites`` is: a client that has stopped waiting for
    /// `updateValueDelivered` can otherwise grow this queue — and the provider's memory —
    /// without bound, and a backend that never reports `readyToUpdateSubscribers` would let
    /// it. The factor of four is slack for the acknowledgements still in flight, not a second
    /// window.
    static let maximumPendingUpdates = 4 * LinkFlowControl.updateValueWindow

    /// How many services one client may publish before this session stops believing it.
    ///
    /// `addService` is the client's other unbounded lever on the provider's memory: each one
    /// is appended to the backend's database — after a linear duplicate scan, so the cost is
    /// quadratic — and every frame may carry up to
    /// ``BLESwiftLink/LinkFraming/maximumPayloadLength`` of characteristic values. Sixty-four
    /// is far past what any real peripheral publishes (CoreBluetooth peripherals run to a
    /// handful) and far short of what a client looping fresh UUIDs would reach in a second.
    /// A client past it has left the protocol behind, and the link goes rather than this
    /// session's memory.
    static let maximumHostedServices = 64

    /// The connection this session serves, held strongly for its whole lifetime.
    private let connection: LinkConnection

    /// The serial queue the backend and every piece of session state are confined to.
    private let queue: DispatchSerialQueue

    /// Receives one line per notable session event.
    private let log: (@Sendable (String) -> Void)?

    /// How this session names itself in the provider's log.
    let label: String

    /// The backend this session drives. `nonisolated(unsafe)` because
    /// `any PeripheralManaging` is not `Sendable`; it is immutable and only ever touched on
    /// ``queue``.
    nonisolated(unsafe) private let backend: any PeripheralManaging

    nonisolated(unsafe) private var pendingUpdates: [PendingUpdate] = []
    nonisolated(unsafe) private var isClosed = false

    /// How many services this client has published, against ``maximumHostedServices``. Reset
    /// by a `removeAllServices`, which empties the database it counts. Session ``queue`` only.
    nonisolated(unsafe) private var hostedServices = 0

    /// Creates a session serving `connection` from `backend`.
    ///
    /// Ordering matches ``CentralSession``: the opening block — the accepted `hello`, the
    /// backend's event handler, the opening `didUpdateState` — is scheduled on `queue` first,
    /// and the session's message handler is then installed synchronously, replaying whatever
    /// the client sent behind its `ClientHello`.
    ///
    /// - Parameters:
    ///   - connection: The accepted link connection, already started.
    ///   - backend: The peripheral-manager backend serving this connection. Must be confined
    ///     to `queue`.
    ///   - queue: This session's own serial queue.
    ///   - ordinal: This session's number, for log lines.
    ///   - hello: The accepted `ServerHello`, written as this session's first frame.
    ///   - install: Hands this session the connection's messages, replaying any that arrived
    ///     behind the hello. Called once, synchronously.
    ///   - log: Receives one line per notable session event.
    init(
        connection: LinkConnection,
        backend: any PeripheralManaging,
        queue: DispatchSerialQueue,
        ordinal: Int,
        hello: ServerHello,
        install: (@escaping @Sendable (LinkMessage) -> Void) -> Void,
        log: (@Sendable (String) -> Void)?
    ) {
        self.connection = connection
        self.backend = backend
        self.queue = queue
        self.label = "host session \(ordinal)"
        self.log = log
        queue.async { [self] in
            guard !isClosed else { return }
            // Nothing may precede the hello on the wire — see `CentralSession`.
            connection.send(.serverHello(hello))
            self.backend.eventHandler = { [weak self] event in self?.translate(event) }
            send(.didUpdateState(WireCentralState(self.backend.radioState)))
            log?("opened \(label) over a \(self.backend is CompositePeripheralManager ? "composite" : "virtual") backend")
        }
        install { [weak self] message in
            guard let self, case .hostRequest(let request) = message else { return }
            self.queue.async {
                do {
                    try self.perform(request)
                } catch {
                    self.failProtocol(error)
                }
            }
        }
    }

    /// Tears the session down: stops advertising, empties the hosted GATT database, detaches
    /// the backend's event handler — which, for a ``VirtualPeripheralManagerBackend``, also
    /// removes the device from the radio, so any central still connected to it sees the
    /// removal — and closes the link connection. Idempotent, and safe to call from any
    /// thread.
    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            backend.stopAdvertising()
            backend.removeAllHostedServices()
            backend.eventHandler = nil
            // Dropped, not acknowledged: the connection is being cancelled, so no
            // `updateValueDelivered` could reach the client anyway — and it does not need one.
            // A client whose link drops empties its own window and fails a blocked host's wait
            // at the drop, so both ends agree without a final exchange.
            let discarded = pendingUpdates.count
            pendingUpdates.removeAll()
            // Nothing to detach on the connection: the provider's table routes its
            // messages, and it drops this session's handler when the link ends — which
            // cancelling it below is what brings about.
            connection.cancel()
            log?("closed \(label), discarding \(discarded) queued update(s)")
        }
    }

    // MARK: - Requests

    /// Applies one request to the backend. Must be called on ``queue``.
    ///
    /// - Throws: ``BLESwiftLink/WireDecodingError`` for a request carrying a field no
    ///   BLESwift type can represent — a malformed UUID string, say — or
    ///   ``ProtocolViolation/unknownATTError(_:)`` for an ATT code no `ATTError` holds. The
    ///   caller treats either as a protocol violation and drops the connection.
    private func perform(_ request: HostRequest) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        switch request {

        case .startAdvertising(let localName, let services):
            backend.startAdvertising(PeripheralAdvertisement(
                localName: localName,
                serviceUUIDs: try services.map { ServiceIdentifier(uuid: try WireIdentifierValidation.validated($0)) }
            ))

        case .stopAdvertising:
            backend.stopAdvertising()

        case .addService(let service):
            // Bounded like every other client-driven queue in this session. Counted here
            // rather than read back from the backend: a composite's children answer for their
            // own databases, and this is the count of what *this client* has published.
            guard hostedServices < Self.maximumHostedServices else {
                failProtocol(ProtocolViolation.hostedServiceLimitExceeded)
                return
            }
            let published = try service.gattService
            backend.add(published)
            hostedServices += 1

        case .removeAllServices:
            hostedServices = 0
            backend.removeAllHostedServices()

        case .respond(let token, let value, let attError):
            // A code no `ATTError` can hold is a malformed field like a malformed UUID, and
            // is refused for the same reason: dropping it would answer the request
            // *successfully* on the client's behalf, turning the failure it asked for into a
            // success the remote central then acts on.
            let error = try attError.map { code in
                guard let error = ATTError(rawValue: code) else {
                    throw ProtocolViolation.unknownATTError(code)
                }
                return error
            }
            backend.respond(to: RequestToken(rawValue: token), value: value, error: error)

        case .updateValue(let sequence, let value, let characteristic, let centrals):
            // A client that keeps queueing past the window it agreed to has stopped following
            // the protocol; the link goes rather than this session's memory.
            guard pendingUpdates.count < Self.maximumPendingUpdates else {
                failProtocol(ProtocolViolation.updateWindowExceeded)
                return
            }
            pendingUpdates.append(PendingUpdate(
                sequence: sequence,
                value: value,
                characteristic: try characteristic.identifier,
                // The client sends identifiers only; the maximum a real subscriber reports is
                // not carried on the wire, so the ATT ceiling stands in for it. Backends match
                // subscribers by `id`, which round-trips exactly.
                centrals: centrals?.map { Subscriber(id: $0, maximumUpdateValueLength: Self.maximumUpdateValueLength) }
            ))
            drainUpdates()
        }
    }

    /// What a client can do that this session refuses to serve.
    enum ProtocolViolation: Error, Equatable {
        /// More `updateValue` pushes were queued than ``maximumPendingUpdates`` allows — the
        /// client has ignored its flow-control window.
        case updateWindowExceeded

        /// A `respond` carried an ATT error code no `ATTError` represents, carried verbatim.
        case unknownATTError(Int)

        /// More services were published than ``maximumHostedServices`` allows — the client is
        /// growing the provider's hosted database without bound.
        case hostedServiceLimitExceeded
    }

    /// Drops the client's link because it sent something the protocol does not allow — a
    /// malformed identifier, or more queued pushes than the window can ever have permitted.
    /// The provider's own termination path then closes this session. Must be called on
    /// ``queue``.
    private func failProtocol(_ error: some Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        log?("\(label): protocol violation (\(error)); closing the connection")
        connection.cancel()
    }

    /// The `maximumUpdateValueLength` reported for a subscriber reconstructed from the wire:
    /// one ATT packet, since that is what a notification is.
    ///
    /// The largest ATT attribute value (512) was the obvious number and the wrong one — it
    /// invited a host to push an update no notification could ever carry, which CoreBluetooth
    /// truncates to ATT_MTU − 3 on device. Matches
    /// ``VirtualRadio/maximumWriteWithoutResponseLength``, which the radio reports to a
    /// device handler for the same reason.
    private static let maximumUpdateValueLength = VirtualRadio.maximumWriteWithoutResponseLength

    /// The `maximumUpdateValueLength` to report for a subscriber whose backend reported one
    /// no caller could divide a payload by: the conservative ATT default, the same number
    /// ``CentralSession`` falls back to for a write maximum.
    private static let defaultMaximumUpdateValueLength = 20

    /// The wire form of `subscriber`, with its `maximumUpdateValueLength` put through the
    /// same rule the client applies on arrival.
    ///
    /// The peripheral-role counterpart to ``CentralSession``'s `reportableMaximum`: the
    /// client runs ``BLESwiftLink/WireLengthValidation`` over whatever lands, and a maximum
    /// it refuses costs it the whole session — so an unusable one costs this *subscriber* its
    /// reported maximum instead. A non-positive maximum is replaced by
    /// ``defaultMaximumUpdateValueLength`` and logged; an implausibly large one is clamped,
    /// exactly as the client clamps it. Must be called on ``queue``.
    ///
    /// - Parameter subscriber: The subscriber the backend reported.
    /// - Returns: A subscriber the client will accept.
    private func reportableSubscriber(_ subscriber: Subscriber) -> WireSubscriber {
        dispatchPrecondition(condition: .onQueue(queue))
        var wire = WireSubscriber(subscriber)
        guard wire.maximumUpdateValueLength > 0 else {
            log?("""
                \(label): subscriber \(subscriber.id) reported maximumUpdateValueLength \
                \(wire.maximumUpdateValueLength); reporting the default
                """)
            wire.maximumUpdateValueLength = Self.defaultMaximumUpdateValueLength
            return wire
        }
        wire.maximumUpdateValueLength = min(wire.maximumUpdateValueLength, WireLengthValidation.maximumLength)
        return wire
    }

    /// The wire form of `request`, with its central's maximum made reportable. Must be called
    /// on ``queue``.
    private func reportableRead(_ request: ReadRequest) -> WireReadRequest {
        dispatchPrecondition(condition: .onQueue(queue))
        var wire = WireReadRequest(request)
        wire.central = reportableSubscriber(request.central)
        return wire
    }

    /// The wire form of `request`, with every entry's central made reportable. Must be called
    /// on ``queue``.
    private func reportableWrite(_ request: WriteRequest) -> WireWriteRequest {
        dispatchPrecondition(condition: .onQueue(queue))
        var wire = WireWriteRequest(request)
        for index in wire.entries.indices {
            wire.entries[index].central = reportableSubscriber(request.entries[index].central)
        }
        return wire
    }

    /// Offers queued pushes to the backend until it refuses one, acknowledging each one it
    /// accepts. Must be called on ``queue``.
    ///
    /// A refused push stays at the head of the queue and is re-offered **verbatim** — same
    /// value, characteristic and subscriber list — as the seam requires, and nothing behind
    /// it is offered first. A push the backend *accepted* is never re-offered: it is dropped
    /// from the queue and acknowledged, so a backend that fans out to several children (a
    /// ``CompositePeripheralManager``) can treat every offer it sees as a new value and
    /// deliver each one exactly once.
    private func drainUpdates() {
        dispatchPrecondition(condition: .onQueue(queue))
        while let next = pendingUpdates.first {
            guard backend.updateValue(next.value, for: next.characteristic, onSubscribed: next.centrals) else {
                // The transmit queue is full; `readyToUpdateSubscribers` resumes the drain.
                log?("\(label): updateValue parked, waiting for readyToUpdateSubscribers (\(pendingUpdates.count) queued)")
                return
            }
            pendingUpdates.removeFirst()
            send(.updateValueDelivered(sequence: next.sequence))
        }
    }

    // MARK: - Events

    /// Translates one ``BLESwiftCore/PeripheralHostEvent`` and sends it. Arrives on
    /// ``queue``, per the backend delivery contract.
    private func translate(_ event: PeripheralHostEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        switch event {

        case .didUpdateState(let state):
            send(.didUpdateState(WireCentralState(state)))

        case .didStartAdvertising(let error):
            send(.didStartAdvertising(error: error.wire))

        case .didAddService(let service, let error):
            send(.didAddService(service: service.uuidString, error: error.wire))

        case .didReceiveRead(let request):
            send(.didReceiveRead(reportableRead(request)))

        case .didReceiveWrite(let request):
            send(.didReceiveWrite(reportableWrite(request)))

        case .didSubscribe(let central, let characteristic):
            send(.didSubscribe(central: reportableSubscriber(central), characteristic: WireCharacteristicRef(characteristic)))

        case .didUnsubscribe(let central, let characteristic):
            send(.didUnsubscribe(central: reportableSubscriber(central), characteristic: WireCharacteristicRef(characteristic)))

        case .readyToUpdateSubscribers:
            // Never forwarded: the client synthesizes its own readiness from the
            // acknowledgements this drain produces.
            drainUpdates()

        case .willRestoreState:
            // State restoration is the provider process's own business — see
            // `CentralSession`'s `willRestoreState`.
            break
        }
    }

    /// Writes one event to the link. Must be called on ``queue``.
    private func send(_ event: HostWireEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.send(.hostEvent(event))
    }
}

/// One live client session, whichever role it serves — the provider's session table holds
/// both kinds and needs nothing from them but the ability to name one and tear it down.
protocol ProviderSession: Sendable {

    /// How this session names itself in the provider's log — its role and ordinal, as in
    /// `"central session 3"`.
    var label: String { get }

    /// Tears the session down and drops its client's link. Idempotent, and safe to call from
    /// any thread.
    func close()
}

extension CentralSession: ProviderSession {}
extension HostSession: ProviderSession {}
#endif
