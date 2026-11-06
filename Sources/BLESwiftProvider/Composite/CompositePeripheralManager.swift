//
//  CompositePeripheralManager.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// A `PeripheralManaging` that sends every call to several child backends. It is the
/// peripheral-role counterpart of ``CompositeCentral``.
///
/// One `PeripheralHost` over a composite publishes the same GATT database, advertisement, and
/// notifications on a ``VirtualRadio`` and on the Mac's real CoreBluetooth. The requests from any
/// child come out as one event stream.
///
/// - ``add(_:)`` and ``startAdvertising(_:)`` complete once, with the first non-`nil` error. If no
///   child is powered on, they complete with ``noPoweredOnBackendError``.
/// - A child that is not powered on is skipped. The composite publishes to it again when it powers
///   on.
/// - ``updateValue(_:for:onSubscribed:)`` keeps one FIFO for each child.
/// - Important: Every child must be confined to the same `queue`. Do not call
///   ``init(backends:queue:log:)`` from that queue.
///
/// See <doc:BLESwiftProvider#Composite-backends>.
public final class CompositePeripheralManager: PeripheralManaging, HostedDeviceRemoving, Sendable {

    /// One outstanding fan-out that waits for the completions of its children.
    private struct Pending {
        /// The children that have not yet reported, by index into ``backends``.
        var owing: Set<Int>
        /// The first non-`nil` error that a child reported so far.
        var error: NSError?
    }

    /// The queue to which every method, property access, and event delivery is confined. Every
    /// child backend must also be confined to this queue.
    public let queue: DispatchQueue

    /// The children, in priority order. The first child supplies the fallback ``radioState``.
    /// The property is `nonisolated(unsafe)` because `any PeripheralManaging` is not
    /// `Sendable`. The array is immutable. Code reads it only on ``queue``.
    nonisolated(unsafe) private let backends: [any PeripheralManaging]

    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _announcedState = false
    nonisolated(unsafe) private var _lastEmittedState: CentralState?

    /// Outstanding ``add(_:)`` fan-outs, keyed by service and held in FIFO order. Thus each
    /// repeated add of the same service gets its own aggregated completion.
    nonisolated(unsafe) private var _pendingAdds: [ServiceIdentifier: [Pending]] = [:]

    /// Outstanding ``startAdvertising(_:)`` fan-outs, in FIFO order.
    nonisolated(unsafe) private var _pendingAdvertisements: [Pending] = []

    /// One push that a child has not taken yet, held unchanged in the child's FIFO.
    private struct PendingPush {
        let value: Data
        let characteristic: CharacteristicIdentifier
        let subscribers: [Subscriber]?
    }

    /// What each child still owes its subscribers, oldest first, at the child's index in
    /// ``backends``. A child's FIFO grows when the child refuses a push and drains, in order, on
    /// the child's `readyToUpdateSubscribers`. Its size is bounded at ``queueLimit``. A *proven*
    /// child's FIFO stops growing because the composite's window closes on it. An unproven
    /// child's FIFO stops growing because the composite drops its oldest entry. See ``_proven``.
    nonisolated(unsafe) private var _queues: [[PendingPush]] = []

    /// The last ``BLESwiftCore/CentralState`` that the composite observed for each child, at the
    /// child's index in ``backends``. The composite compares a `didUpdateState` with this value
    /// to see that a child enters or leaves `poweredOn`.
    nonisolated(unsafe) private var _childStates: [CentralState] = []

    /// The services that this composite published, with the newest write for each identifier.
    /// A child that comes back to `poweredOn` receives these services.
    nonisolated(unsafe) private var _services: [GATTService] = []

    /// The advertisement that this composite runs, or `nil` after ``stopAdvertising()``. A child
    /// that comes back to `poweredOn` restarts with this advertisement.
    nonisolated(unsafe) private var _advertisement: PeripheralAdvertisement?

    /// The number of `didAddService`/`didStartAdvertising` completions from each child that
    /// the composite must swallow, not aggregate or forward. These are the completions that the
    /// catch-up republish of the child produces. The host must never hear them.
    ///
    /// Only ``powerUp(child:)`` sets the bound. The count does not include what a child owed when
    /// it powered off. A radio that goes away abandons those operations, so their completions may
    /// never arrive. The composite swallows them on the child's state instead. See
    /// ``powerDown(child:)``.
    nonisolated(unsafe) private var _swallowedAdds: [Int] = []
    nonisolated(unsafe) private var _swallowedAdvertisements: [Int] = []

    /// The children that the composite already reported as skipped because they are powered off.
    /// The composite logs each child once, not once for each operation.
    nonisolated(unsafe) private var _loggedOffline: Set<Int> = []

    /// Whether each child has *proved*, in its current power cycle, that its refusals are real
    /// back-pressure. A child proves this when it takes a push or raises a
    /// `readyToUpdateSubscribers` of its own. The index is the same as in ``backends``.
    /// ``powerDown(child:)`` and ``powerUp(child:)`` reset it.
    ///
    /// The FIFO for each child relies on this rule: a child that returned `false` will raise
    /// `readyToUpdateSubscribers`. A real `CBPeripheralManager` breaks the rule. It refuses a
    /// push for a characteristic with no live handle (never added, or removed) without a call to
    /// CoreBluetooth, and no readiness follows. Nothing drains that child's FIFO. If
    /// ``isAnyQueueFull`` counted such a child, the composite's window would stay shut for the
    /// life of the session and stop the notifications for *every* characteristic on *every*
    /// child. Thus a child that has never taken anything never closes the window. See
    /// ``updateValue(_:for:onSubscribed:)``.
    nonisolated(unsafe) private var _proven: [Bool] = []

    /// The children that the composite already reported as children that drop queued pushes.
    /// An unproven child that refuses forever thus costs one line for each power cycle, not one
    /// line for each push.
    nonisolated(unsafe) private var _loggedDropping: Set<Int> = []

    /// Whether the composite told its host that the window is closed, and owes the host one
    /// `readyToUpdateSubscribers`. The `false` that closed the window sets this value. The
    /// single event that reopens the window clears it.
    nonisolated(unsafe) private var _windowClosed = false

    /// The completion of ``add(_:)`` and ``startAdvertising(_:)`` when *no* child is powered
    /// on. In that case the composite published nothing and nothing advertises. The caller must
    /// know this.
    ///
    /// A skipped child is normally harmless, because the children that are powered on carry the
    /// operation and the composite catches up the skipped child when it powers on. If no child is
    /// powered on, nobody can carry the operation. A report of success would let a
    /// `PeripheralHost` believe that it had published a database and started an advertisement
    /// that reached no radio. When its manager is off, CoreBluetooth fails both operations
    /// immediately. This composite does the same.
    public static var noPoweredOnBackendError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "no powered-on backend"]
        )
    }

    /// The number of pushes by which one child can fall behind before the composite closes its
    /// window. It is the window that the link's client honors, so a composite behind a link
    /// cannot queue more pushes than the link lets through.
    private static var queueLimit: Int { LinkFlowControl.updateValueWindow }

    /// The authorization status that this composite reports. It is always
    /// `BluetoothAuthorization.allowedAlways`. See ``CompositeCentral/bluetoothAuthorization``.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// Where this composite reports a child that falls a whole window behind.
    private let log: (@Sendable (String) -> Void)?

    /// Creates a composite over `backends`, confined to `queue`.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. All must be confined to `queue`.
    ///   - queue: The shared serial queue. It is the queue with which you construct the owning
    ///     `PeripheralHost`.
    ///   - log: Where to report a child whose FIFO has filled, or that the composite skipped
    ///     because it is powered off. If `nil`, the composite does not report.
    public init(
        backends: [any PeripheralManaging],
        queue: DispatchQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.backends = backends
        self.queue = queue
        self.log = log
        self._queues = Array(repeating: [], count: backends.count)
        self._proven = Array(repeating: false, count: backends.count)
        self._swallowedAdds = Array(repeating: 0, count: backends.count)
        self._swallowedAdvertisements = Array(repeating: 0, count: backends.count)
        queue.sync { attachChildren() }
    }

    /// Creates a composite over `backends` **from `queue` itself**. This initializer attaches
    /// the children without a hop. It is the peripheral-role counterpart of
    /// `CompositeCentral.init(backends:onQueue:log:)`. Use it to build both the children and the
    /// composite inside a single `queue.sync`.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. All must be confined to `queue`.
    ///   - queue: The shared queue. This call must already run on it.
    ///   - log: Where to report a child whose FIFO has filled, or that the composite skipped
    ///     because it is powered off. If `nil`, the composite does not report.
    package init(
        backends: [any PeripheralManaging],
        onQueue queue: DispatchQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.backends = backends
        self.queue = queue
        self.log = log
        self._queues = Array(repeating: [], count: backends.count)
        self._proven = Array(repeating: false, count: backends.count)
        self._swallowedAdds = Array(repeating: 0, count: backends.count)
        self._swallowedAdvertisements = Array(repeating: 0, count: backends.count)
        attachChildren()
    }

    /// Installs this composite as the event sink of every child and records each child's
    /// starting state. Repeated calls are safe. Call it on ``queue``.
    private func attachChildren() {
        dispatchPrecondition(condition: .onQueue(queue))
        _childStates = backends.map(\.radioState)
        for index in backends.indices {
            backends[index].eventHandler = { [weak self] event in
                self?.handle(event, from: index)
            }
        }
    }

    /// Whether child `index` can answer a completion and accept a push now. Call it on
    /// ``queue``.
    private func isOnline(_ index: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return backends[index].radioState == .poweredOn
    }

    /// The children for which a fan-out can wait. Call it on ``queue``.
    private var onlineIndices: [Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return backends.indices.filter { isOnline($0) }
    }

    /// Reports once for each child that the composite skipped `index` because it is not powered
    /// on. Call it on ``queue``.
    private func noteOffline(_ index: Int, operation: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _loggedOffline.insert(index).inserted else { return }
        log?("composite child \(index) is \(backends[index].radioState); skipping \(operation) until it powers on")
    }

    /// ``BLESwiftCore/CentralState/poweredOn`` if any child is on. Otherwise the first child's
    /// state. Call it on ``queue``.
    private var computedState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        if backends.contains(where: { $0.radioState == .poweredOn }) { return .poweredOn }
        return backends.first?.radioState ?? .unknown
    }

    /// Emits `didUpdateState` when ``computedState`` changes. With `force`, it emits
    /// unconditionally, for the one-shot announcement. Call it on ``queue``.
    private func emitState(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let state = computedState
        guard force || state != _lastEmittedState else { return }
        _lastEmittedState = state
        _eventHandler?(.didUpdateState(state))
    }

    /// Fans in one event from child `index`. Call it on ``queue``.
    private func handle(_ event: PeripheralHostEvent, from index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case .didUpdateState(let state):
            childChangedState(index, to: state)
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

    /// Reconciles child `index` when it enters or leaves `poweredOn`. Call it on ``queue``.
    ///
    /// The method uses the state that the child *reported*, never the child's live `radioState`.
    /// Two transitions can coalesce before this handler drains them, and both would then read
    /// the same live value. The method would see `was == now` for each transition and skip both
    /// the power-down and the republish that the cycle earned.
    ///
    /// - Parameters:
    ///   - index: The child that reported a state.
    ///   - now: The state that the child reported, from the `didUpdateState` payload.
    private func childChangedState(_ index: Int, to now: CentralState) {
        dispatchPrecondition(condition: .onQueue(queue))
        let was = _childStates[index]
        guard was != now else { return }
        _childStates[index] = now
        if was == .poweredOn, now != .poweredOn {
            powerDown(child: index)
        } else if was != .poweredOn, now == .poweredOn {
            powerUp(child: index)
        }
    }

    /// Settles everything that child `index` still owed, and drops what it will never take.
    /// While the child is not powered on, it cannot answer a completion or a push, so the host
    /// must not wait for it. Call it on ``queue``.
    ///
    /// **The method emits every completion last, after it has written every table.** A handler
    /// can call straight back into this composite. A handler that did this from the middle of
    /// the `_pendingAdds` walk would have its new batch overwritten by the stale snapshot that
    /// the walk writes back.
    private func powerDown(child index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        _queues[index].removeAll()
        // A radio that went away proved nothing about the radio that comes back. The handles
        // over which it served pushes are gone with it.
        _proven[index] = false
        _loggedDropping.remove(index)

        // Accumulate the completions and emit them only after every table below is written. The
        // loop walks a snapshot of `_pendingAdds`. A handler that called ``add(_:)`` again
        // synchronously would append a batch under a key that the loop has not reached, and the
        // write-back of the stale snapshot would destroy that batch. The child's own
        // `didAddService` would then be forwarded for each child and not aggregated once.
        var settledAdds: [(identifier: ServiceIdentifier, error: NSError?)] = []
        for (identifier, batches) in _pendingAdds {
            var remaining: [Pending] = []
            for var batch in batches {
                guard batch.owing.remove(index) != nil else {
                    remaining.append(batch)
                    continue
                }
                if batch.owing.isEmpty {
                    settledAdds.append((identifier, batch.error))
                } else {
                    remaining.append(batch)
                }
            }
            _pendingAdds[identifier] = remaining.isEmpty ? nil : remaining
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

        // Reset the swallow counters. A `CBPeripheralManager` that leaves `.poweredOn`
        // *abandons* the adds and the advertisement that it had in flight, so the completions
        // that the counters stood for may never arrive. A counter that survived the power-down
        // would never come back down, and the code would swallow the child's next own completion
        // in place of one that was never coming. A child that is no longer powered on can still
        // send completions. ``completeAdd(_:error:from:)`` and
        // ``completeAdvertising(error:from:)`` swallow them on the child's *state*, with no
        // counter. Thus ``powerUp(child:)`` bounds both counters by what it issues again.
        _swallowedAdds[index] = 0
        _swallowedAdvertisements[index] = 0

        reopenWindowIfPossible()

        // Every table is settled, so a handler that calls back from here finds this composite
        // consistent, and whatever the handler queues survives.
        for settled in settledAdds { _eventHandler?(.didAddService(settled.identifier, error: settled.error)) }
        for error in settledAdvertisements { _eventHandler?(.didStartAdvertising(error: error)) }
    }

    /// Catches child `index` up with the composite's current services and advertisement, now
    /// that the child can serve them. The completions of these calls belong to this composite,
    /// not to the host. The method sets the two swallow counters to exactly the number of
    /// republishes for which this catch-up owes an answer. ``powerDown(child:)`` cleared the
    /// counters. Call it on ``queue``.
    private func powerUp(child index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        _loggedOffline.remove(index)
        // This is a new power cycle. This child has not proved anything yet.
        _proven[index] = false
        _loggedDropping.remove(index)
        for service in _services {
            _swallowedAdds[index] += 1
            backends[index].add(service)
        }
        if let advertisement = _advertisement {
            _swallowedAdvertisements[index] += 1
            backends[index].startAdvertising(advertisement)
        }
        // A window that closed because *nothing* was powered on can now reopen. This is the only
        // event that can reopen it, because a child that was never queued for raises no
        // `readyToUpdateSubscribers` of its own.
        reopenWindowIfPossible()
    }

    /// Emits the one `readyToUpdateSubscribers` that the host is owed, if the closed window can
    /// reopen now. Call it on ``queue``.
    private func reopenWindowIfPossible() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _windowClosed, !isAnyQueueFull else { return }
        _windowClosed = false
        _eventHandler?(.readyToUpdateSubscribers)
    }

    /// Drains what child `index` still owes, then decides what the host hears.
    ///
    /// If the window is closed, the composite has refused a push and the host is owed exactly one
    /// `readyToUpdateSubscribers`. It comes when no child FIFO is full any more, so several
    /// children that reopen produce one event, not one for each child. If the window is open,
    /// nothing is owed, and the composite forwards the child's readiness as it forwards every
    /// other event. Call it on ``queue``.
    private func resume(child index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        // A readiness of its own proves that the child serves pushes, even if the child has not
        // taken a push yet.
        markProven(index)
        drain(child: index)
        guard _windowClosed else {
            _eventHandler?(.readyToUpdateSubscribers)
            return
        }
        guard !isAnyQueueFull else { return }
        _windowClosed = false
        _eventHandler?(.readyToUpdateSubscribers)
    }

    /// Offers child `index` what it owes, oldest first, and stops at the first refusal. Thus the
    /// child's subscribers see the values in push order. Call it on ``queue``.
    private func drain(child index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isOnline(index) else { return }
        while let next = _queues[index].first {
            guard backends[index].updateValue(next.value, for: next.characteristic, onSubscribed: next.subscribers) else {
                return
            }
            markProven(index)
            _queues[index].removeFirst()
        }
    }

    /// Whether any powered-on, *proven* child has fallen a whole ``queueLimit`` behind. A child
    /// that is not powered on is never queued for, and a child that has never taken a push or
    /// raised a readiness of its own never closes the window. ``updateValue(_:for:onSubscribed:)``
    /// caps the FIFO of such a child instead. Call it on ``queue``.
    private var isAnyQueueFull: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _queues.indices.contains { isOnline($0) && _proven[$0] && _queues[$0].count >= Self.queueLimit }
    }

    /// The number of pushes that child `index` still owes its subscribers.
    ///
    /// This is not API. It exists for tests that assert that an unproven child's FIFO stays
    /// bounded and that a proven child's FIFO drains. Call it on ``queue``.
    package func queuedCountForTesting(child index: Int) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _queues[index].count
    }

    /// Records that child `index` really serves pushes: it took one, or it raised a
    /// `readyToUpdateSubscribers` of its own. From here, its refusals are back-pressure, and the
    /// composite can close its window for them. Call it on ``queue``.
    private func markProven(_ index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        _proven[index] = true
    }

    /// Settles one child's `didAddService`. It emits the aggregate when the last child that owes
    /// it has reported. Call it on ``queue``.
    ///
    /// The method swallows a completion from a child that is no longer powered on. It settles
    /// nothing, because ``powerDown(child:)`` released the child from every batch that it owed.
    /// The completion is the tail of an operation that this composite already settled without
    /// the child.
    private func completeAdd(_ identifier: ServiceIdentifier, error: NSError?, from index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isOnline(index) else { return }
        var batches = _pendingAdds[identifier] ?? []
        guard let position = batches.firstIndex(where: { $0.owing.contains(index) }) else {
            // A completion for a catch-up republish that ``powerUp(child:)`` issued. Swallow it.
            // Do not aggregate it.
            if _swallowedAdds[index] > 0 {
                _swallowedAdds[index] -= 1
                return
            }
            // A completion for an add that this composite never issued (a child that publishes on
            // its own). There is nothing to aggregate. Forward it unchanged.
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

    /// Settles one child's `didStartAdvertising`. It emits the aggregate when the last child that
    /// owes it has reported. The method swallows a completion from a child that is no longer
    /// powered on, as ``completeAdd(_:error:from:)`` does. Call it on ``queue``.
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

    // MARK: - HostedDeviceRemoving

    /// Takes the hosted device off the radio of every child that hosts one. Call it on ``queue``.
    package func removeHostedDevice() {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends {
            (backend as? any HostedDeviceRemoving)?.removeHostedDevice()
        }
    }

    // MARK: - PeripheralManaging

    /// Receives every `PeripheralHostEvent` that the composite fans in from the children, on
    /// ``queue``. Attach and detach work as in ``CompositeCentral/eventHandler``: a non-`nil`
    /// handler (re)installs the composite on every child, `nil` clears every child's handler, and
    /// the first non-`nil` attachment triggers the one-shot `didUpdateState` announcement.
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

    /// `CentralState.poweredOn` if any child is powered on. Otherwise the first child's state
    /// (`CentralState.unknown` if there are no children).
    public var radioState: CentralState {
        computedState
    }

    /// `true` when any *powered-on* child advertises. These are the children to which
    /// ``startAdvertising(_:)`` fans out. The value is `false` with no children or while every
    /// child is off.
    ///
    /// The property ignores children that are off. Otherwise it would report `false` for the
    /// arrangement in which `--passthrough` normally runs: a virtual child advertises beside a
    /// real `CBPeripheralManager` whose Bluetooth is off. ``startAdvertising(_:)`` skips that
    /// child, which picks up the advertisement when it powers on. The composite must not deny an
    /// advertisement that it really broadcasts.
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return onlineIndices.contains { backends[$0].isAdvertising }
    }

    /// Starts to advertise on every powered-on child. When every one of them has reported, a
    /// single `didStartAdvertising` follows with the first non-`nil` error. The method skips a
    /// child that is not powered on, because it could never report. That child picks up the
    /// advertisement when it powers on.
    ///
    /// If *no* child is powered on, the completion carries ``noPoweredOnBackendError``. The
    /// composite still remembers the advertisement, and the first child to power on starts it.
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

    /// Publishes `service` on every powered-on child. When every one of them has reported, a
    /// single `didAddService` follows with the first non-`nil` error. The method skips a child
    /// that is not powered on, because it could never report. That child receives the composite's
    /// services when it powers on.
    ///
    /// If *no* child is powered on, the completion carries ``noPoweredOnBackendError``. The
    /// composite still remembers the service, and the first child to power on publishes it.
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

    /// Clears the GATT database of every child.
    public func removeAllHostedServices() {
        dispatchPrecondition(condition: .onQueue(queue))
        _services.removeAll()
        for backend in backends { backend.removeAllHostedServices() }
    }

    /// Offers the response to every child. The children that never created `token` ignore it, as
    /// the seam's contract states. Thus the composite needs no routing table.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.respond(to: token, value: value, error: error) }
    }

    /// Delivers `value` to every powered-on child, now or from that child's FIFO, in push order.
    ///
    /// - Returns: `true` when every powered-on child took the value or queued it. `false`, and the
    ///   composite's window closes, if a powered-on child is a full `queueLimit` behind or no
    ///   child is powered on. In both cases the method pushes and queues nothing. The caller's
    ///   offer after the next `readyToUpdateSubscribers` is then the first delivery.
    ///
    /// Two pushes with identical bytes are two pushes. A child that is not powered on is skipped
    /// and not queued. See <doc:BLESwiftProvider#Composite-backends>.
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        // Check before delivering anything. A refused push must reach no child. Otherwise the
        // caller's second offer would notify some subscribers twice.
        guard !isAnyQueueFull else {
            _windowClosed = true
            return false
        }
        guard !onlineIndices.isEmpty else {
            for index in backends.indices { noteOffline(index, operation: "updateValue") }
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
                markProven(index)
                continue
            }
            _queues[index].append(pending)
            guard _proven[index] else {
                // A child that has never taken anything owes no readiness, so nothing can ever
                // drain this FIFO. Keep the newest ``queueLimit`` pushes: drop the oldest instead
                // of letting the FIFO grow without bound. The child still catches up in order if
                // it comes to life. Log one line for each child for each power cycle.
                if _queues[index].count > Self.queueLimit {
                    _queues[index].removeFirst()
                    if _loggedDropping.insert(index).inserted {
                        log?(
                            "composite child \(index) has taken no update on \(characteristic) and raised no "
                                + "readiness; dropping its oldest queued update(s) rather than closing the window"
                        )
                    }
                }
                continue
            }
            // Report only on the transition. The push that fills a FIFO is the last push that
            // this composite accepts until that child drains, so a child that never comes back
            // costs one line, not one line for each push.
            if _queues[index].count == Self.queueLimit {
                log?("composite child \(index) is \(Self.queueLimit) update(s) behind on \(characteristic); closing the window")
            }
        }
        return true
    }
}
#endif
