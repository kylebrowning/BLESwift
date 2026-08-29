//
//  CompositePeripheralManager.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Dispatch
import Foundation

/// A `PeripheralManaging` made of several — the peripheral-role counterpart
/// to ``CompositeCentral``.
///
/// One `PeripheralHost` over a composite is hosted simultaneously by every child: the same
/// GATT database is published, the same advertisement started, and the same notification
/// pushed on an in-process ``VirtualRadio`` *and* the Mac's real CoreBluetooth. Requests
/// arriving from any child surface as one event stream, and
/// ``respond(to:value:error:)`` is offered to every child — the ones that never minted
/// that token ignore it, per `PeripheralManaging.respond(to:value:error:)`,
/// so no routing table is needed.
///
/// **Two completions are aggregated, not forwarded.** ``add(_:)`` and
/// ``startAdvertising(_:)`` each report once per child; the composite holds a pending count
/// per outstanding operation and emits a single `didAddService`/`didStartAdvertising` once
/// every child has reported, carrying the *first* non-`nil` error. Every other event is
/// forwarded verbatim, except `didUpdateState` (replaced by the composite's computed state)
/// and `willRestoreState` (dropped) — see ``CompositeCentral`` for why.
///
/// **A refused push is the composite's to finish.** ``updateValue(_:for:onSubscribed:)``
/// returns the AND of its children's answers, and a push some child refused is held as the
/// *outstanding* push: the composite re-offers it to the children that refused it — and only
/// those — as their `readyToUpdateSubscribers` arrive, so no child's subscribers see a value
/// twice. Until that push has landed everywhere the window is closed: a further
/// `updateValue` is refused without being pushed, which keeps the caller's pushes in order.
/// See ``updateValue(_:for:onSubscribed:)`` for the full state machine.
///
/// **Concurrency — queue-confined, not lock-protected.** Identical discipline to
/// ``CompositeCentral``, including the requirement that **every child be confined to the
/// same `queue`** and that ``init(backends:queue:)`` not be called from that queue.
public final class CompositePeripheralManager: PeripheralManaging, Sendable {

    /// One outstanding fan-out awaiting its children's completions.
    private struct Pending {
        /// How many children have yet to report.
        var remaining: Int
        /// The first non-`nil` error reported so far.
        var error: NSError?
    }

    /// The queue every method, property access, and event delivery is confined to — and the
    /// queue every child backend must also be confined to.
    public let queue: DispatchSerialQueue

    /// The children, in priority order (the first supplies the fallback ``radioState``).
    /// `nonisolated(unsafe)` because `any PeripheralManaging` is not itself `Sendable`; the
    /// array is immutable and only ever read on ``queue``.
    nonisolated(unsafe) private let backends: [any PeripheralManaging]

    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _announcedState = false
    nonisolated(unsafe) private var _lastEmittedState: CentralState?

    /// Outstanding ``add(_:)`` fan-outs, keyed by service and held FIFO so that repeated
    /// adds of the same service each get their own aggregated completion.
    nonisolated(unsafe) private var _pendingAdds: [ServiceIdentifier: [Pending]] = [:]

    /// Outstanding ``startAdvertising(_:)`` fan-outs, FIFO.
    nonisolated(unsafe) private var _pendingAdvertisements: [Pending] = []

    /// The push some child refused, and the children that still owe it.
    private struct OutstandingPush {
        /// The value to re-offer, held so the composite can finish the push itself.
        let value: Data
        let characteristic: CharacteristicIdentifier
        let subscribers: [Subscriber]?
        /// The indices into ``backends`` whose transmit queue was full. Only these are
        /// pushed to again; empty once every child has taken the value, which leaves the
        /// entry standing as the marker for the caller's re-offer.
        var refused: [Int]

        /// Whether every child has taken this value.
        var isDelivered: Bool { refused.isEmpty }
    }

    /// The push some child refused, held until every child has taken it — so the composite's
    /// own re-offers reach the children that refused it alone, and a child that already
    /// delivered the value does not notify its subscribers a second time.
    ///
    /// Once delivered the entry is kept, not cleared: it is what tells the caller's mandated
    /// re-offer (`PeripheralManaging.updateValue(_:for:onSubscribed:)` promises a `false` is
    /// retried after `readyToUpdateSubscribers`) from a *new* push, without ever inferring a
    /// retry from the payload. The re-offer is answered `true` and pushed nowhere.
    nonisolated(unsafe) private var _outstandingPush: OutstandingPush?

    /// The authorization status this composite reports: always
    /// `BluetoothAuthorization.allowedAlways`. See
    /// ``CompositeCentral/bluetoothAuthorization`` for why a composite has no better
    /// answer to give.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// Creates a composite over `backends`, confined to `queue`.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. Must all be confined to `queue`.
    ///   - queue: The shared queue — the same one the owning `PeripheralHost` is
    ///     constructed with.
    public init(backends: [any PeripheralManaging], queue: DispatchSerialQueue) {
        self.backends = backends
        self.queue = queue
        queue.sync { attachChildren() }
    }

    /// Creates a composite over `backends` **from `queue` itself**, attaching the children
    /// without hopping — the peripheral-role counterpart to
    /// ``CompositeCentral/init(backends:onQueue:)``, and the one way to build both children
    /// and the composite over them inside a single `queue.sync`.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. Must all be confined to `queue`.
    ///   - queue: The shared queue, which this call must already be running on.
    package init(backends: [any PeripheralManaging], onQueue queue: DispatchSerialQueue) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.backends = backends
        self.queue = queue
        attachChildren()
    }

    /// Installs this composite as every child's event sink. Idempotent; must be called on
    /// ``queue``.
    private func attachChildren() {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends {
            backend.eventHandler = { [weak self] event in
                self?.handle(event)
            }
        }
    }

    /// ``BLESwiftCore/CentralState/poweredOn`` if any child is on, else the first child's
    /// state. Must be called on ``queue``.
    private var computedState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        if backends.contains(where: { $0.radioState == .poweredOn }) { return .poweredOn }
        return backends.first?.radioState ?? .unknown
    }

    /// Emits `didUpdateState` when ``computedState`` changes (or unconditionally, for the
    /// one-shot announcement). Must be called on ``queue``.
    private func emitState(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let state = computedState
        guard force || state != _lastEmittedState else { return }
        _lastEmittedState = state
        _eventHandler?(.didUpdateState(state))
    }

    /// Fans one child's event in. Must be called on ``queue``.
    private func handle(_ event: PeripheralHostEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case .didUpdateState:
            emitState()
        case .willRestoreState:
            break
        case .didAddService(let identifier, let error):
            completeAdd(identifier, error: error)
        case .didStartAdvertising(let error):
            completeAdvertising(error: error)
        case .readyToUpdateSubscribers:
            resumeOutstandingPush()
        default:
            _eventHandler?(event)
        }
    }

    /// Re-offers the outstanding push to the children that still owe it, and emits one
    /// `readyToUpdateSubscribers` to the host once — and only once — that push has landed
    /// everywhere. With nothing outstanding the child's event is forwarded verbatim. Must be
    /// called on ``queue``.
    private func resumeOutstandingPush() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var outstanding = _outstandingPush, !outstanding.isDelivered else {
            _eventHandler?(.readyToUpdateSubscribers)
            return
        }
        outstanding.refused = outstanding.refused.filter { index in
            !backends[index].updateValue(
                outstanding.value,
                for: outstanding.characteristic,
                onSubscribed: outstanding.subscribers
            )
        }
        _outstandingPush = outstanding
        // Still owed by someone: the window stays closed and the host hears nothing, so it
        // cannot offer a push that would overtake this one.
        guard outstanding.isDelivered else { return }
        _eventHandler?(.readyToUpdateSubscribers)
    }

    /// Settles one child's `didAddService`, emitting the aggregate once the last child has
    /// reported. Must be called on ``queue``.
    private func completeAdd(_ identifier: ServiceIdentifier, error: NSError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var batches = _pendingAdds[identifier], !batches.isEmpty else {
            // A completion for an add this composite never issued (a child publishing on
            // its own). Nothing to aggregate — forward it as-is.
            _eventHandler?(.didAddService(identifier, error: error))
            return
        }
        batches[0].remaining -= 1
        if batches[0].error == nil { batches[0].error = error }
        guard batches[0].remaining <= 0 else {
            _pendingAdds[identifier] = batches
            return
        }
        let settled = batches.removeFirst()
        _pendingAdds[identifier] = batches.isEmpty ? nil : batches
        _eventHandler?(.didAddService(identifier, error: settled.error))
    }

    /// Settles one child's `didStartAdvertising`, emitting the aggregate once the last
    /// child has reported. Must be called on ``queue``.
    private func completeAdvertising(error: NSError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !_pendingAdvertisements.isEmpty else {
            _eventHandler?(.didStartAdvertising(error: error))
            return
        }
        _pendingAdvertisements[0].remaining -= 1
        if _pendingAdvertisements[0].error == nil { _pendingAdvertisements[0].error = error }
        guard _pendingAdvertisements[0].remaining <= 0 else { return }
        let settled = _pendingAdvertisements.removeFirst()
        _eventHandler?(.didStartAdvertising(error: settled.error))
    }

    // MARK: - PeripheralManaging

    /// Receives every `PeripheralHostEvent` fanned in from the children, on
    /// ``queue``. Attaching and detaching behave exactly as
    /// ``CompositeCentral/eventHandler``: a non-`nil` handler (re)installs the composite on
    /// every child, `nil` clears every child's handler, and the first non-`nil` attachment
    /// triggers the one-shot `didUpdateState` announcement.
    public var eventHandler: ((PeripheralHostEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
            guard newValue != nil else {
                for backend in backends { backend.eventHandler = nil }
                return
            }
            attachChildren()
            guard !_announcedState else { return }
            _announcedState = true
            queue.async { [self] in emitState(force: true) }
        }
    }

    /// `CentralState.poweredOn` if any child is powered on, otherwise the
    /// first child's state (`CentralState.unknown` with no children).
    public var radioState: CentralState {
        computedState
    }

    /// `true` only when *every* child is advertising — the composite advertises as a whole
    /// or not at all. Vacuously `true` with no children.
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return backends.allSatisfy(\.isAdvertising)
    }

    /// Starts advertising on every child. A single `didStartAdvertising` follows once every
    /// child has reported, carrying the first non-`nil` error.
    public func startAdvertising(_ advertisement: PeripheralAdvertisement) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !backends.isEmpty else {
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                _eventHandler?(.didStartAdvertising(error: nil))
            }
            return
        }
        _pendingAdvertisements.append(Pending(remaining: backends.count, error: nil))
        for backend in backends { backend.startAdvertising(advertisement) }
    }

    /// Stops advertising on every child.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.stopAdvertising() }
    }

    /// Publishes `service` on every child. A single `didAddService` follows once every child
    /// has reported, carrying the first non-`nil` error.
    public func add(_ service: GATTService) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !backends.isEmpty else {
            let identifier = service.identifier
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                _eventHandler?(.didAddService(identifier, error: nil))
            }
            return
        }
        _pendingAdds[service.identifier, default: []].append(Pending(remaining: backends.count, error: nil))
        for backend in backends { backend.add(service) }
    }

    /// Clears every child's GATT database.
    public func removeAllHostedServices() {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.removeAllHostedServices() }
    }

    /// Offers the response to every child; the children that never minted `token` ignore it,
    /// per the seam's contract — which is why no routing table is needed.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.respond(to: token, value: value, error: error) }
    }

    /// Pushes `value` through every child and returns the AND of their answers: `false` if
    /// *any* child's transmit queue was full. Never short-circuits — every child is called
    /// even once a `false` is known.
    ///
    /// **The composite finishes a refused push itself; the caller only re-offers it.** Three
    /// states, and no retry is ever inferred from the payload:
    ///
    /// - *Nothing outstanding.* The push fans out to every child. If they all take it the
    ///   answer is `true` and nothing is remembered. If any refuses, the push becomes the
    ///   outstanding one and the answer is `false`.
    /// - *An outstanding push is still owed by some child.* The window is closed: the answer
    ///   is `false` and nothing is pushed, so no later push can overtake the outstanding one.
    ///   Each `readyToUpdateSubscribers` from a child re-offers the outstanding value to the
    ///   children that refused it — and only those, so no subscriber sees it twice — with the
    ///   host hearing nothing until it has landed everywhere.
    /// - *The outstanding push has landed everywhere.* One `readyToUpdateSubscribers` has
    ///   reached the host, and the seam's contract says the next push it offers is the
    ///   re-offer of that same value. It is answered `true` and pushed nowhere: every child
    ///   already has it.
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        if let outstanding = _outstandingPush {
            guard outstanding.isDelivered else { return false }
            _outstandingPush = nil
            return true
        }
        var refused: [Int] = []
        for index in backends.indices where !backends[index].updateValue(value, for: characteristic, onSubscribed: centrals) {
            refused.append(index)
        }
        guard !refused.isEmpty else { return true }
        _outstandingPush = OutstandingPush(
            value: value,
            characteristic: characteristic,
            subscribers: centrals,
            refused: refused
        )
        return false
    }
}
#endif
