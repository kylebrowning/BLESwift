//
//  CompositePeripheralManager.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
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
/// **One FIFO per child.** ``updateValue(_:for:onSubscribed:)`` hands the value to every
/// child that will take it and queues it for the ones that will not, in its own per-child
/// FIFO; each child's `readyToUpdateSubscribers` drains that child's FIFO in order. So every
/// value reaches every child exactly once, in the order it was pushed, and nothing is ever
/// inferred from a payload or from the *position* of a push in the caller's sequence. The
/// composite refuses a push — closing its window — only when some child's FIFO is full. See
/// ``updateValue(_:for:onSubscribed:)``.
///
/// **Concurrency — queue-confined, not lock-protected.** Identical discipline to
/// ``CompositeCentral``, including the requirement that **every child be confined to the
/// same `queue`** and that ``init(backends:queue:log:)`` not be called from that queue.
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

    /// One push a child has not taken yet, held verbatim in that child's FIFO.
    private struct PendingPush {
        let value: Data
        let characteristic: CharacteristicIdentifier
        let subscribers: [Subscriber]?
    }

    /// What each child still owes its subscribers, oldest first — one FIFO per child, indexed
    /// like ``backends``. A child's queue grows when it refuses a push and drains, in order,
    /// on its `readyToUpdateSubscribers`.
    nonisolated(unsafe) private var _queues: [[PendingPush]] = []

    /// Whether the composite has told its host the window is closed and owes it one
    /// `readyToUpdateSubscribers` — set by the `false` that closed it, cleared by the single
    /// event that reopens it.
    nonisolated(unsafe) private var _windowClosed = false

    /// How many pushes one child may fall behind by before the composite closes its window.
    /// The same window the link's own client honors, so a composite behind a link cannot
    /// queue more than the link would have let through.
    private static var queueLimit: Int { LinkFlowControl.updateValueWindow }

    /// The authorization status this composite reports: always
    /// `BluetoothAuthorization.allowedAlways`. See
    /// ``CompositeCentral/bluetoothAuthorization`` for why a composite has no better
    /// answer to give.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// Where this composite reports a child falling a whole window behind, if anywhere.
    private let log: (@Sendable (String) -> Void)?

    /// Creates a composite over `backends`, confined to `queue`.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. Must all be confined to `queue`.
    ///   - queue: The shared queue — the same one the owning `PeripheralHost` is
    ///     constructed with.
    ///   - log: Where to report a child whose FIFO has filled, if anywhere.
    public init(
        backends: [any PeripheralManaging],
        queue: DispatchSerialQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.backends = backends
        self.queue = queue
        self.log = log
        self._queues = Array(repeating: [], count: backends.count)
        queue.sync { attachChildren() }
    }

    /// Creates a composite over `backends` **from `queue` itself**, attaching the children
    /// without hopping — the peripheral-role counterpart to
    /// `CompositeCentral.init(backends:onQueue:)`, and the one way to build both children
    /// and the composite over them inside a single `queue.sync`.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. Must all be confined to `queue`.
    ///   - queue: The shared queue, which this call must already be running on.
    ///   - log: Where to report a child whose FIFO has filled, if anywhere.
    package init(
        backends: [any PeripheralManaging],
        onQueue queue: DispatchSerialQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.backends = backends
        self.queue = queue
        self.log = log
        self._queues = Array(repeating: [], count: backends.count)
        attachChildren()
    }

    /// Installs this composite as every child's event sink. Idempotent; must be called on
    /// ``queue``.
    private func attachChildren() {
        dispatchPrecondition(condition: .onQueue(queue))
        for index in backends.indices {
            backends[index].eventHandler = { [weak self] event in
                self?.handle(event, from: index)
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

    /// Fans one child's event in, `index` naming the child it came from. Must be called on
    /// ``queue``.
    private func handle(_ event: PeripheralHostEvent, from index: Int) {
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
            resume(child: index)
        default:
            _eventHandler?(event)
        }
    }

    /// Drains what child `index` still owes, then decides what the host hears.
    ///
    /// With the window closed — the composite has refused a push — the host is owed exactly
    /// one `readyToUpdateSubscribers`, and it comes when no child's FIFO is full any more, so
    /// several children reopening produce one event rather than one apiece. With the window
    /// open nothing is owed and the child's readiness is the composite's own: forwarded, as
    /// every other event is. Must be called on ``queue``.
    private func resume(child index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        drain(child: index)
        guard _windowClosed else {
            _eventHandler?(.readyToUpdateSubscribers)
            return
        }
        guard !isAnyQueueFull else { return }
        _windowClosed = false
        _eventHandler?(.readyToUpdateSubscribers)
    }

    /// Offers child `index` what it owes, oldest first, stopping at the first refusal so the
    /// child's subscribers see the values in the order they were pushed. Must be called on
    /// ``queue``.
    private func drain(child index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        while let next = _queues[index].first {
            guard backends[index].updateValue(next.value, for: next.characteristic, onSubscribed: next.subscribers) else {
                return
            }
            _queues[index].removeFirst()
        }
    }

    /// Whether any child has fallen a whole ``queueLimit`` behind. Must be called on
    /// ``queue``.
    private var isAnyQueueFull: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _queues.contains { $0.count >= Self.queueLimit }
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

    /// Delivers `value` to every child — now if it will take it, from that child's FIFO if it
    /// will not.
    ///
    /// **Per-child FIFOs, not a shared outstanding push.** For each child: if it owes nothing
    /// and accepts the push, it is done; otherwise the push joins the back of *that child's*
    /// FIFO, which its next `readyToUpdateSubscribers` drains in order. A value therefore
    /// reaches each child exactly once and in order, whatever the children's windows are
    /// doing, and two pushes carrying identical bytes are two pushes — nothing here compares
    /// payloads or infers a retry.
    ///
    /// - Returns: `true` when every child either took the value or queued it. `false` — the
    ///   composite's window closing — only when some child has already fallen a full
    ///   `queueLimit` behind, in which case *nothing* is pushed or queued, so the caller's
    ///   re-offer after the next `readyToUpdateSubscribers` is the value's first and only
    ///   delivery.
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        // Checked before anything is delivered: a push that is refused must reach no child at
        // all, or the caller's re-offer of it would notify some subscribers twice.
        guard !isAnyQueueFull else {
            _windowClosed = true
            return false
        }
        let pending = PendingPush(value: value, characteristic: characteristic, subscribers: centrals)
        for index in backends.indices {
            if _queues[index].isEmpty,
               backends[index].updateValue(value, for: characteristic, onSubscribed: centrals) {
                continue
            }
            _queues[index].append(pending)
            // Reported on the transition only: the push that fills a FIFO is the last one
            // this composite accepts until that child drains, so a child that never comes
            // back — the one case worth diagnosing — costs exactly one line, not one per
            // push. Which child, and on what, is the whole diagnosis.
            if _queues[index].count == Self.queueLimit {
                log?("composite child \(index) is \(Self.queueLimit) update(s) behind on \(characteristic); closing the window")
            }
        }
        return true
    }
}
#endif
