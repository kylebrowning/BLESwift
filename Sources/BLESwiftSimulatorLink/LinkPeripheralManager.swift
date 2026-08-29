//
//  LinkPeripheralManager.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// A `PeripheralManaging` backed by a provider process rather than a local
/// `CBPeripheralManager`: every call is encoded as a ``BLESwiftLink/HostRequest`` and sent
/// over one ``LinkClientSession``, and every ``BLESwiftLink/HostWireEvent`` the provider
/// sends back is translated into a `PeripheralHostEvent`.
///
/// Hand one to `PeripheralHost(backend:queue:)`, passing the *same* `DispatchSerialQueue`:
///
/// ```swift
/// let queue = DispatchSerialQueue(label: "ble")
/// let host = PeripheralHost(backend: LinkPeripheralManager(endpoint: endpoint, queue: queue), queue: queue)
/// ```
///
/// The provider hosts this peripheral on its ``VirtualRadio``, so a `Central` in *another*
/// simulator, dialing the same provider through a `LinkCentral`, can scan for it, connect,
/// and hold a full GATT conversation with it.
///
/// **Radio state.** ``radioState`` starts `.unsupported` — a provider that has not answered
/// is indistinguishable from a machine without Bluetooth — and that first `.unsupported` is
/// delivered as soon as an ``eventHandler`` is attached. The provider's own `didUpdateState`
/// replaces it; if the link then drops, the state falls back to `.unsupported`,
/// ``isAdvertising`` becomes `false`, and every subscriber the host had is implicitly gone
/// along with the session that owned them.
///
/// **Notification back-pressure.** ``updateValue(_:for:onSubscribed:)`` returns `false` once
/// ``BLESwiftLink/LinkFlowControl/updateValueWindow`` pushes are in flight unacknowledged,
/// exactly as a full CoreBluetooth transmit queue does; the provider acknowledges each push
/// as its own backend accepts it, and the acknowledgement that reopens the window is
/// reported as `readyToUpdateSubscribers`. A dropped link empties the window — the
/// acknowledgements died with the session that owed them, and pushes made while it is down
/// are dropped unsent, so neither can ever be acknowledged — and the window is emptied again
/// at the reconnect, which is also where a host left blocked by either is released by exactly
/// one `readyToUpdateSubscribers`. Never by the drop itself.
///
/// **Concurrency — queue-confined, not lock-protected.** Identical discipline to
/// ``LinkCentral``: every stored property is `nonisolated(unsafe)`, safe only because every
/// `PeripheralManaging` member asserts `dispatchPrecondition(condition: .onQueue(queue))`
/// and touches state inline, and every event delivery is `queue.async`, never inline.
public final class LinkPeripheralManager: PeripheralManaging, Sendable {

    /// The queue every request, state update, and event delivery is confined to — the same
    /// queue the owning `PeripheralHost` must be constructed with.
    public let queue: DispatchSerialQueue

    /// The client session this manager owns; held strongly for its whole lifetime.
    private let session: LinkClientSession

    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _radioState: CentralState = .unsupported
    nonisolated(unsafe) private var _didDeliverInitialState = false
    nonisolated(unsafe) private var _isAdvertising = false

    /// The sequence number the next ``updateValue(_:for:onSubscribed:)`` is tagged with.
    nonisolated(unsafe) private var _nextSequence: UInt64 = 0

    /// How many pushes have been sent but not yet acknowledged — the occupied part of the
    /// window.
    nonisolated(unsafe) private var _outstandingUpdates = 0

    /// Whether the window was full when the link dropped, so the owning `PeripheralHost` is
    /// waiting on a `readyToUpdateSubscribers` that the dead session's acknowledgements can
    /// never produce. Cleared by the reconnect that answers it.
    nonisolated(unsafe) private var _wasBlockedAtDrop = false

    /// Whether a link that had been established has since dropped, so the next provider state
    /// is a *reconnect* and must clear the window rather than trust it.
    nonisolated(unsafe) private var _isAwaitingReconnect = false

    /// Creates a peripheral manager that drives the provider at `endpoint`, and starts
    /// dialing it immediately. Reconnection is automatic, at `retryInterval`.
    ///
    /// - Parameters:
    ///   - endpoint: The provider's host and port.
    ///   - queue: The serial queue this manager is confined to — the same instance the
    ///     owning `PeripheralHost` is constructed with.
    ///   - clientName: A human-readable name sent in the handshake. The provider both logs
    ///     it and gives it to the hosted device, so it is the name remote centrals see.
    ///     Defaults to the current process's name.
    ///   - codec: The codec used to encode messages. Defaults to
    ///     ``BLESwiftLink/LinkCodec/binaryPropertyList``.
    ///   - retryInterval: How long to wait before redialing after a failure. Defaults to two
    ///     seconds.
    public init(
        endpoint: LinkEndpoint,
        queue: DispatchSerialQueue,
        clientName: String = ProcessInfo.processInfo.processName,
        codec: LinkCodec = .binaryPropertyList,
        retryInterval: Duration = .seconds(2)
    ) {
        self.queue = queue
        self.session = LinkClientSession(
            endpoint: endpoint,
            role: .peripheral,
            clientName: clientName,
            codec: codec,
            queue: queue,
            retryInterval: retryInterval
        )
        // Weak captures: the session is owned by this manager, so a strong capture would be a
        // cycle and `deinit` — which stops the session — would never run.
        session.onDisconnected = { [weak self] _ in self?.handleLinkDropped() }
        session.onMessage = { [weak self] message in self?.handle(message) }
        session.start()
    }

    deinit {
        session.stop()
    }

    /// Whether the provider has accepted the handshake and the link is live.
    public var isProviderConnected: Bool {
        session.isConnected
    }

    /// Stops the session and detaches the event handler. Idempotent, and safe to call from
    /// any thread. Nothing calls it in production; ``deinit`` stops the session on its own.
    public func shutdown() {
        session.stop()
        queue.async { [self] in
            _eventHandler = nil
        }
    }

    // MARK: - PeripheralManaging

    /// The app's Bluetooth authorization status. Always `.allowedAlways`: authorization is
    /// the provider process's concern, and it would have refused the handshake otherwise.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// The provider's last reported radio state, or `.unsupported` while no provider is
    /// connected.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _radioState
    }

    /// Whether the provider's host is currently advertising. `true` from a successful
    /// `didStartAdvertising`, `false` from ``stopAdvertising()`` and from a dropped link.
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _isAdvertising
    }

    /// Receives every `PeripheralHostEvent` translated from the provider's wire events.
    ///
    /// Attaching a handler schedules delivery of the current ``radioState`` — mirroring
    /// CoreBluetooth's `peripheralManagerDidUpdateState(_:)` after a delegate is set, and
    /// making the initial `.unsupported` observable even when the provider is never
    /// reachable.
    public var eventHandler: ((PeripheralHostEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
            guard newValue != nil, !_didDeliverInitialState else { return }
            _didDeliverInitialState = true
            deliver(.didUpdateState(_radioState))
        }
    }

    /// Asks the provider's host to start advertising. Completion arrives as
    /// `didStartAdvertising(error:)`.
    public func startAdvertising(_ advertisement: PeripheralAdvertisement) {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.startAdvertising(
            localName: advertisement.localName,
            services: advertisement.serviceUUIDs.map(\.uuidString)
        ))
    }

    /// Asks the provider's host to stop advertising. Reports no completion of its own, so
    /// ``isAdvertising`` drops here rather than on an acknowledgement.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        _isAdvertising = false
        send(.stopAdvertising)
    }

    /// Asks the provider's host to publish `service`. Completion arrives as
    /// `didAddService(_:error:)`.
    public func add(_ service: GATTService) {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.addService(WireGATTService(service)))
    }

    /// Asks the provider's host to empty its GATT database.
    public func removeAllHostedServices() {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.removeAllServices)
    }

    /// Answers the read or write request `token` identifies, on the provider's host.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.respond(token: token.rawValue, value: value, attError: error?.rawValue))
    }

    /// Pushes `value` for `characteristic` to `centrals` (or every subscriber, when `nil`)
    /// through the provider's host.
    ///
    /// - Returns: `false` — without sending anything — once
    ///   ``BLESwiftLink/LinkFlowControl/updateValueWindow`` pushes are unacknowledged;
    ///   `true` otherwise, having sent the push and claimed a slot in the window.
    public func updateValue(
        _ value: Data,
        for characteristic: CharacteristicIdentifier,
        onSubscribed centrals: [Subscriber]?
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _outstandingUpdates < LinkFlowControl.updateValueWindow else { return false }
        let sequence = _nextSequence
        _nextSequence &+= 1
        _outstandingUpdates += 1
        send(.updateValue(
            sequence: sequence,
            value: value,
            characteristic: WireCharacteristicRef(characteristic),
            centrals: centrals?.map(\.id)
        ))
        return true
    }

    // MARK: - Sending

    /// Sends `request` over the link. Must be called on ``queue``.
    private func send(_ request: HostRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        session.send(.hostRequest(request))
    }

    // MARK: - Link lifecycle

    /// Handles the link dropping after having been established: nothing is advertising any
    /// more, whatever centrals had subscribed are gone with the session that owned them, and
    /// the radio state is unknowable again.
    ///
    /// The notification window is emptied here: every unacknowledged push belonged to a
    /// session that no longer exists, so no `updateValueDelivered` can ever arrive for it and
    /// a surviving count would wedge the window shut. Emptying it here also keeps
    /// ``updateValue(_:for:onSubscribed:)`` answering `true` while the link is down, so a host
    /// pushing into the dark is not wedged either — those pushes are dropped unsent and are
    /// cleared again at the reconnect. A host that was *blocked* at that moment is deliberately
    /// **not** released here: it is about to be told the radio is `.unsupported`, and a
    /// readiness signal against a dead radio would only invite a push that goes nowhere. The
    /// release is deferred to the reconnect.
    private func handleLinkDropped() {
        dispatchPrecondition(condition: .onQueue(queue))
        _isAdvertising = false
        _isAwaitingReconnect = true
        if _outstandingUpdates >= LinkFlowControl.updateValueWindow { _wasBlockedAtDrop = true }
        _outstandingUpdates = 0
        guard _radioState != .unsupported else { return }
        _radioState = .unsupported
        deliver(.didUpdateState(.unsupported))
    }

    /// Routes an inbound message; anything that is not a `PeripheralHost`-role event is not
    /// this client's business.
    private func handle(_ message: LinkMessage) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard case .hostEvent(let event) = message else { return }
        handle(event)
    }

    // MARK: - Wire events

    /// Translates one ``BLESwiftLink/HostWireEvent`` into the state updates it implies
    /// (applied inline) and the `PeripheralHostEvent` it stands for (delivered on the next
    /// queue tick).
    private func handle(_ event: HostWireEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {

        case .didUpdateState(let state):
            // Deliberately does NOT set `_didDeliverInitialState`; see `LinkCentral` for why
            // a provider state landing before a handler exists must not suppress the attach.
            _radioState = state.state
            deliver(.didUpdateState(state.state))
            if _isAwaitingReconnect {
                // The provider is back, with a session — and a queue — of its own. Nothing this
                // client sent to the old one will ever be acknowledged, whether it was in
                // flight at the drop or dropped unsent afterwards, so the window is emptied
                // here too. A host blocked by either can push again, but only a
                // `readyToUpdateSubscribers` will tell it so.
                _isAwaitingReconnect = false
                let wasBlocked = _outstandingUpdates >= LinkFlowControl.updateValueWindow || _wasBlockedAtDrop
                _wasBlockedAtDrop = false
                _outstandingUpdates = 0
                if wasBlocked { deliver(.readyToUpdateSubscribers) }
            }

        case .didStartAdvertising(let error):
            if error == nil { _isAdvertising = true }
            deliver(.didStartAdvertising(error: error?.nsError))

        case .didAddService(let service, let error):
            deliver(.didAddService(ServiceIdentifier(uuid: service), error: error?.nsError))

        case .didReceiveRead(let request):
            deliver(.didReceiveRead(request.readRequest))

        case .didReceiveWrite(let request):
            deliver(.didReceiveWrite(request.writeRequest))

        case .didSubscribe(let central, let characteristic):
            deliver(.didSubscribe(central: central.subscriber, characteristic: characteristic.identifier))

        case .didUnsubscribe(let central, let characteristic):
            deliver(.didUnsubscribe(central: central.subscriber, characteristic: characteristic.identifier))

        case .updateValueDelivered:
            // Consumed, never forwarded: `readyToUpdateSubscribers` is synthesized here from
            // the acknowledgement that reopens a full window, exactly as `LinkCentral`
            // synthesizes write-without-response readiness.
            let wasFull = _outstandingUpdates >= LinkFlowControl.updateValueWindow
            _outstandingUpdates = max(0, _outstandingUpdates - 1)
            if wasFull, _outstandingUpdates < LinkFlowControl.updateValueWindow {
                deliver(.readyToUpdateSubscribers)
            }
        }
    }

    /// Delivers `event` to ``eventHandler`` asynchronously on ``queue``, honoring the seam's
    /// never-inline delivery contract.
    private func deliver(_ event: PeripheralHostEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            _eventHandler?(event)
        }
    }
}
