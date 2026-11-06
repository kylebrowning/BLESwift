//
//  LinkPeripheralManager.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import Logging

/// A `PeripheralManaging` that a provider process backs, not a local `CBPeripheralManager`. It
/// sends each call to the provider as a `HostRequest` over one `LinkClientSession`. It turns each
/// `HostWireEvent` that comes back into a `PeripheralHostEvent`.
///
/// Give one to `PeripheralHost(backend:queue:)`. Pass the *same* `DispatchQueue`:
///
/// ```swift
/// let queue = DispatchQueue(label: "ble")
/// let backend = LinkPeripheralManager(endpoint: endpoint, queue: queue)
/// let host = PeripheralHost(backend: backend, queue: queue)
/// ```
///
/// The provider hosts the peripheral on its `VirtualRadio`. A `Central` in another simulator can
/// connect to it through a ``LinkCentral``.
///
/// - ``radioState`` is `.unsupported` until the provider reports its state.
/// - If an established link drops, the state returns to `.unsupported` and ``isAdvertising``
///   becomes `false`. The manager reports each subscriber as gone with `didUnsubscribe`.
/// - ``updateValue(_:for:onSubscribed:)`` returns `false` when `LinkFlowControl.updateValueWindow`
///   pushes wait for an acknowledgement. `readyToUpdateSubscribers` reopens the window.
/// - Call every member on ``queue``.
///
/// For the full rules, see <doc:BLESwiftSimulatorLink#Radio-state-and-dropped-links> and
/// <doc:BLESwiftSimulatorLink#Notification-back-pressure>.
public final class LinkPeripheralManager: PeripheralManaging, Sendable {

    /// The queue to which the code confines every request, state update, and event delivery.
    /// The owning `PeripheralHost` must be constructed with the same queue.
    public let queue: DispatchQueue

    /// The client session that this manager owns. The manager holds it strongly for its whole
    /// lifetime.
    private let session: LinkClientSession

    /// The identity under which this manager asks every provider to host its device. The manager
    /// creates it once for each instance and sends it in every hello, including each
    /// reconnect's hello.
    private let hostIdentifier: UUID

    /// Where the manager reports a provider that refused ``hostIdentifier``. It is the only such
    /// place, because nothing else in this manager has an outcome that the caller cannot already
    /// see.
    private static let logger = Logger(label: "BLESwiftSimulatorLink.LinkPeripheralManager")

    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _radioState: CentralState = .unsupported
    nonisolated(unsafe) private var _didDeliverInitialState = false
    nonisolated(unsafe) private var _isAdvertising = false

    /// The number of ``startAdvertising(_:)`` requests that are still outstanding. Each of them
    /// was sent, has no `didStartAdvertising` answer yet, and was not cancelled by a later
    /// ``stopAdvertising()``.
    ///
    /// The count exists because the provider answers a start that it has already stopped again.
    /// The provider applies a start and a stop that were sent in one queue turn in that order,
    /// which leaves the hosted device silent. But the provider creates the start's completion
    /// inside the start, so the completion arrives here *after* the code sent the stop.
    ///
    /// If the code latched ``isAdvertising`` on for that completion, this manager would claim a
    /// radio that the provider already quieted, and `PeripheralHost.startAdvertising(_:)` would
    /// return early on the flag. The host could then never advertise again for the life of the
    /// session.
    ///
    /// Thus a stop sets the count to zero. The manager still delivers a completion that has no
    /// start behind it, because a host that awaits one must not hang, but it does not claim the
    /// radio.
    ///
    /// `VirtualPeripheralManagerBackend` answers the same race by making both writes from its
    /// serial chain. A client owns neither the radio nor the ordering, so it counts the starts
    /// that it has outstanding.
    nonisolated(unsafe) private var _outstandingStarts = 0

    /// The subscribers for which this manager delivered a `didSubscribe` and not yet a
    /// `didUnsubscribe`, for each characteristic. This is a mirror of the host's subscriber
    /// table.
    ///
    /// It exists only so the manager can answer a dropped link with the `didUnsubscribe` that the
    /// dead provider never sends. The key is the ``BLESwiftCore/Subscriber`` id, so a repeat
    /// `didSubscribe` for the same central refreshes the entry and does not duplicate it.
    nonisolated(unsafe) private var _subscribers: [CharacteristicIdentifier: [UUID: Subscriber]] = [:]

    /// The sequence number with which the next ``updateValue(_:for:onSubscribed:)`` is tagged.
    nonisolated(unsafe) private var _nextSequence: UInt64 = 0

    /// The sequences of the pushes that this manager sent and that have no acknowledgement yet,
    /// oldest first. They are the occupied part of the window. This is an array and not a
    /// `Set`, for the same reasons as in `LinkPeripheral`:
    ///
    /// - It never holds more than the size of one window.
    /// - The order makes a stale acknowledgement easy to see in a debugger.
    /// - A linear scan of that many elements is cheaper than hashing.
    nonisolated(unsafe) private var _outstandingUpdates: [UInt64] = []

    /// Whether the window was full when the link dropped.
    ///
    /// A host that was blocked on the window at a drop from any state but `.unsupported` is
    /// already failed: the `.unsupported` state change failed it with `bluetoothUnavailable`.
    ///
    /// This flag arms the reconnect to emit one `readyToUpdateSubscribers`, for a waiter that the
    /// state change cannot reach. That waiter parked before a drop from a radio that was already
    /// `.unsupported`, and that drop delivers no state change to fail it. The code empties the
    /// window here, and the waiter is still parked. The reconnect that emits the signal clears
    /// the flag.
    nonisolated(unsafe) private var _wasBlockedAtDrop = false

    /// Whether the next provider state is a *reconnect*. In that case the code must clear the
    /// window and must not trust it.
    ///
    /// The value starts as `true`, so the code treats the *first* provider connection as a
    /// reconnect too. A host can fill the window before the link ever comes up. Its pushes then
    /// parked against no provider at all, and nothing will ever acknowledge them. This is the
    /// same unacknowledgeable state that a drop leaves, and the connection that answers it
    /// clears it in the same way.
    nonisolated(unsafe) private var _isAwaitingReconnect = true

    /// Creates a peripheral manager that controls the provider at `endpoint`, and starts dialing
    /// it at once. Reconnection is automatic, at `retryInterval`.
    ///
    /// - Parameters:
    ///   - endpoint: The host and port of the provider.
    ///   - queue: The serial queue to which this manager is confined. It is the instance with
    ///     which the owning `PeripheralHost` is constructed.
    ///   - clientName: A name that people can read, sent in the handshake. The provider logs it
    ///     and gives it to the hosted device, so it is the name that remote centrals see. The
    ///     default is the name of the current process.
    ///   - codec: The codec that encodes messages. The default is `LinkCodec.binaryPropertyList`.
    ///   - retryInterval: How long to wait before a new dial after a failure. The default is two
    ///     seconds.
    public init(
        endpoint: LinkEndpoint,
        queue: DispatchQueue,
        clientName: String = ProcessInfo.processInfo.processName,
        codec: LinkCodec = .binaryPropertyList,
        retryInterval: Duration = .seconds(2)
    ) {
        self.queue = queue
        // One identity for each manager, sent in every hello that this session makes. The
        // provider hosts the device under it, so a link drop and its reconnect leave the same
        // device on the radio and not a new device that every central would have to discover
        // again.
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
        // The captures are weak. This manager owns the session, so a strong capture would make a
        // cycle, and `deinit`, which stops the session, would never run.
        session.onConnected = { hello in
            // A provider hosted this device under an identity other than the one that the client
            // asked for, because one of its own devices holds that identity. Every reconnect will
            // ask again and the provider will refuse again. The client cannot repair this, so it
            // reports the problem. To every central, this host looks like a device that keeps
            // changing its identifier. This line is the only place that explains it.
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

    /// Whether the provider accepted the handshake and the link is live.
    public var isProviderConnected: Bool {
        session.isConnected
    }

    /// Stops the session, then runs the teardown that a dropped link runs. The teardown reports
    /// every subscriber as departing and drops the state to `.unsupported`. The function detaches
    /// the event handler one turn later. Repeated calls are safe, and it is safe to call from any
    /// thread. Nothing calls it in production, because `deinit` stops the session on its own.
    ///
    /// **The teardown runs before the handler goes. The handler goes one turn later.** The reason
    /// is the same as in ``LinkCentral/shutdown()``. The session is marked stopped before its
    /// connection reaches a terminal state, so `onDisconnected` never fires. A host that awaited
    /// `add(_:)` or `startAdvertising(_:)` was stranded and not failed.
    public func shutdown() {
        session.stop()
        queue.async { [self] in
            handleLinkDropped()
            queue.async { [self] in
                _eventHandler = nil
            }
        }
    }

    /// Drops the live link, as a transport failure does, and lets the session dial again under
    /// the same `hostIdentifier`.
    ///
    /// This is for tests only, because production code has no reason to drop a healthy link. It
    /// lets a test produce the reconnect that races the teardown of a provider session against
    /// the registration of its successor. A provider restart cannot reproduce this race,
    /// because the restart takes the whole radio with it.
    package func dropLinkForTesting() {
        session.dropConnection()
    }

    // MARK: - PeripheralManaging

    /// The Bluetooth authorization status of the app. It is always `.allowedAlways`, because the
    /// provider process is responsible for authorization and would have refused the handshake
    /// otherwise.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// The last radio state that the provider reported. The value is `.unsupported` while no
    /// provider is connected.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _radioState
    }

    /// Whether the provider's host is advertising now. The value is `true` after a successful
    /// `didStartAdvertising` for a start that is still outstanding. The value is `false` after
    /// ``stopAdvertising()`` and after a dropped link, which both cancel every outstanding
    /// start. Thus the completion of a start that the provider already stopped again cannot
    /// latch this value back on. See `_outstandingStarts`.
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _isAdvertising
    }

    /// Receives every `PeripheralHostEvent` that the code translated from the provider's wire
    /// events.
    ///
    /// When an app attaches a handler, the manager schedules the delivery of the current
    /// ``radioState``. This mirrors the `peripheralManagerDidUpdateState(_:)` that CoreBluetooth
    /// sends after an app sets a delegate. It also makes the first `.unsupported` observable when
    /// the provider is never reachable.
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

    /// Asks the provider's host to start advertising. The completion arrives as
    /// `didStartAdvertising(error:)`.
    public func startAdvertising(_ advertisement: PeripheralAdvertisement) {
        dispatchPrecondition(condition: .onQueue(queue))
        _outstandingStarts += 1
        send(.startAdvertising(
            localName: advertisement.localName,
            services: advertisement.serviceUUIDs.map(\.uuidString)
        ))
    }

    /// Asks the provider's host to stop the advertisement. It reports no completion of its own,
    /// so ``isAdvertising`` drops here and not on an acknowledgement.
    ///
    /// It also cancels every start that is still outstanding. The provider applies this stop
    /// after them, so the completion that any of them still owes describes a radio that this
    /// call has since quieted. See `_outstandingStarts`.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        _isAdvertising = false
        _outstandingStarts = 0
        send(.stopAdvertising)
    }

    /// Asks the provider's host to publish `service`. The completion arrives as
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

    /// Answers the read or write request that `token` identifies, on the provider's host.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.respond(token: token.rawValue, value: value, attError: error?.rawValue))
    }

    /// Pushes `value` for `characteristic` to `centrals` through the provider's host. If
    /// `centrals` is `nil`, it pushes to every subscriber.
    ///
    /// - Returns: `false`, and sends nothing, if `LinkFlowControl.updateValueWindow` pushes are
    ///   unacknowledged. Otherwise `true`, and the function sent the push and claimed a slot in
    ///   the window.
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

    /// Sends `request` over the link. Call it on ``queue``.
    private func send(_ request: HostRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        session.send(.hostRequest(request))
    }

    // MARK: - Link lifecycle

    /// Handles a link that dropped after it was established. Nothing advertises, and the radio
    /// state is unknown again.
    ///
    /// - The manager synthesizes `didUnsubscribe` for each subscriber. The old provider session
    ///   owed it, and a new session creates new ``BLESwiftCore/Subscriber`` ids.
    /// - The code empties the notification window. No `updateValueDelivered` can arrive for a push
    ///   of the old session. A surviving count would hold the window shut. While the link is down,
    ///   ``updateValue(_:for:onSubscribed:)`` returns `true` and drops the push.
    /// - The code emits no `readyToUpdateSubscribers`, because the radio is dead.
    /// - If the radio was not `.unsupported`, `didUpdateState(.unsupported)` releases a blocked
    ///   host. `PeripheralHost` fails each parked waiter in any state but `.poweredOn`. If it was
    ///   already `.unsupported`, `_wasBlockedAtDrop` arms the readiness signal at the reconnect.
    private func handleLinkDropped() {
        dispatchPrecondition(condition: .onQueue(queue))
        _isAdvertising = false
        // The provider that owed those completions is gone. The code can still decode one that
        // is on the wire from it. In either case it describes a radio that no longer exists.
        _outstandingStarts = 0
        _isAwaitingReconnect = true
        // This happens before the state change, so a host that drains its events sees its
        // subscribers leave and only then hears that the radio is gone.
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

    /// Routes an inbound message. A message that is not a `PeripheralHost`-role event is not a
    /// concern of this client.
    private func handle(_ message: LinkMessage) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard case .hostEvent(let event) = message else { return }
        do {
            try handle(event)
        } catch {
            // See `LinkCentral.handle(_:)`. A malformed identifier from the provider is the
            // provider's fault. The answer is to drop the session and dial again.
            session.dropConnection()
        }
    }

    // MARK: - Wire events

    /// Translates one ``BLESwiftLink/HostWireEvent`` into the state updates that it implies and
    /// the `PeripheralHostEvent` that it stands for. The code applies the updates inline and
    /// delivers the event on the next queue tick.
    private func handle(_ event: HostWireEvent) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {

        case .didUpdateState(let state):
            // Do NOT set `_didDeliverInitialState` here, on purpose. See `LinkCentral` for the
            // reason. A provider state that lands before a handler exists must not suppress the
            // attach.
            _radioState = state.state
            deliver(.didUpdateState(state.state))
            if _isAwaitingReconnect {
                // The provider is back, with a session and a queue of its own. Nothing that this
                // client sent to the old provider will ever get an acknowledgement, whether the
                // push was in flight at the drop or the manager dropped it unsent after the drop.
                // Thus the code empties the window here too.
                //
                // The `.unsupported` state change already failed a host that was blocked at the
                // drop. A host can still be parked if it parked while the radio was already
                // `.unsupported`, so no state change failed it. Only this
                // `readyToUpdateSubscribers` tells that host that it can push again.
                _isAwaitingReconnect = false
                let wasBlocked = _outstandingUpdates.count >= LinkFlowControl.updateValueWindow || _wasBlockedAtDrop
                _wasBlockedAtDrop = false
                _outstandingUpdates.removeAll()
                if wasBlocked { deliver(.readyToUpdateSubscribers) }
            }

        case .didStartAdvertising(let error):
            // Only a start that no `stopAdvertising()` and no link drop cancelled can claim the
            // radio. The code always reports the completion itself, cancelled or not, so a host
            // that awaits one is never left to hang. See `_outstandingStarts`.
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
            // The code consumes this event and never forwards it. It synthesizes
            // `readyToUpdateSubscribers` here from the acknowledgement that reopens a full window.
            // `LinkCentral` synthesizes write-without-response readiness in the same way.
            //
            // The code matches the event against the sequences that are still outstanding, as
            // `LinkPeripheral` does for a write acknowledgement. It ignores these sequences:
            //
            // - A sequence that this manager never sent.
            // - A sequence that it already got an acknowledgement for.
            // - A sequence from before a drop. The drop and the reconnect both empty the set, and
            //   the dead session's acknowledgements can still be on the wire when they do.
            //
            // Thus the code does not credit the window that the *next* session is filling.
            guard let index = _outstandingUpdates.firstIndex(of: sequence) else { return }
            let wasFull = _outstandingUpdates.count >= LinkFlowControl.updateValueWindow
            _outstandingUpdates.remove(at: index)
            if wasFull, _outstandingUpdates.count < LinkFlowControl.updateValueWindow {
                deliver(.readyToUpdateSubscribers)
            }
        }
    }

    /// Delivers `event` to ``eventHandler`` asynchronously on ``queue``, as the seam's
    /// never-inline delivery contract requires.
    private func deliver(_ event: PeripheralHostEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            _eventHandler?(event)
        }
    }
}
