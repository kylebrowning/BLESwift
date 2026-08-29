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
        default:
            _eventHandler?(event)
        }
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
    /// *any* child's transmit queue was full, so the caller retries the push everywhere
    /// after the next `readyToUpdateSubscribers`. Never short-circuits — every child is
    /// called even once a `false` is known.
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        var queued = true
        for backend in backends {
            let accepted = backend.updateValue(value, for: characteristic, onSubscribed: centrals)
            queued = queued && accepted
        }
        return queued
    }
}
#endif
