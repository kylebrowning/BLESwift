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
/// ``startAdvertising(_:)`` each report once per child; the composite holds the set of
/// children still owing each outstanding operation and emits a single
/// `didAddService`/`didStartAdvertising` once every one of them has reported, carrying the
/// *first* non-`nil` error. Every other event is forwarded verbatim, except `didUpdateState`
/// (replaced by the composite's computed state) and `willRestoreState` (dropped) — see
/// ``CompositeCentral`` for why.
///
/// **Only powered-on children take part.** A child whose `radioState` is not
/// `CentralState/poweredOn` — the Mac's real `CBPeripheralManager` while Bluetooth is off,
/// unauthorized, or resetting — can neither answer a completion nor accept a push, so the
/// composite never waits on one. Such a child is skipped by ``add(_:)`` and
/// ``startAdvertising(_:)`` (counted as immediately complete with no error: the powered-on
/// children, the virtual radio among them, carry the service — unless there are none, in which
/// case both complete with ``noPoweredOnBackendError``), and skipped by
/// ``updateValue(_:for:onSubscribed:)``, whose window never closes on it. When a child drops
/// out of `poweredOn` the composite settles whatever it still owed and discards its FIFO;
/// when a child comes back the composite republishes its current services and restarts
/// advertising on it, so `--passthrough` picks the Mac's radio up the moment the user turns
/// it on. Each skipped child is logged once.
///
/// **One FIFO per child.** ``updateValue(_:for:onSubscribed:)`` hands the value to every
/// powered-on child that will take it and queues it for the ones that will not, in its own
/// per-child FIFO; each child's `readyToUpdateSubscribers` drains that child's FIFO in order.
/// So every value reaches every such child exactly once, in the order it was pushed, and
/// nothing is ever inferred from a payload or from the *position* of a push in the caller's
/// sequence. The composite refuses a push — closing its window — only when some powered-on
/// child's FIFO is full. See ``updateValue(_:for:onSubscribed:)``.
///
/// **Concurrency — queue-confined, not lock-protected.** Identical discipline to
/// ``CompositeCentral``, including the requirement that **every child be confined to the
/// same `queue`** and that ``init(backends:queue:log:)`` not be called from that queue.
public final class CompositePeripheralManager: PeripheralManaging, Sendable {

    /// One outstanding fan-out awaiting its children's completions.
    private struct Pending {
        /// The children that have yet to report, by index into ``backends``.
        var owing: Set<Int>
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

    /// Each child's last observed ``BLESwiftCore/CentralState``, indexed like ``backends`` —
    /// what a `didUpdateState` is compared against to spot a child entering or leaving
    /// `poweredOn`.
    nonisolated(unsafe) private var _childStates: [CentralState] = []

    /// The services this composite has published, newest write per identifier — what a child
    /// coming back to `poweredOn` is caught up with.
    nonisolated(unsafe) private var _services: [GATTService] = []

    /// The advertisement this composite is running, or `nil` once ``stopAdvertising()`` has
    /// been called — what a child coming back to `poweredOn` is restarted with.
    nonisolated(unsafe) private var _advertisement: PeripheralAdvertisement?

    /// How many `didAddService`/`didStartAdvertising` completions from each child must be
    /// swallowed rather than aggregated or forwarded: exactly the ones the child's catch-up
    /// republish will produce, which are never the host's to hear.
    ///
    /// Bounded by what ``powerUp(child:)`` re-issues, and by nothing else. What a child owed
    /// when it powered off is *not* counted here — a radio that goes away abandons those, so
    /// they may never arrive — and is swallowed on the child's state instead. See
    /// ``powerDown(child:)``.
    nonisolated(unsafe) private var _swallowedAdds: [Int] = []
    nonisolated(unsafe) private var _swallowedAdvertisements: [Int] = []

    /// The children already reported as skipped for being powered off — the skip is logged
    /// once per child, not once per operation.
    nonisolated(unsafe) private var _loggedOffline: Set<Int> = []

    /// Whether the composite has told its host the window is closed and owes it one
    /// `readyToUpdateSubscribers` — set by the `false` that closed it, cleared by the single
    /// event that reopens it.
    nonisolated(unsafe) private var _windowClosed = false

    /// What ``add(_:)`` and ``startAdvertising(_:)`` complete with when *no* child is powered
    /// on: nothing was published and nothing is advertising, and the caller has to be told so.
    ///
    /// A skipped child is normally harmless — the powered-on children, the virtual radio among
    /// them, carry the operation, and the skipped one is caught up when it powers on. With no
    /// powered-on child at all there is nobody to carry it, and reporting success left a
    /// `PeripheralHost` believing it had published a database and started an advertisement that
    /// reached no radio whatsoever. CoreBluetooth fails both outright while its manager is off,
    /// and so does this composite.
    public static var noPoweredOnBackendError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "no powered-on backend"]
        )
    }

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
    ///   - log: Where to report a child whose FIFO has filled, or that was skipped for being
    ///     powered off, if anywhere.
    public init(
        backends: [any PeripheralManaging],
        queue: DispatchSerialQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.backends = backends
        self.queue = queue
        self.log = log
        self._queues = Array(repeating: [], count: backends.count)
        self._swallowedAdds = Array(repeating: 0, count: backends.count)
        self._swallowedAdvertisements = Array(repeating: 0, count: backends.count)
        queue.sync { attachChildren() }
    }

    /// Creates a composite over `backends` **from `queue` itself**, attaching the children
    /// without hopping — the peripheral-role counterpart to
    /// `CompositeCentral.init(backends:onQueue:log:)`, and the one way to build both children
    /// and the composite over them inside a single `queue.sync`.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. Must all be confined to `queue`.
    ///   - queue: The shared queue, which this call must already be running on.
    ///   - log: Where to report a child whose FIFO has filled, or that was skipped for being
    ///     powered off, if anywhere.
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
        self._swallowedAdds = Array(repeating: 0, count: backends.count)
        self._swallowedAdvertisements = Array(repeating: 0, count: backends.count)
        attachChildren()
    }

    /// Installs this composite as every child's event sink, and records the state each child
    /// starts from. Idempotent; must be called on ``queue``.
    private func attachChildren() {
        dispatchPrecondition(condition: .onQueue(queue))
        _childStates = backends.map(\.radioState)
        for index in backends.indices {
            backends[index].eventHandler = { [weak self] event in
                self?.handle(event, from: index)
            }
        }
    }

    /// Whether child `index` can currently answer a completion and accept a push. Must be
    /// called on ``queue``.
    private func isOnline(_ index: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return backends[index].radioState == .poweredOn
    }

    /// The children a fan-out may wait on. Must be called on ``queue``.
    private var onlineIndices: [Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return backends.indices.filter { isOnline($0) }
    }

    /// Reports, once per child, that `index` was skipped for not being powered on. Must be
    /// called on ``queue``.
    private func noteOffline(_ index: Int, operation: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _loggedOffline.insert(index).inserted else { return }
        log?("composite child \(index) is \(backends[index].radioState); skipping \(operation) until it powers on")
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
            childChangedState(index)
            emitState()
        case .willRestoreState:
            break
        case .didAddService(let identifier, let error):
            completeAdd(identifier, error: error, from: index)
        case .didStartAdvertising(let error):
            completeAdvertising(error: error, from: index)
        case .readyToUpdateSubscribers:
            resume(child: index)
        default:
            _eventHandler?(event)
        }
    }

    /// Reconciles child `index` entering or leaving `poweredOn`. Must be called on ``queue``.
    private func childChangedState(_ index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        let was = _childStates[index]
        let now = backends[index].radioState
        guard was != now else { return }
        _childStates[index] = now
        if was == .poweredOn, now != .poweredOn {
            powerDown(child: index)
        } else if was != .poweredOn, now == .poweredOn {
            powerUp(child: index)
        }
    }

    /// Settles everything child `index` still owed, and drops what it will never take: it
    /// cannot answer a completion or a push while it is not powered on, and the host must
    /// not wait on it. Must be called on ``queue``.
    private func powerDown(child index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        _queues[index].removeAll()

        for (identifier, batches) in _pendingAdds {
            var remaining: [Pending] = []
            var settled: [NSError?] = []
            for var batch in batches {
                guard batch.owing.remove(index) != nil else {
                    remaining.append(batch)
                    continue
                }
                if batch.owing.isEmpty { settled.append(batch.error) } else { remaining.append(batch) }
            }
            _pendingAdds[identifier] = remaining.isEmpty ? nil : remaining
            for error in settled { _eventHandler?(.didAddService(identifier, error: error)) }
        }

        var remainingAdvertisements: [Pending] = []
        var settledAdvertisements: [NSError?] = []
        for var batch in _pendingAdvertisements {
            guard batch.owing.remove(index) != nil else {
                remainingAdvertisements.append(batch)
                continue
            }
            if batch.owing.isEmpty { settledAdvertisements.append(batch.error) } else { remainingAdvertisements.append(batch) }
        }
        _pendingAdvertisements = remainingAdvertisements
        for error in settledAdvertisements { _eventHandler?(.didStartAdvertising(error: error)) }

        // Nothing this child owed is counted as swallowed, and whatever it still had counted
        // against it is dropped: a `CBPeripheralManager` leaving `.poweredOn` *abandons* the
        // adds and the advertisement it had in flight, so the completions those counters
        // stood in for may never arrive at all. Counted anyway, a counter left standing after
        // a power-down never came back down, and the next completion the child produced for
        // itself was eaten in place of one that was never coming. What does still arrive from
        // a child that is no longer powered on is swallowed by ``completeAdd(_:error:from:)``
        // and ``completeAdvertising(error:from:)`` on the child's *state* instead, which needs
        // no counter — leaving both of these bounded by what ``powerUp(child:)`` re-issues.
        _swallowedAdds[index] = 0
        _swallowedAdvertisements[index] = 0

        reopenWindowIfPossible()
    }

    /// Catches child `index` up with the composite's current services and advertisement now
    /// that it can serve them. Its completions are this composite's business, not the host's,
    /// and the two swallow counters — cleared by ``powerDown(child:)`` — are set here to
    /// exactly the number of republishes this catch-up owes an answer for. Must be called on
    /// ``queue``.
    private func powerUp(child index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        _loggedOffline.remove(index)
        for service in _services {
            _swallowedAdds[index] += 1
            backends[index].add(service)
        }
        if let advertisement = _advertisement {
            _swallowedAdvertisements[index] += 1
            backends[index].startAdvertising(advertisement)
        }
    }

    /// Emits the one `readyToUpdateSubscribers` the host is owed, if the window it closed can
    /// now reopen. Must be called on ``queue``.
    private func reopenWindowIfPossible() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _windowClosed, !isAnyQueueFull else { return }
        _windowClosed = false
        _eventHandler?(.readyToUpdateSubscribers)
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
        guard isOnline(index) else { return }
        while let next = _queues[index].first {
            guard backends[index].updateValue(next.value, for: next.characteristic, onSubscribed: next.subscribers) else {
                return
            }
            _queues[index].removeFirst()
        }
    }

    /// Whether any powered-on child has fallen a whole ``queueLimit`` behind. A child that is
    /// not powered on is never queued for, and so never closes the window. Must be called on
    /// ``queue``.
    private var isAnyQueueFull: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _queues.indices.contains { isOnline($0) && _queues[$0].count >= Self.queueLimit }
    }

    /// Settles one child's `didAddService`, emitting the aggregate once the last child owing
    /// it has reported. Must be called on ``queue``.
    ///
    /// A completion from a child that is no longer powered on is swallowed outright:
    /// ``powerDown(child:)`` released it from every batch it owed, so it can settle nothing,
    /// and a radio that is off has published nothing of its own to report either. It is the
    /// tail of an operation this composite has already settled without it.
    private func completeAdd(_ identifier: ServiceIdentifier, error: NSError?, from index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isOnline(index) else { return }
        var batches = _pendingAdds[identifier] ?? []
        guard let position = batches.firstIndex(where: { $0.owing.contains(index) }) else {
            // A completion for one of the catch-up republishes ``powerUp(child:)`` issued on
            // this composite's own behalf — swallowed, not aggregated.
            if _swallowedAdds[index] > 0 {
                _swallowedAdds[index] -= 1
                return
            }
            // A completion for an add this composite never issued (a child publishing on
            // its own). Nothing to aggregate — forward it as-is.
            _eventHandler?(.didAddService(identifier, error: error))
            return
        }
        batches[position].owing.remove(index)
        if batches[position].error == nil { batches[position].error = error }
        guard batches[position].owing.isEmpty else {
            _pendingAdds[identifier] = batches
            return
        }
        let settled = batches.remove(at: position)
        _pendingAdds[identifier] = batches.isEmpty ? nil : batches
        _eventHandler?(.didAddService(identifier, error: settled.error))
    }

    /// Settles one child's `didStartAdvertising`, emitting the aggregate once the last child
    /// owing it has reported. A completion from a child that is no longer powered on is
    /// swallowed, for the same reason as in ``completeAdd(_:error:from:)``. Must be called on
    /// ``queue``.
    private func completeAdvertising(error: NSError?, from index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isOnline(index) else { return }
        guard let position = _pendingAdvertisements.firstIndex(where: { $0.owing.contains(index) }) else {
            if _swallowedAdvertisements[index] > 0 {
                _swallowedAdvertisements[index] -= 1
                return
            }
            _eventHandler?(.didStartAdvertising(error: error))
            return
        }
        _pendingAdvertisements[position].owing.remove(index)
        if _pendingAdvertisements[position].error == nil { _pendingAdvertisements[position].error = error }
        guard _pendingAdvertisements[position].owing.isEmpty else { return }
        let settled = _pendingAdvertisements.remove(at: position)
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

    /// `true` when any *powered-on* child is advertising — the same children
    /// ``startAdvertising(_:)`` fans out to. `false` with no children, and `false` while every
    /// child is off.
    ///
    /// Read over every child instead, this reported `false` for exactly the arrangement
    /// `--passthrough` is normally in: a virtual child happily advertising beside a real
    /// `CBPeripheralManager` whose Bluetooth is turned off. That child is skipped by
    /// ``startAdvertising(_:)`` — it could never report a completion — and picks the
    /// advertisement up when it powers on, so counting it as not-advertising made the
    /// composite deny an advertisement it really is broadcasting.
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return onlineIndices.contains { backends[$0].isAdvertising }
    }

    /// Starts advertising on every powered-on child. A single `didStartAdvertising` follows
    /// once every one of them has reported, carrying the first non-`nil` error; a child that
    /// is not powered on is skipped — it could never report — and picks the advertisement up
    /// when it powers on.
    ///
    /// With *no* powered-on child the completion carries ``noPoweredOnBackendError``: nothing
    /// is advertising, so reporting success would be a lie. The advertisement is still
    /// remembered, and the first child to power on starts it.
    public func startAdvertising(_ advertisement: PeripheralAdvertisement) {
        dispatchPrecondition(condition: .onQueue(queue))
        _advertisement = advertisement
        let targets = onlineIndices
        for index in backends.indices where !targets.contains(index) {
            noteOffline(index, operation: "startAdvertising")
        }
        guard !targets.isEmpty else {
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                _eventHandler?(.didStartAdvertising(error: Self.noPoweredOnBackendError))
            }
            return
        }
        _pendingAdvertisements.append(Pending(owing: Set(targets), error: nil))
        for index in targets { backends[index].startAdvertising(advertisement) }
    }

    /// Stops advertising on every child.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        _advertisement = nil
        for backend in backends { backend.stopAdvertising() }
    }

    /// Publishes `service` on every powered-on child. A single `didAddService` follows once
    /// every one of them has reported, carrying the first non-`nil` error; a child that is not
    /// powered on is skipped — it could never report — and is caught up with the composite's
    /// services when it powers on.
    ///
    /// With *no* powered-on child the completion carries ``noPoweredOnBackendError``: the
    /// service reached no radio. It is still remembered, and the first child to power on
    /// publishes it.
    public func add(_ service: GATTService) {
        dispatchPrecondition(condition: .onQueue(queue))
        _services.removeAll { $0.identifier == service.identifier }
        _services.append(service)
        let targets = onlineIndices
        for index in backends.indices where !targets.contains(index) {
            noteOffline(index, operation: "add")
        }
        guard !targets.isEmpty else {
            let identifier = service.identifier
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                _eventHandler?(.didAddService(identifier, error: Self.noPoweredOnBackendError))
            }
            return
        }
        _pendingAdds[service.identifier, default: []].append(Pending(owing: Set(targets), error: nil))
        for index in targets { backends[index].add(service) }
    }

    /// Clears every child's GATT database.
    public func removeAllHostedServices() {
        dispatchPrecondition(condition: .onQueue(queue))
        _services.removeAll()
        for backend in backends { backend.removeAllHostedServices() }
    }

    /// Offers the response to every child; the children that never minted `token` ignore it,
    /// per the seam's contract — which is why no routing table is needed.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.respond(to: token, value: value, error: error) }
    }

    /// Delivers `value` to every powered-on child — now if it will take it, from that child's
    /// FIFO if it will not.
    ///
    /// **Per-child FIFOs, not a shared outstanding push.** For each powered-on child: if it
    /// owes nothing and accepts the push, it is done; otherwise the push joins the back of
    /// *that child's* FIFO, which its next `readyToUpdateSubscribers` drains in order. A value
    /// therefore reaches each such child exactly once and in order, whatever the children's
    /// windows are doing, and two pushes carrying identical bytes are two pushes — nothing
    /// here compares payloads or infers a retry. A child that is not powered on refuses every
    /// push and can never drain, so it is skipped outright rather than queued for.
    ///
    /// - Returns: `true` when every powered-on child either took the value or queued it.
    ///   `false` — the composite's window closing — only when some powered-on child has
    ///   already fallen a full `queueLimit` behind, in which case *nothing* is pushed or
    ///   queued, so the caller's re-offer after the next `readyToUpdateSubscribers` is the
    ///   value's first and only delivery.
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
            guard isOnline(index) else {
                noteOffline(index, operation: "updateValue")
                continue
            }
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
