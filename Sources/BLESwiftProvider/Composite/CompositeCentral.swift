//
//  CompositeCentral.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Dispatch
import Foundation

/// A ``BLESwiftCore/CentralManaging`` made of several — every call fans out to every child
/// backend, and every child's events fan back in as one stream.
///
/// This is what lets one central-role connection be served by *both* an in-process
/// ``VirtualRadio`` and the Mac's real CoreBluetooth at the same time: hand
/// `Central(backend:queue:)` a composite of a ``VirtualCentralBackend`` and a real
/// `CBCentralManager`-backed shim, and a single `Central` scans, retrieves, and connects
/// across both worlds without knowing there is more than one radio.
///
/// **Routing is unnecessary by construction.** ``BLESwiftCore/CentralManaging`` specifies
/// that `connect`/`cancelPeripheralConnection` given a peripheral from a *different* shim
/// family is a silent no-op rather than a trap, so ``connect(_:options:requiresANCS:)`` and
/// ``cancelPeripheralConnection(_:)`` simply call every child and let the mismatched ones
/// ignore the call. The composite keeps no peripheral-to-backend map.
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
/// - Important: ``init(backends:queue:)`` installs the children's event handlers with
///   `queue.sync`, so it must not be called from `queue` itself.
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

    /// The authorization status this composite reports: always
    /// ``BLESwiftCore/BluetoothAuthorization/allowedAlways``.
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
    public init(backends: [any CentralManaging], queue: DispatchSerialQueue) {
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
    private func handle(_ event: CentralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case .didUpdateState:
            // Never forwarded verbatim: one child powering off says nothing about the
            // composite, which is still served by the others.
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

    /// Receives every ``BLESwiftCore/CentralEvent`` fanned in from the children, on
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

    /// ``BLESwiftCore/CentralState/poweredOn`` if any child is powered on, otherwise the
    /// first child's state (``BLESwiftCore/CentralState/unknown`` with no children).
    public var radioState: CentralState {
        computedState
    }

    /// Starts a scan on every child.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.scanForPeripherals(withServices: services, options: options) }
    }

    /// Stops the scan on every child.
    public func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.stopScan() }
    }

    /// Asks every child to connect `peripheral`. Children of a different shim family ignore
    /// it silently, per ``BLESwiftCore/CentralManaging/connect(_:options:requiresANCS:)`` —
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
    /// ``BLESwiftCore/PeripheralRemote/identifier`` — the first backend to vend an
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

    /// Registers on every child (a no-op on the children for which the underlying API does
    /// not exist).
    public func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.registerForConnectionEvents(services: services, peripherals: peripherals) }
    }

    /// Unregisters on every child.
    public func unregisterForConnectionEvents() {
        dispatchPrecondition(condition: .onQueue(queue))
        for backend in backends { backend.unregisterForConnectionEvents() }
    }
}
#endif
