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
/// ``BLESwiftCore/PeripheralManaging``. It is the counterpart of ``CentralSession``.
///
/// Each ``BLESwiftLink/HostRequest`` becomes a `PeripheralManaging` call. Each
/// `PeripheralHostEvent` becomes a ``BLESwiftLink/HostWireEvent``. The backend is a
/// ``VirtualPeripheralManagerBackend``, so the client's `PeripheralHost` becomes a device on the
/// provider's ``VirtualRadio``.
///
/// The queue rules are the same as in ``CentralSession``. Each inbound request hops once from the
/// listener queue onto ``queue``.
///
/// **Back-pressure.** The session queues pushes in FIFO order and offers them to the backend one
/// at a time. It sends `updateValueDelivered` for each accepted push. If the backend refuses, the
/// drain parks until `readyToUpdateSubscribers`. The queue is bounded at ``maximumPendingUpdates``.
/// A client that pushes past it loses its link. The hosted database is bounded at
/// ``maximumHostedServices``.
///
/// - Note: The session holds its ``BLESwiftLink/LinkConnection`` strongly, as ``CentralSession``
///   does.
final class HostSession: Sendable {

    /// One `updateValue` push that waits until the backend accepts it.
    private struct PendingUpdate {
        let sequence: UInt64
        let value: Data
        let characteristic: CharacteristicIdentifier
        let centrals: [Subscriber]?
    }

    /// The number of unsent `updateValue` pushes that this session holds before it stops
    /// believing the client.
    ///
    /// The number is four times the window that the client agreed to honor. A client that has
    /// stopped waiting for `updateValueDelivered` could otherwise grow this queue, and the
    /// provider's memory, without bound if the backend never reports `readyToUpdateSubscribers`.
    /// The factor of four is slack for the acknowledgements that are still in flight. It is not
    /// a second window. ``CentralSession/maximumPendingWrites`` parks a burst of honest writers,
    /// but a push past this number has no such explanation: the client gets one acknowledgement
    /// for each push and cannot have run ahead of them by accident.
    static let maximumPendingUpdates = 4 * LinkFlowControl.updateValueWindow

    /// The number of services that one client can publish before this session stops believing
    /// it.
    ///
    /// `addService` is the other unbounded lever of the client on the provider's memory. The
    /// session appends each service to the backend's database after a linear scan for
    /// duplicates, so the cost is quadratic, and every frame can carry up to
    /// ``BLESwiftLink/LinkFraming/maximumPayloadLength`` of characteristic values. Sixty-four
    /// is much more than the few services that a real peripheral publishes, and much less than
    /// a client that loops over new UUIDs would reach in one second. A client past this number
    /// has left the protocol. The link goes, and not this session's memory.
    static let maximumHostedServices = 64

    /// The connection that this session serves. The session holds it strongly for its whole
    /// lifetime.
    private let connection: LinkConnection

    /// The serial queue to which the backend and all session state are confined.
    private let queue: DispatchQueue

    /// Receives one line for each notable session event.
    private let log: (@Sendable (String) -> Void)?

    /// How this session names itself in the provider's log.
    let label: String

    /// The backend that this session drives. It is `nonisolated(unsafe)` because
    /// `any PeripheralManaging` is not `Sendable`. It is immutable. Code touches it only on
    /// ``queue``.
    nonisolated(unsafe) private let backend: any PeripheralManaging

    nonisolated(unsafe) private var pendingUpdates: [PendingUpdate] = []
    nonisolated(unsafe) private var isClosed = false

    /// The number of services that this client has published or waits to have published. It
    /// counts against ``maximumHostedServices``.
    ///
    /// An `addService` request raises the count. The `didAddService` that *refuses* the add
    /// (a duplicate identifier, or a device already removed from the radio) lowers it again.
    /// Thus the count measures the database that this session really grows and not the client's
    /// attempts. If the count included attempts alone, a client could add one service
    /// sixty-four times, be told each time that it is a duplicate, and still lose its link over
    /// a database that holds one service. If the count included only *accepted* completions,
    /// the bound would be lost: the backend publishes asynchronously, so a burst of new
    /// services all pass the guard before any completion lands. A `removeAllServices` resets
    /// the count, because it empties the database that the count measures. Use it only on the
    /// session ``queue``.
    nonisolated(unsafe) private var hostedServices = 0

    /// Creates a session that serves `connection` from `backend`.
    ///
    /// The ordering is the same as in ``CentralSession``. The initializer first schedules the
    /// opening block on `queue`. The opening block has the accepted `hello`, the backend's event
    /// handler, and the first `didUpdateState`. The initializer then installs the session's
    /// message handler synchronously. The installation replays whatever the client sent behind
    /// its `ClientHello`.
    ///
    /// - Parameters:
    ///   - connection: The accepted link connection. It is already started.
    ///   - backend: The peripheral-manager backend that serves this connection. It must be
    ///     confined to `queue`.
    ///   - queue: This session's own serial queue.
    ///   - ordinal: The number of this session, for log lines.
    ///   - hello: The accepted `ServerHello`. The session writes it as its first frame.
    ///   - install: Gives this session the connection's messages. It replays any message that
    ///     arrived behind the hello. The initializer calls it once, synchronously.
    ///   - log: Receives one line for each notable session event.
    init(
        connection: LinkConnection,
        backend: any PeripheralManaging,
        queue: DispatchQueue,
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
            // Nothing can precede the hello on the wire. See `CentralSession`.
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

    /// Tears the session down. It stops advertising, empties the hosted GATT database, and
    /// takes the hosted device off the radio, so any central that is still connected to the
    /// device sees the removal. It detaches the backend's event handler and closes the link
    /// connection. Repeated calls are safe. It is safe to call from any thread.
    ///
    /// The method asks for the removal outright and does not take it as a side effect of the
    /// detach. Clearing the handler of a ``VirtualPeripheralManagerBackend`` only detaches the
    /// backend. This is what lets a composite clear and install its
    /// children again.
    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            backend.stopAdvertising()
            backend.removeAllHostedServices()
            (backend as? any HostedDeviceRemoving)?.removeHostedDevice()
            backend.eventHandler = nil
            // Drop the pending updates and do not acknowledge them. The code cancels the
            // connection, so no `updateValueDelivered` could reach the client, and the client
            // does not need one. When a client's link drops, the client empties its own window
            // and fails the wait of a blocked host at the drop. Thus both ends agree without a
            // final exchange.
            let discarded = pendingUpdates.count
            pendingUpdates.removeAll()
            // There is nothing to detach on the connection. The provider's table routes its
            // messages and drops this session's handler when the link ends. The cancel below
            // ends the link.
            connection.cancel()
            log?("closed \(label), discarding \(discarded) queued update(s)")
        }
    }

    // MARK: - Requests

    /// Applies one request to the backend. Call it on ``queue``.
    ///
    /// - Throws: ``BLESwiftLink/WireDecodingError`` for a request that carries a field that no
    ///   BLESwift type can represent, for example a malformed UUID string. Also throws
    ///   ``ProtocolViolation/unknownATTError(_:)`` for an ATT code that no `ATTError` holds. The
    ///   caller treats either error as a protocol violation and drops the connection.
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
            // The session bounds this queue as it bounds every other queue that the client
            // drives. It counts here and does not read the count back from the backend, because
            // the children of a composite answer for their own databases. This is the count of
            // what *this client* has published. The count rises now, before the backend has
            // answered, and a refused `didAddService` gives the slot back. Thus an add that
            // never reached the database does not hold a slot against the cap.
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
            // A code that no `ATTError` can hold is a malformed field, as a malformed UUID is,
            // and the session refuses it for the same reason. If the session dropped the code, it
            // would answer the request *successfully* on behalf of the client. The failure that
            // the client asked for would become a success, and the remote central would act on
            // that success.
            let error = try attError.map { code in
                guard let error = ATTError(rawValue: code) else {
                    throw ProtocolViolation.unknownATTError(code)
                }
                return error
            }
            backend.respond(to: RequestToken(rawValue: token), value: value, error: error)

        case .updateValue(let sequence, let value, let characteristic, let centrals):
            // A client that keeps queueing past the window on which it agreed has stopped
            // following the protocol. The link goes, and not this session's memory.
            guard pendingUpdates.count < Self.maximumPendingUpdates else {
                failProtocol(ProtocolViolation.updateWindowExceeded)
                return
            }
            pendingUpdates.append(PendingUpdate(
                sequence: sequence,
                value: value,
                characteristic: try characteristic.identifier,
                // The client sends identifiers only, and the wire does not carry the maximum
                // that a real subscriber reports. Thus the ATT ceiling replaces it. Backends
                // match subscribers by `id`, which round-trips exactly.
                centrals: centrals?.map { Subscriber(id: $0, maximumUpdateValueLength: Self.maximumUpdateValueLength) }
            ))
            drainUpdates()
        }
    }

    /// The client actions that this session refuses to serve.
    enum ProtocolViolation: Error, Equatable {
        /// The session queued more `updateValue` pushes than ``maximumPendingUpdates`` allows.
        /// The client has ignored its flow-control window.
        case updateWindowExceeded

        /// A `respond` carried an ATT error code that no `ATTError` represents. The code is
        /// carried unchanged.
        case unknownATTError(Int)

        /// The client published more services than ``maximumHostedServices`` allows. It grows
        /// the provider's hosted database without bound.
        case hostedServiceLimitExceeded
    }

    /// Drops the client's link because the client sent something that the protocol does not
    /// allow, such as a malformed identifier or more queued pushes than the window can ever have
    /// permitted. The provider's termination path then closes this session. Call it on
    /// ``queue``.
    private func failProtocol(_ error: some Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        log?("\(label): protocol violation (\(error)); closing the connection")
        connection.cancel()
    }

    /// The `maximumUpdateValueLength` that the session reports for a subscriber that it
    /// reconstructed from the wire. It is one ATT packet, because a notification is one ATT
    /// packet.
    ///
    /// The largest ATT attribute value (512) would invite a host to push an update that no
    /// notification can carry. On a device, CoreBluetooth truncates such an update to
    /// ATT_MTU - 3. This value matches ``VirtualRadio/maximumWriteWithoutResponseLength``,
    /// which the radio reports to a device handler for the same reason.
    private static let maximumUpdateValueLength = VirtualRadio.maximumWriteWithoutResponseLength

    /// The `maximumUpdateValueLength` to report for a subscriber whose backend reported a value
    /// by which no caller could divide a payload. It is the conservative ATT default, the same
    /// number to which ``CentralSession`` falls back for a write maximum.
    private static let defaultMaximumUpdateValueLength = 20

    /// The wire form of `subscriber`. The method puts its `maximumUpdateValueLength` through the
    /// rule that the client applies on arrival.
    ///
    /// This is the peripheral-role counterpart of `reportableMaximum` in ``CentralSession``. The
    /// client runs ``BLESwiftLink/WireLengthValidation`` over whatever lands, and a maximum that
    /// it refuses costs it the whole session. Thus an unusable maximum costs only this
    /// *subscriber* its reported maximum. The method replaces a non-positive maximum with
    /// ``defaultMaximumUpdateValueLength`` and logs it. It clamps a maximum that is too large to
    /// be plausible, as the client clamps it. Call it on ``queue``.
    ///
    /// - Parameter subscriber: The subscriber that the backend reported.
    /// - Returns: A subscriber that the client will accept.
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

    /// The wire form of `request`, with its central's maximum made reportable. Call it on
    /// ``queue``.
    private func reportableRead(_ request: ReadRequest) -> WireReadRequest {
        dispatchPrecondition(condition: .onQueue(queue))
        var wire = WireReadRequest(request)
        wire.central = reportableSubscriber(request.central)
        return wire
    }

    /// The wire form of `request`, with every entry's central made reportable. Call it on
    /// ``queue``.
    private func reportableWrite(_ request: WriteRequest) -> WireWriteRequest {
        dispatchPrecondition(condition: .onQueue(queue))
        var wire = WireWriteRequest(request)
        for index in wire.entries.indices {
            wire.entries[index].central = reportableSubscriber(request.entries[index].central)
        }
        return wire
    }

    /// Offers queued pushes to the backend until it refuses one. It acknowledges each push that
    /// the backend accepts. Call it on ``queue``.
    ///
    /// A refused push stays at the head of the queue. The session offers it again **unchanged**
    /// (the same value, characteristic, and subscriber list), as the seam requires, and offers
    /// nothing behind it first. The session never offers a push again that the backend
    /// *accepted*: it drops the push from the queue and acknowledges it. Thus a backend that fans
    /// out to several children, such as a ``CompositePeripheralManager``, can treat every offer
    /// as a new value and deliver each value exactly once.
    private func drainUpdates() {
        dispatchPrecondition(condition: .onQueue(queue))
        while let next = pendingUpdates.first {
            guard backend.updateValue(next.value, for: next.characteristic, onSubscribed: next.centrals) else {
                // The transmit queue is full. `readyToUpdateSubscribers` resumes the drain.
                log?("\(label): updateValue parked, waiting for readyToUpdateSubscribers (\(pendingUpdates.count) queued)")
                return
            }
            pendingUpdates.removeFirst()
            send(.updateValueDelivered(sequence: next.sequence))
        }
    }

    // MARK: - Events

    /// Translates one ``BLESwiftCore/PeripheralHostEvent`` and sends it. The event arrives on
    /// ``queue``, as the backend's delivery contract states.
    private func translate(_ event: PeripheralHostEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        switch event {

        case .didUpdateState(let state):
            send(.didUpdateState(WireCentralState(state)))

        case .didStartAdvertising(let error):
            send(.didStartAdvertising(error: error.wire))

        case .didAddService(let service, let error):
            // A refusal published nothing, so the slot that the request took goes back. The
            // count has a floor of zero, because a `removeAllServices` can empty the count while
            // this add is still in flight.
            if error != nil {
                hostedServices = max(0, hostedServices - 1)
            }
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
            // Never forward it. The client synthesizes its own readiness from the
            // acknowledgements that this drain produces.
            drainUpdates()

        case .willRestoreState:
            // State restoration belongs to the provider process. See the `willRestoreState` case
            // in `CentralSession`.
            break
        }
    }

    /// Writes one event to the link. Call it on ``queue``.
    private func send(_ event: HostWireEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.send(.hostEvent(event))
    }
}

/// One live client session, for either role. The provider's session table holds both kinds. It
/// needs only two things from them: to name one and to tear it down.
protocol ProviderSession: Sendable {

    /// How this session names itself in the provider's log. It uses its role and its ordinal, as
    /// in `"central session 3"`.
    var label: String { get }

    /// Tears the session down and drops its client's link. Repeated calls are safe. It is safe
    /// to call from any thread.
    func close()
}

extension CentralSession: ProviderSession {}
extension HostSession: ProviderSession {}
#endif
