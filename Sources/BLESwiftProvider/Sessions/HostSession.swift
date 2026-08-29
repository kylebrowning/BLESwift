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
/// the drain until the backend reports `readyToUpdateSubscribers`.
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

    /// The connection this session serves, held strongly for its whole lifetime.
    private let connection: LinkConnection

    /// The serial queue the backend and every piece of session state are confined to.
    private let queue: DispatchSerialQueue

    /// Receives one line per notable session event.
    private let log: (@Sendable (String) -> Void)?

    /// The backend this session drives. `nonisolated(unsafe)` because
    /// `any PeripheralManaging` is not `Sendable`; it is immutable and only ever touched on
    /// ``queue``.
    nonisolated(unsafe) private let backend: any PeripheralManaging

    nonisolated(unsafe) private var pendingUpdates: [PendingUpdate] = []
    nonisolated(unsafe) private var isClosed = false

    /// Creates a session serving `connection` from `backend`.
    ///
    /// Ordering matches ``CentralSession``: the backend's event handler is installed first,
    /// then the connection's message handler, then the opening `didUpdateState` is sent. The
    /// caller must have sent its accepted `ServerHello` first.
    ///
    /// - Parameters:
    ///   - connection: The accepted link connection, already started.
    ///   - backend: The peripheral-manager backend serving this connection. Must be confined
    ///     to `queue`.
    ///   - queue: This session's own serial queue.
    ///   - log: Receives one line per notable session event.
    init(
        connection: LinkConnection,
        backend: any PeripheralManaging,
        queue: DispatchSerialQueue,
        log: (@Sendable (String) -> Void)?
    ) {
        self.connection = connection
        self.backend = backend
        self.queue = queue
        self.log = log
        queue.async { [self] in
            guard !isClosed else { return }
            self.backend.eventHandler = { [weak self] event in self?.translate(event) }
            // Installed only once the backend's own handler exists — see `CentralSession`.
            connection.onMessage = { [weak self] message in
                guard let self, case .hostRequest(let request) = message else { return }
                self.queue.async { self.perform(request) }
            }
            send(.didUpdateState(WireCentralState(self.backend.radioState)))
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
            pendingUpdates.removeAll()
            connection.onMessage = nil
            connection.cancel()
        }
    }

    // MARK: - Requests

    /// Applies one request to the backend. Must be called on ``queue``.
    private func perform(_ request: HostRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        switch request {

        case .startAdvertising(let localName, let services):
            backend.startAdvertising(PeripheralAdvertisement(
                localName: localName,
                serviceUUIDs: services.map(ServiceIdentifier.init(uuid:))
            ))

        case .stopAdvertising:
            backend.stopAdvertising()

        case .addService(let service):
            backend.add(service.gattService)

        case .removeAllServices:
            backend.removeAllHostedServices()

        case .respond(let token, let value, let attError):
            backend.respond(
                to: RequestToken(rawValue: token),
                value: value,
                error: attError.flatMap(ATTError.init(rawValue:))
            )

        case .updateValue(let sequence, let value, let characteristic, let centrals):
            pendingUpdates.append(PendingUpdate(
                sequence: sequence,
                value: value,
                characteristic: characteristic.identifier,
                // The client sends identifiers only; the maximum a real subscriber reports is
                // not carried on the wire, so the ATT ceiling stands in for it. Backends match
                // subscribers by `id`, which round-trips exactly.
                centrals: centrals?.map { Subscriber(id: $0, maximumUpdateValueLength: Self.maximumUpdateValueLength) }
            ))
            drainUpdates()
        }
    }

    /// The `maximumUpdateValueLength` reported for a subscriber reconstructed from the wire:
    /// the largest ATT attribute value, so nothing is truncated on the strength of a number
    /// this session had to invent.
    private static let maximumUpdateValueLength = 512

    /// Offers queued pushes to the backend until it refuses one, acknowledging each one it
    /// accepts. Must be called on ``queue``.
    private func drainUpdates() {
        dispatchPrecondition(condition: .onQueue(queue))
        while let next = pendingUpdates.first {
            guard backend.updateValue(next.value, for: next.characteristic, onSubscribed: next.centrals) else {
                // The transmit queue is full; `readyToUpdateSubscribers` resumes the drain.
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
            send(.didReceiveRead(WireReadRequest(request)))

        case .didReceiveWrite(let request):
            send(.didReceiveWrite(WireWriteRequest(request)))

        case .didSubscribe(let central, let characteristic):
            send(.didSubscribe(central: WireSubscriber(central), characteristic: WireCharacteristicRef(characteristic)))

        case .didUnsubscribe(let central, let characteristic):
            send(.didUnsubscribe(central: WireSubscriber(central), characteristic: WireCharacteristicRef(characteristic)))

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
/// both kinds and needs nothing from them but the ability to tear one down.
protocol ProviderSession: Sendable {
    /// Tears the session down and drops its client's link. Idempotent, and safe to call from
    /// any thread.
    func close()
}

extension CentralSession: ProviderSession {}
extension HostSession: ProviderSession {}
#endif
