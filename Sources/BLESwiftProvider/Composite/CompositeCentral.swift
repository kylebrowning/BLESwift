//
//  CompositeCentral.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Dispatch
import Foundation

/// A `CentralManaging` that sends every call to several child backends and merges their events
/// into one stream.
///
/// Give `Central(backend:queue:)` a composite of a ``VirtualCentralBackend`` and a real
/// CoreBluetooth shim. One `Central` then scans, retrieves, and connects on both radios.
///
/// - `connect` and `cancelPeripheralConnection` go to every child. A child ignores a peripheral
///   from another shim family.
/// - The composite scans, and registers for connection events, only on powered-on children. It
///   does both again when a child powers on.
/// - Important: Every child must be confined to the same `queue` that you give to this composite.
///   Do not call ``init(backends:queue:log:)`` from `queue`. Code that runs on `queue` must use
///   `init(backends:onQueue:log:)`.
///
/// The queue confines the state, and no lock protects it.
/// See <doc:BLESwiftProvider#Composite-backends>.
public final class CompositeCentral: CentralManaging, Sendable {

    /// The queue to which every method, property access, and event delivery is confined. Every
    /// child backend must also be confined to this queue.
    public let queue: DispatchQueue

    /// The children, in priority order. The first backend wins identifier collisions in
    /// ``retrievePeripherals(withIdentifiers:)`` and supplies the fallback ``radioState``. The
    /// property is `nonisolated(unsafe)` because `any CentralManaging` is not `Sendable`. The
    /// array is immutable. Code reads it only on ``queue``.
    nonisolated(unsafe) private let backends: [any CentralManaging]

    nonisolated(unsafe) private var _eventHandler: ((CentralEvent) -> Void)?
    nonisolated(unsafe) private var _announcedState = false
    nonisolated(unsafe) private var _lastEmittedState: CentralState?

    /// The last ``BLESwiftCore/CentralState`` that the composite observed for each child, at the
    /// child's index in ``backends``. The composite compares a `didUpdateState` with this value
    /// to see that a child enters `poweredOn`.
    nonisolated(unsafe) private var _childStates: [CentralState] = []

    /// One live scan, as the caller asked for it.
    private struct Scan {
        let services: [ServiceIdentifier]?
        let options: ScanOptions
    }

    /// The scan that runs now, or `nil` after ``stopScan()``. The composite issues this scan
    /// again to a child that changes to `poweredOn`.
    nonisolated(unsafe) private var _scan: Scan?

    /// One live registration for connection events, as the caller asked for it.
    private struct ConnectionEventRegistration {
        let services: [ServiceIdentifier]?
        let peripherals: [UUID]?
    }

    /// The registration for connection events that is in force, or `nil` after
    /// ``unregisterForConnectionEvents()``.
    nonisolated(unsafe) private var _connectionEvents: ConnectionEventRegistration?

    /// The children that the composite already reported as skipped because they are powered off.
    /// The composite logs each child once, not once for each operation.
    nonisolated(unsafe) private var _loggedOffline: Set<Int> = []

    /// Where this composite reports a child that it skipped.
    private let log: (@Sendable (String) -> Void)?

    /// The authorization status that this composite reports. It is always
    /// `BluetoothAuthorization.allowedAlways`.
    ///
    /// `bluetoothAuthorization` is a `static` member on the seam, like the `CBManager` class
    /// property. A composite of *instances* cannot ask its children, and it has no single answer
    /// to give. `.allowedAlways` is the correct default when at least one member is a virtual
    /// radio, because the system's Bluetooth permission never gates a virtual radio. For the
    /// system's real answer, ask a concrete backend type.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// Creates a composite over `backends`, confined to `queue`.
    ///
    /// This initializer installs each child's `eventHandler` inside `queue.sync`, because those
    /// setters are confined to the queue. The handler captures the composite weakly, so the
    /// wiring does not keep the composite alive.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. All must be confined to `queue`.
    ///   - queue: The shared serial queue. It is the queue with which you construct the owning
    ///     `Central`.
    ///   - log: Where to report a child that the composite skips because it is not powered on.
    ///     If `nil`, the composite does not report skipped children.
    public init(
        backends: [any CentralManaging],
        queue: DispatchQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.backends = backends
        self.queue = queue
        self.log = log
        queue.sync { attachChildren() }
    }

    /// Creates a composite over `backends` **from `queue` itself**. This initializer attaches
    /// the children without a hop.
    ///
    /// Use it to build both the children and the composite inside a single `queue.sync`, so the
    /// queue never yields between a child's construction and its `eventHandler`.
    /// ``CoreBluetoothBackends`` requires this for a real `CBCentralManager`. Otherwise its
    /// first `didUpdateState` goes to no one.
    ///
    /// - Parameters:
    ///   - backends: The children, in priority order. All must be confined to `queue`.
    ///   - queue: The shared queue. This call must already run on it.
    ///   - log: Where to report a child that the composite skips because it is not powered on.
    ///     If `nil`, the composite does not report skipped children.
    package init(
        backends: [any CentralManaging],
        onQueue queue: DispatchQueue,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.backends = backends
        self.queue = queue
        self.log = log
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

    /// Whether child `index` can serve a scan now. Call it on ``queue``.
    private func isOnline(_ index: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return backends[index].radioState == .poweredOn
    }

    /// The children that a fan-out can reach. Call it on ``queue``.
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

    /// Reports each child that is not powered on as skipped for `operation`, once for each child.
    /// Call it on ``queue``.
    private func skipOfflineChildren(operation: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        for index in backends.indices where !isOnline(index) {
            noteOffline(index, operation: operation)
        }
    }

    /// Reconciles child `index` when it enters `poweredOn`. The method gives the child the scan
    /// and the registration for connection events that it could not serve while it was off. Call
    /// it on ``queue``.
    ///
    /// The method uses the state that the child *reported*, never the child's live `radioState`.
    /// Two transitions can coalesce before this handler drains them, and both would then read
    /// the same live value. The method would see `was == now` for each transition and skip the
    /// reconciliation that the power cycle earned.
    ///
    /// - Parameters:
    ///   - index: The child that reported a state.
    ///   - now: The state that the child reported, from the `didUpdateState` payload.
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

    /// The composite's state. It is ``BLESwiftCore/CentralState/poweredOn`` if *any* child is on,
    /// because one usable radio is enough. Otherwise it is the first child's state. Call it on
    /// ``queue``.
    private var computedState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        if backends.contains(where: { $0.radioState == .poweredOn }) { return .poweredOn }
        return backends.first?.radioState ?? .unknown
    }

    /// Emits `didUpdateState` if ``computedState`` differs from the last emitted state. With
    /// `force`, it emits unconditionally, for the one-shot announcement when the first handler
    /// attaches. Call it on ``queue``.
    private func emitState(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let state = computedState
        guard force || state != _lastEmittedState else { return }
        _lastEmittedState = state
        _eventHandler?(.didUpdateState(state))
    }

    /// Fans in one child's event. Every child delivers asynchronously on ``queue``, so this runs
    /// on ``queue``.
    private func handle(_ event: CentralEvent, from index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case .didUpdateState(let state):
            // Never forward it as it is. When one child powers off, the other children still serve
            // the composite.
            childChangedState(index, to: state)
            emitState()
        case .willRestoreState:
            // Drop it. Restoration belongs to each manager and exists only on iOS. A replay of one
            // child's restored state as the composite's own would claim sessions that the other
            // children do not know.
            break
        default:
            _eventHandler?(event)
        }
    }

    // MARK: - CentralManaging

    /// Receives every `CentralEvent` that the composite fans in from the children, on
    /// ``queue``.
    ///
    /// A non-`nil` handler (re)installs the composite on every child. `nil` clears every child's
    /// handler and detaches the whole tree. The first non-`nil` attachment also triggers the
    /// one-shot `didUpdateState` announcement, as in the other backends, because CoreBluetooth
    /// reports its state only through the delegate.
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

    /// `CentralState.poweredOn` if any child is powered on. Otherwise the first child's state
    /// (`CentralState.unknown` if there are no children).
    public var radioState: CentralState {
        computedState
    }

    /// Starts a scan on every child that is powered on, and remembers the scan. It skips a child
    /// that is not powered on, because CoreBluetooth would drop the scan, and issues the scan to
    /// that child when it powers on.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        dispatchPrecondition(condition: .onQueue(queue))
        _scan = Scan(services: services, options: options)
        skipOfflineChildren(operation: "scanForPeripherals")
        for index in onlineIndices {
            backends[index].scanForPeripherals(withServices: services, options: options)
        }
    }

    /// Stops the scan on every child and forgets it, so a child that powers on afterwards does
    /// not pick up a scan that the caller ended.
    public func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        _scan = nil
        for backend in backends { backend.stopScan() }
    }

    /// Asks every child to connect `peripheral`. A child of a different shim family ignores the
    /// request, as `CentralManaging.connect(_:options:requiresANCS:)` specifies. Thus the
    /// composite needs no routing table.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.connect(peripheral, options: options, requiresANCS: requiresANCS) }
    }

    /// Asks every child to cancel `peripheral`'s connection. Children of a different family do
    /// nothing, as in ``connect(_:options:requiresANCS:)``.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.cancelPeripheralConnection(peripheral) }
    }

    /// The answers of all children, joined in child order and de-duplicated by
    /// `PeripheralRemote.identifier`. The first backend that supplies an identifier wins.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return deduplicated(backends.map { $0.retrievePeripherals(withIdentifiers: identifiers) })
    }

    /// The answers of all children, joined and de-duplicated as in
    /// ``retrievePeripherals(withIdentifiers:)``.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return deduplicated(backends.map { $0.retrieveConnectedPeripherals(withServices: services) })
    }

    /// Flattens `answers` in order and keeps the first remote for each identifier.
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

    /// Registers on every child that is powered on, and remembers the registration. On a child
    /// without the underlying API, the call does nothing. The composite skips a child that is
    /// not powered on and registers it when it powers on.
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
