//
//  CompositeCentral.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Dispatch
import Foundation

/// A `CentralManaging` made of several — every call fans out to every child
/// backend, and every child's events fan back in as one stream.
///
/// This is what lets one central-role connection be served by *both* an in-process
/// ``VirtualRadio`` and the Mac's real CoreBluetooth at the same time: hand
/// `Central(backend:queue:)` a composite of a ``VirtualCentralBackend`` and a real
/// `CBCentralManager`-backed shim, and a single `Central` scans, retrieves, and connects
/// across both worlds without knowing there is more than one radio.
///
/// **Routing is unnecessary by construction.** `CentralManaging` specifies
/// that `connect`/`cancelPeripheralConnection` given a peripheral from a *different* shim
/// family is a silent no-op rather than a trap, so ``connect(_:options:requiresANCS:)`` and
/// ``cancelPeripheralConnection(_:)`` simply call every child and let the mismatched ones
/// ignore the call. The composite keeps no peripheral-to-backend map.
///
/// **Only powered-on children are scanned on.** CoreBluetooth drops a
/// `scanForPeripherals(withServices:options:)` issued to a manager that is not
/// `CentralState/poweredOn`, and never re-issues it — so a child that was off when the scan
/// started would stay dark for the rest of the scan even after its radio came back. The
/// composite therefore *remembers* the current scan and the current connection-event
/// registration, skips the children that cannot serve them (logging each skipped child once),
/// and re-issues both to a child the moment it transitions into `poweredOn` — the
/// central-role counterpart of ``CompositePeripheralManager``'s catch-up republish.
/// ``stopScan()`` and ``unregisterForConnectionEvents()`` forget what they undo, so a child
/// powering on after them picks nothing up.
///
/// **Concurrency — queue-confined, not lock-protected.** Every stored property is
/// `nonisolated(unsafe)` and touched only on ``queue``, which every `CentralManaging`
/// member asserts at entry.
///
/// - Important: **Every child must be confined to the same `queue` this composite is
///   created with.** That single shared queue is what makes fan-in sound with no hops: a
///   child's event arrives already on `queue` (asynchronously, per the seam's delivery
///   contract), so the composite can forward it inline. A child on a different queue trips
///   the composite's own `dispatchPrecondition`.
///
/// - Important: ``init(backends:queue:log:)`` installs the children's event handlers with
///   `queue.sync`, so it must not be called from `queue` itself. Code already running on
///   `queue` — which is where a real `CBCentralManager` has to be built and wired without
///   yielding — uses `init(backends:onQueue:log:)` instead.
public final class CompositeCentral: CentralManaging, Sendable {

    /// The queue every method, property access, and event delivery is confined to — and
    /// the queue every child backend must also be confined to.
    public let queue: DispatchSerialQueue

    /// The children, in priority order: the first backend wins identifier collisions in
    /// ``retrievePeripherals(withIdentifiers:)`` and supplies the fallback
    /// ``radioState``. `nonisolated(unsafe)` because `any CentralManaging` is not itself
    /// `Sendable`; the array is immutable and only ever read on ``queue``.
    nonisolated(unsafe) private let backends: [any CentralManaging]

    nonisolated(unsafe) private var _eventHandler: ((CentralEvent) -> Void)?
    nonisolated(unsafe) private var _announcedState = false
    nonisolated(unsafe) private var _lastEmittedState: CentralState?

    /// Each child's last observed ``BLESwiftCore/CentralState``, indexed like ``backends`` —
    /// what a `didUpdateState` is compared against to spot a child entering `poweredOn`.
    nonisolated(unsafe) private var _childStates: [CentralState] = []

    /// One live scan, as the caller asked for it.
    private struct Scan {
        let services: [ServiceIdentifier]?
        let options: ScanOptions
    }

    /// The scan currently running, or `nil` once ``stopScan()`` has been called — what a child
    /// coming up to `poweredOn` is re-issued.
    nonisolated(unsafe) private var _scan: Scan?

    /// One live connection-event registration, as the caller asked for it.
    private struct ConnectionEventRegistration {
        let services: [ServiceIdentifier]?
        let peripherals: [UUID]?
    }

    /// The connection-event registration currently in force, or `nil` once
    /// ``unregisterForConnectionEvents()`` has been called.
    nonisolated(unsafe) private var _connectionEvents: ConnectionEventRegistration?

    /// The children already reported as skipped for being powered off — logged once per child,
    /// not once per operation.
    nonisolated(unsafe) private var _loggedOffline: Set<Int> = []

    /// Where this composite reports a child it had to skip, if anywhere.
    private let log: (@Sendable (String) -> Void)?

    /// The authorization status this composite reports: always
    /// `BluetoothAuthorization.allowedAlways`.
    ///
    /// `bluetoothAuthorization` is a `static` on the seam (mirroring `CBManager`'s class
    /// property), so a composite of *instances* has no way to consult its children — and
    /// no single answer to give even if it could. `.allowedAlways` is the honest default
    /// for a composite whose whole point is that at least one member is a virtual radio,
    /// which the system's Bluetooth permission never gates. Ask a concrete backend type
    /// when the real system answer matters.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// Creates a composite over `backends`, confined to `queue`.
    ///
    /// Each child's `eventHandler` is installed here (inside `queue.sync`, since those
    /// setters are themselves queue-confined) and captures the composite weakly, so the
    /// wiring never keeps it alive.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. Must all be confined to `queue`.
    ///   - queue: The shared queue — the same one the owning `Central` is constructed with.
    ///   - log: Where to report a child skipped for not being powered on, if anywhere.
    public init(
        backends: [any CentralManaging],
        queue: DispatchSerialQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.backends = backends
        self.queue = queue
        self.log = log
        queue.sync { attachChildren() }
    }

    /// Creates a composite over `backends` **from `queue` itself**, attaching the children
    /// without hopping.
    ///
    /// The one way to build both children and the composite over them inside a single
    /// `queue.sync`, so the queue never yields between a child's construction and the moment
    /// its `eventHandler` exists — which is what ``CoreBluetoothBackends`` requires of a real
    /// `CBCentralManager`, whose opening `didUpdateState` is otherwise delivered to no one.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. Must all be confined to `queue`.
    ///   - queue: The shared queue, which this call must already be running on.
    ///   - log: Where to report a child skipped for not being powered on, if anywhere.
    package init(
        backends: [any CentralManaging],
        onQueue queue: DispatchSerialQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.backends = backends
        self.queue = queue
        self.log = log
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

    /// Whether child `index` can currently serve a scan. Must be called on ``queue``.
    private func isOnline(_ index: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return backends[index].radioState == .poweredOn
    }

    /// The children a fan-out may reach. Must be called on ``queue``.
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

    /// Re-issues whatever is in force to every child that is not powered on. Must be called on
    /// ``queue``.
    private func skipOfflineChildren(operation: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        for index in backends.indices where !isOnline(index) {
            noteOffline(index, operation: operation)
        }
    }

    /// Reconciles child `index` entering `poweredOn`, catching it up with the scan and the
    /// connection-event registration it could not have served while it was off. Must be called
    /// on ``queue``.
    ///
    /// Driven by the state the child *reported*, never by its live `radioState`: two
    /// transitions that coalesce before this handler drains both read the same live value, so
    /// re-reading it would see `was == now` for each and skip the reconciliation the power
    /// cycle earned.
    ///
    /// - Parameters:
    ///   - index: The child that reported a state.
    ///   - now: The state it reported, from the `didUpdateState` payload.
    private func childChangedState(_ index: Int, to now: CentralState) {
        dispatchPrecondition(condition: .onQueue(queue))
        let was = _childStates[index]
        guard was != now else { return }
        _childStates[index] = now
        guard was != .poweredOn, now == .poweredOn else { return }
        _loggedOffline.remove(index)
        if let scan = _scan {
            backends[index].scanForPeripherals(withServices: scan.services, options: scan.options)
        }
        if let registration = _connectionEvents {
            backends[index].registerForConnectionEvents(
                services: registration.services,
                peripherals: registration.peripherals
            )
        }
    }

    /// The composite's state: ``BLESwiftCore/CentralState/poweredOn`` if *any* child is on
    /// (one usable radio is enough to serve the connection), otherwise the first child's
    /// state. Must be called on ``queue``.
    private var computedState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        if backends.contains(where: { $0.radioState == .poweredOn }) { return .poweredOn }
        return backends.first?.radioState ?? .unknown
    }

    /// Emits `didUpdateState` if ``computedState`` differs from what was last emitted (or
    /// unconditionally, for the one-shot announcement on first handler attach). Must be
    /// called on ``queue``.
    private func emitState(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let state = computedState
        guard force || state != _lastEmittedState else { return }
        _lastEmittedState = state
        _eventHandler?(.didUpdateState(state))
    }

    /// Fans one child's event in. Must be called on ``queue`` — which it always is, because
    /// every child is confined to that same queue and delivers asynchronously on it.
    private func handle(_ event: CentralEvent, from index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case .didUpdateState(let state):
            // Never forwarded verbatim: one child powering off says nothing about the
            // composite, which is still served by the others.
            childChangedState(index, to: state)
            emitState()
        case .willRestoreState:
            // Dropped. Restoration is a per-manager, iOS-only concept; replaying one
            // child's restored state as the composite's would claim sessions the other
            // children know nothing about.
            break
        default:
            _eventHandler?(event)
        }
    }

    // MARK: - CentralManaging

    /// Receives every `CentralEvent` fanned in from the children, on
    /// ``queue``.
    ///
    /// Setting a non-`nil` handler (re)installs the composite on every child; setting `nil`
    /// clears every child's handler, detaching the whole tree. The first non-`nil`
    /// attachment also triggers the one-shot `didUpdateState` announcement, exactly as the
    /// other backends do — CoreBluetooth reports its state only through the delegate.
    public var eventHandler: ((CentralEvent) -> Void)? {
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

    /// Starts a scan on every powered-on child, and remembers it: a child that is not powered
    /// on is skipped — CoreBluetooth would have dropped the scan — and is re-issued it when it
    /// powers on.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        dispatchPrecondition(condition: .onQueue(queue))
        _scan = Scan(services: services, options: options)
        skipOfflineChildren(operation: "scanForPeripherals")
        for index in onlineIndices {
            backends[index].scanForPeripherals(withServices: services, options: options)
        }
    }

    /// Stops the scan on every child and forgets it, so a child powering on afterwards does
    /// not pick a scan the caller has already ended back up.
    public func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        _scan = nil
        for backend in backends { backend.stopScan() }
    }

    /// Asks every child to connect `peripheral`. Children of a different shim family ignore
    /// it silently, per `CentralManaging.connect(_:options:requiresANCS:)` —
    /// which is why no routing table is needed.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.connect(peripheral, options: options, requiresANCS: requiresANCS) }
    }

    /// Asks every child to cancel `peripheral`'s connection; mismatched families no-op, as
    /// in ``connect(_:options:requiresANCS:)``.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.cancelPeripheralConnection(peripheral) }
    }

    /// Every child's answer, concatenated in child order and de-duplicated by
    /// `PeripheralRemote.identifier` — the first backend to vend an
    /// identifier wins it.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return deduplicated(backends.map { $0.retrievePeripherals(withIdentifiers: identifiers) })
    }

    /// Every child's answer, concatenated and de-duplicated exactly as in
    /// ``retrievePeripherals(withIdentifiers:)``.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return deduplicated(backends.map { $0.retrieveConnectedPeripherals(withServices: services) })
    }

    /// Flattens `answers` in order, keeping the first remote seen for each identifier.
    private func deduplicated(_ answers: [[any PeripheralRemote]]) -> [any PeripheralRemote] {
        var seen = Set<UUID>()
        var result: [any PeripheralRemote] = []
        for answer in answers {
            for peripheral in answer where seen.insert(peripheral.identifier).inserted {
                result.append(peripheral)
            }
        }
        return result
    }

    /// Registers on every powered-on child (a no-op on the children for which the underlying
    /// API does not exist), and remembers the registration: a child that is not powered on is
    /// skipped and registered when it powers on.
    public func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionEvents = ConnectionEventRegistration(services: services, peripherals: peripherals)
        skipOfflineChildren(operation: "registerForConnectionEvents")
        for index in onlineIndices {
            backends[index].registerForConnectionEvents(services: services, peripherals: peripherals)
        }
    }

    /// Unregisters on every child and forgets the registration.
    public func unregisterForConnectionEvents() {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionEvents = nil
        for backend in backends { backend.unregisterForConnectionEvents() }
    }
}
#endif
