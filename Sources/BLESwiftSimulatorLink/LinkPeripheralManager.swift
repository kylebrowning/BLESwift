//
//  LinkPeripheralManager.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import Logging

/// A `PeripheralManaging` backed by a provider process rather than a local
/// `CBPeripheralManager`: every call is encoded as a `HostRequest` and sent
/// over one `LinkClientSession`, and every `HostWireEvent` the provider
/// sends back is translated into a `PeripheralHostEvent`.
///
/// Hand one to `PeripheralHost(backend:queue:)`, passing the *same* `DispatchSerialQueue`:
///
/// ```swift
/// let queue = DispatchSerialQueue(label: "ble")
/// let host = PeripheralHost(backend: LinkPeripheralManager(endpoint: endpoint, queue: queue), queue: queue)
/// ```
///
/// The provider hosts this peripheral on its `VirtualRadio`, so a `Central` in *another*
/// simulator, dialing the same provider through a `LinkCentral`, can scan for it, connect,
/// and hold a full GATT conversation with it.
///
/// **Radio state.** ``radioState`` starts `.unsupported` — a provider that has not answered
/// is indistinguishable from a machine without Bluetooth — and that first `.unsupported` is
/// delivered as soon as an ``eventHandler`` is attached. The provider's own `didUpdateState`
/// replaces it; if the link then drops, the state falls back to `.unsupported`,
/// ``isAdvertising`` becomes `false`, and every subscriber the host had is reported gone with
/// a synthesized `didUnsubscribe`. The subscribers really are gone — they belonged to the
/// provider session that just died, and a reconnect mints fresh `Subscriber`
/// ids — so a host left holding them would be pushing at centrals that no longer exist.
///
/// **Notification back-pressure.** ``updateValue(_:for:onSubscribed:)`` returns `false` once
/// `LinkFlowControl.updateValueWindow` pushes are in flight unacknowledged,
/// exactly as a full CoreBluetooth transmit queue does; the provider acknowledges each push
/// as its own backend accepts it, and the acknowledgement that reopens the window is
/// reported as `readyToUpdateSubscribers`. A dropped link empties the window — the
/// acknowledgements died with the session that owed them, and pushes made while it is down
/// are dropped unsent, so neither can ever be acknowledged — and the window is emptied again
/// at the reconnect. A host blocked on the window when the link drops is released by the drop
/// itself, with `bluetoothUnavailable`: a drop from any state but `.unsupported`
/// delivers `didUpdateState(.unsupported)`, and `PeripheralHost` fails every parked readiness
/// waiter on any state but `.poweredOn`. The single `readyToUpdateSubscribers` at the
/// reconnect is the backstop for a waiter that parked while the radio was already
/// `.unsupported` — a drop from that state delivers no state change — not the release path
/// for the drop.
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

    /// The identity this manager asks every provider to host its device under. Minted once,
    /// per instance, and sent on every hello — the opening one and every reconnect's.
    private let hostIdentifier: UUID

    /// Where a provider that refused ``hostIdentifier`` is reported. The only thing worth
    /// saying here: nothing else in this manager has an outcome the caller cannot already see.
    private static let logger = Logger(label: "BLESwiftSimulatorLink.LinkPeripheralManager")

    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _radioState: CentralState = .unsupported
    nonisolated(unsafe) private var _didDeliverInitialState = false
    nonisolated(unsafe) private var _isAdvertising = false

    /// How many ``startAdvertising(_:)`` requests are still outstanding: sent, not yet
    /// answered by a `didStartAdvertising`, and not cancelled by a ``stopAdvertising()``
    /// behind them.
    ///
    /// It exists because the provider answers a start it has already stopped again. A start
    /// and a stop sent on one queue turn are applied in that order over there — leaving the
    /// hosted device silent — but the start's completion is minted from inside the start and
    /// arrives here *after* the stop was sent. Latching ``isAdvertising`` on for that
    /// completion left this manager claiming a radio the provider had already quieted, and
    /// `PeripheralHost.startAdvertising(_:)` early-returns on the flag, so the host could
    /// never advertise again for the life of the session. A stop zeroes the count instead,
    /// and a completion with no start behind it is delivered — a host awaiting one must not
    /// hang — without claiming the radio. `VirtualPeripheralManagerBackend` answers the same
    /// race by making both writes from its serial chain; a client that owns neither the radio
    /// nor the ordering counts the starts it has outstanding.
    nonisolated(unsafe) private var _outstandingStarts = 0

    /// The subscribers this manager has delivered a `didSubscribe` for and not yet a
    /// `didUnsubscribe`, per characteristic — the host's subscriber table, mirrored.
    ///
    /// It exists only so a dropped link can be answered with the `didUnsubscribe` the dead
    /// provider will never send. Keyed by ``BLESwiftCore/Subscriber`` id so a repeat
    /// `didSubscribe` for the same central refreshes rather than duplicates it.
    nonisolated(unsafe) private var _subscribers: [CharacteristicIdentifier: [UUID: Subscriber]] = [:]

    /// The sequence number the next ``updateValue(_:for:onSubscribed:)`` is tagged with.
    nonisolated(unsafe) private var _nextSequence: UInt64 = 0

    /// The sequences of the pushes this manager has sent and not yet been acknowledged for,
    /// oldest first — the occupied part of the window. An array rather than a `Set`, for
    /// `LinkPeripheral`'s reasons: it never holds more than a window's worth, order makes a
    /// stale acknowledgement obvious in a debugger, and a linear scan of that many elements is
    /// cheaper than hashing.
    nonisolated(unsafe) private var _outstandingUpdates: [UInt64] = []

    /// Whether the window was full when the link dropped. A host blocked on it at a drop from
    /// any state but `.unsupported` has already been failed with `bluetoothUnavailable` by the `.unsupported`
    /// state change; this flag arms the reconnect to emit one `readyToUpdateSubscribers` for
    /// the waiter that case cannot reach — one parked before a drop taken from an
    /// already-`.unsupported` radio, which delivers no state change to fail it, and whose
    /// window is emptied here with the waiter still parked. Cleared by the reconnect that
    /// emits it.
    nonisolated(unsafe) private var _wasBlockedAtDrop = false

    /// Whether the next provider state is a *reconnect* and must clear the window rather than
    /// trust it.
    ///
    /// Starts `true`, so the *first* provider connection is treated as a reconnect too: a host
    /// that filled the window before the link ever came up parked its pushes against no
    /// provider at all, and nothing will ever acknowledge them. That is the same
    /// unacknowledgeable state a drop leaves behind, and it is cleared the same way — by the
    /// connection that answers it.
    nonisolated(unsafe) private var _isAwaitingReconnect = true

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
    ///     `LinkCodec.binaryPropertyList`.
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
        // One identity per manager, sent on every hello this session makes: the provider hosts
        // the device under it, so a link drop and its reconnect leave the same device on the
        // radio rather than a fresh one every central would have to rediscover.
        let hostIdentifier = UUID()
        self.hostIdentifier = hostIdentifier
        self.session = LinkClientSession(
            endpoint: endpoint,
            role: .peripheral,
            clientName: clientName,
            hostIdentifier: hostIdentifier,
            codec: codec,
            queue: queue,
            retryInterval: retryInterval
        )
        // Weak captures: the session is owned by this manager, so a strong capture would be a
        // cycle and `deinit` — which stops the session — would never run.
        session.onConnected = { hello in
            // A provider that hosted this device under something other than what was asked for
            // has refused the identity — because one of its own devices holds it — and every
            // reconnect will ask again and be refused again. The client cannot repair that, so
            // it says so: to every central this host looks like a device that keeps changing
            // its identifier, and this line is the only place that is explained.
            guard let assigned = hello.assignedHostIdentifier, assigned != hostIdentifier else { return }
            Self.logger.warning(
                """
                The provider refused host identifier \(hostIdentifier) and is hosting this \
                peripheral as \(assigned); centrals will see it as a different device
                """
            )
        }
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

    /// Stops the session, then runs the teardown a dropped link runs — every subscriber
    /// reported as departing and the state dropped to `.unsupported` — and detaches the event
    /// handler a turn behind it. Idempotent, and safe to call from any thread. Nothing calls it in production;
    /// `deinit` stops the session on its own.
    ///
    /// **The teardown runs before the handler goes, and the handler goes a turn behind it**,
    /// for the reason ``LinkCentral/shutdown()`` gives: the session is marked stopped before
    /// its connection reaches a terminal state, so `onDisconnected` never fires, and a host
    /// awaiting `add(_:)` or `startAdvertising(_:)` was stranded rather than failed.
    public func shutdown() {
        session.stop()
        queue.async { [self] in
            handleLinkDropped()
            queue.async { [self] in
                _eventHandler = nil
            }
        }
    }

    /// Drops the live link, exactly as a transport failure does, and lets the session redial
    /// under the same `hostIdentifier`.
    ///
    /// Test-only: production code has no reason to drop a healthy link. It exists so a test
    /// can produce the reconnect that races a provider session's teardown against its
    /// successor's registration — the one thing a provider restart cannot reproduce, since
    /// that takes the whole radio with it.
    package func dropLinkForTesting() {
        session.dropConnection()
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
    /// `didStartAdvertising` for a start that is still outstanding, `false` from
    /// ``stopAdvertising()`` and from a dropped link — both of which cancel every outstanding
    /// start, so the completion of one the provider has already stopped again cannot latch
    /// this back on. See `_outstandingStarts`.
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
        _outstandingStarts += 1
        send(.startAdvertising(
            localName: advertisement.localName,
            services: advertisement.serviceUUIDs.map(\.uuidString)
        ))
    }

    /// Asks the provider's host to stop advertising. Reports no completion of its own, so
    /// ``isAdvertising`` drops here rather than on an acknowledgement.
    ///
    /// It also cancels every start still outstanding: the provider applies this stop behind
    /// them, so the completion any of them still owes describes a radio this call has since
    /// quieted. See `_outstandingStarts`.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        _isAdvertising = false
        _outstandingStarts = 0
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
    ///   `LinkFlowControl.updateValueWindow` pushes are unacknowledged;
    ///   `true` otherwise, having sent the push and claimed a slot in the window.
    public func updateValue(
        _ value: Data,
        for characteristic: CharacteristicIdentifier,
        onSubscribed centrals: [Subscriber]?
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _outstandingUpdates.count < LinkFlowControl.updateValueWindow else { return false }
        let sequence = _nextSequence
        _nextSequence &+= 1
        _outstandingUpdates.append(sequence)
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
    /// more, every central that had subscribed is reported unsubscribed, and the radio state
    /// is unknowable again.
    ///
    /// The subscribers are synthesized rather than left standing because nothing else will
    /// ever retract them: the provider that owed the `didUnsubscribe` is gone, and the one
    /// that replaces it mints new ``BLESwiftCore/Subscriber`` ids for whoever resubscribes. A
    /// host that kept the old ones would push at centrals that cannot receive.
    ///
    /// The notification window is emptied here: every unacknowledged push belonged to a
    /// session that no longer exists, so no `updateValueDelivered` can ever arrive for it and
    /// a surviving count would wedge the window shut. Emptying it here also keeps
    /// ``updateValue(_:for:onSubscribed:)`` answering `true` while the link is down, so a host
    /// pushing into the dark is not wedged either — those pushes are dropped unsent and are
    /// cleared again at the reconnect. No `readyToUpdateSubscribers` is emitted here — a
    /// readiness signal against a dead radio would only invite a push that goes nowhere. A
    /// host that was *blocked* at that moment is released all the same, by the
    /// `didUpdateState(.unsupported)` delivered below when the radio was not already `.unsupported`:
    /// `PeripheralHost` fails every parked readiness waiter with `bluetoothUnavailable` on any
    /// state but `.poweredOn`. When the radio was already `.unsupported` no state change is
    /// delivered, and `_wasBlockedAtDrop` arms the reconnect's readiness instead.
    private func handleLinkDropped() {
        dispatchPrecondition(condition: .onQueue(queue))
        _isAdvertising = false
        // The provider that owed those completions is gone, and one still on the wire from it
        // may yet be decoded — it describes a radio that no longer exists either way.
        _outstandingStarts = 0
        _isAwaitingReconnect = true
        // Before the state change, so a host draining its events sees its subscribers leave
        // and only then hears the radio is gone.
        let departing = _subscribers
        _subscribers.removeAll()
        for (characteristic, subscribers) in departing {
            for subscriber in subscribers.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                deliver(.didUnsubscribe(central: subscriber, characteristic: characteristic))
            }
        }
        if _outstandingUpdates.count >= LinkFlowControl.updateValueWindow { _wasBlockedAtDrop = true }
        _outstandingUpdates.removeAll()
        guard _radioState != .unsupported else { return }
        _radioState = .unsupported
        deliver(.didUpdateState(.unsupported))
    }

    /// Routes an inbound message; anything that is not a `PeripheralHost`-role event is not
    /// this client's business.
    private func handle(_ message: LinkMessage) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard case .hostEvent(let event) = message else { return }
        do {
            try handle(event)
        } catch {
            // See `LinkCentral.handle(_:)`: a malformed identifier from the provider is a
            // provider fault, answered by dropping the session and redialing.
            session.dropConnection()
        }
    }

    // MARK: - Wire events

    /// Translates one ``BLESwiftLink/HostWireEvent`` into the state updates it implies
    /// (applied inline) and the `PeripheralHostEvent` it stands for (delivered on the next
    /// queue tick).
    private func handle(_ event: HostWireEvent) throws {
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
                // here too. A host blocked at the drop was already failed by the `.unsupported`
                // state change; one still parked — it parked while the radio was already
                // `.unsupported`, so no state change failed it — is told it can push again
                // only by this `readyToUpdateSubscribers`.
                _isAwaitingReconnect = false
                let wasBlocked = _outstandingUpdates.count >= LinkFlowControl.updateValueWindow || _wasBlockedAtDrop
                _wasBlockedAtDrop = false
                _outstandingUpdates.removeAll()
                if wasBlocked { deliver(.readyToUpdateSubscribers) }
            }

        case .didStartAdvertising(let error):
            // Only a start no `stopAdvertising()` (or link drop) has cancelled may claim the
            // radio; the completion itself is always reported, cancelled or not, so a host
            // awaiting one is never left hanging. See `_outstandingStarts`.
            if _outstandingStarts > 0 {
                _outstandingStarts -= 1
                if error == nil { _isAdvertising = true }
            }
            deliver(.didStartAdvertising(error: error?.nsError))

        case .didAddService(let service, let error):
            deliver(.didAddService(ServiceIdentifier(uuid: try WireIdentifierValidation.validated(service)), error: error?.nsError))

        case .didReceiveRead(let request):
            deliver(.didReceiveRead(try request.readRequest))

        case .didReceiveWrite(let request):
            deliver(.didReceiveWrite(try request.writeRequest))

        case .didSubscribe(let central, let characteristic):
            let identifier = try characteristic.identifier
            let subscriber = try central.subscriber
            _subscribers[identifier, default: [:]][subscriber.id] = subscriber
            deliver(.didSubscribe(central: subscriber, characteristic: identifier))

        case .didUnsubscribe(let central, let characteristic):
            let identifier = try characteristic.identifier
            let subscriber = try central.subscriber
            _subscribers[identifier]?.removeValue(forKey: subscriber.id)
            if _subscribers[identifier]?.isEmpty == true { _subscribers.removeValue(forKey: identifier) }
            deliver(.didUnsubscribe(central: subscriber, characteristic: identifier))

        case .updateValueDelivered(let sequence):
            // Consumed, never forwarded: `readyToUpdateSubscribers` is synthesized here from
            // the acknowledgement that reopens a full window, exactly as `LinkCentral`
            // synthesizes write-without-response readiness.
            //
            // Matched against the sequences still outstanding, exactly as `LinkPeripheral`
            // matches a write acknowledgement. A sequence this manager never sent, one it has
            // already been acknowledged for, or one from before a drop — the drop and the
            // reconnect both empty the set, and the dead session's acknowledgements may still
            // be on the wire when they do — is ignored, rather than crediting the window the
            // *next* session is filling.
            guard let index = _outstandingUpdates.firstIndex(of: sequence) else { return }
            let wasFull = _outstandingUpdates.count >= LinkFlowControl.updateValueWindow
            _outstandingUpdates.remove(at: index)
            if wasFull, _outstandingUpdates.count < LinkFlowControl.updateValueWindow {
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
