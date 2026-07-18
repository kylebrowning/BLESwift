//
//  FakeCentral.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation
import Synchronization

/// A scriptable stand-in for `CBCentralManager`, conforming to `CentralManaging`.
///
/// `CBCentralManager` cannot be instantiated or scripted in tests, so `FakeCentral` lets
/// you drive the shim protocol's call sites (`connect`, `scanForPeripherals`, …) and script
/// the events a real manager would eventually deliver via its delegate, without any
/// hardware or third-party mocking library. Construct one with ``init(queue:state:)`` and
/// pass it to `Central.init(backend:queue:configuration:startupBackgroundTask:connectedPeripheral:)`.
///
/// **Concurrency — queue-confined, not lock-protected.** Every stored property is
/// `nonisolated(unsafe)`, and that is safe only because of an invariant this type
/// enforces structurally, not because the state is otherwise synchronized:
/// - **Every CB-mirroring method (the `CentralManaging` conformance) and every property
///   getter/setter asserts `dispatchPrecondition(condition: .onQueue(queue))` at entry**,
///   then touches state inline. Nothing in this type calls `queue.sync` to protect a
///   read or write — the single serial queue itself *is* the synchronization, exactly as
///   it is for a real `CBCentralManager`, whose delegate is only ever called back on the
///   queue it was created with. The `Central` actor, isolated to this same queue, calls
///   these methods directly, already on-queue.
/// - **Event delivery is always `queue.async`, never inline.** This mirrors
///   CoreBluetooth's own asynchronous delegate delivery and means a "simulate" call
///   returns before its event lands; callers that need the event to have landed call
///   ``onQueue(_:)`` (which, being on the same serial queue, only returns once every
///   previously-scheduled `.async` block — including the pending delivery — has run).
/// - **`onQueue(_:)` is the only sanctioned door for off-queue code to configure or
///   inspect state**: it hops onto `queue` (asynchronously — `queue.async` + an awaited
///   continuation, never a thread-parking `queue.sync`; see its own docs and issue #13),
///   where every precondition-guarded accessor above is legal to call.
///   `static var bluetoothAuthorization` is the one exception — it is not scoped to any
///   single fake's queue, so it is backed by a `Mutex` instead (see its doc comment).
public final class FakeCentral: CentralManaging, Sendable {

    /// How a scripted call to ``connect(_:options:)`` resolves.
    public enum ConnectBehavior: Sendable {
        /// Deliver `CentralEvent.didConnect` on the queue, asynchronously — as CB would.
        case succeed
        /// Deliver `CentralEvent.didFailToConnect` on the queue, asynchronously.
        case fail(NSError)
        /// Never deliver an event, simulating a connection attempt that never completes
        /// (for exercising timeout/cancellation behavior).
        case hang
    }

    /// The queue every CB-mirroring method and event delivery is confined to.
    public let queue: DispatchSerialQueue

    nonisolated(unsafe) private var _radioState: CentralState
    nonisolated(unsafe) private var _eventHandler: ((CentralEvent) -> Void)?
    nonisolated(unsafe) private var _connectBehavior: ConnectBehavior = .succeed
    nonisolated(unsafe) private var _connectBehaviors: [UUID: ConnectBehavior] = [:]
    nonisolated(unsafe) private var _connectCallCount = 0
    nonisolated(unsafe) private var _connectCallCounts: [UUID: Int] = [:]
    nonisolated(unsafe) private var _lastConnectOptions: WarningOptions?
    nonisolated(unsafe) private var _cancelCallCount = 0
    nonisolated(unsafe) private var _cancelCallCounts: [UUID: Int] = [:]
    nonisolated(unsafe) private var _scanCallCount = 0
    nonisolated(unsafe) private var _lastScanOptions: ScanOptions?
    nonisolated(unsafe) private var _stopScanCallCount = 0
    nonisolated(unsafe) private var _retrievablePeripherals: [UUID: FakePeripheral] = [:]
    nonisolated(unsafe) private var _systemConnectedPeripherals: [(peripheral: FakePeripheral, services: [ServiceIdentifier])] = []

    /// Backs ``bluetoothAuthorization``. Unlike every other stored property here,
    /// `bluetoothAuthorization` is a `static var` mirroring the `CBManager.authorization`
    /// *class* property — it isn't scoped to one fake instance's queue, so it can't be
    /// confined the same way, and is protected by a `Mutex` instead.
    private static let authorizationBox = Mutex<BluetoothAuthorization>(.allowedAlways)

    /// The `BluetoothAuthorization` this fake reports. Settable directly — `Mutex`
    /// protects it, so no queue confinement or `onQueue(_:)` hop is needed.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        get { authorizationBox.withLock { $0 } }
        set { authorizationBox.withLock { $0 = newValue } }
    }

    /// Creates a `FakeCentral` confined to `queue`.
    ///
    /// - Parameters:
    ///   - queue: The queue every CB-mirroring method and event delivery is confined to —
    ///     the same queue the `Central` actor's executor must be tied to.
    ///   - state: The initial `CentralState`. Defaults to `.unknown`, matching a real
    ///     `CBCentralManager` before its first `centralManagerDidUpdateState(_:)`.
    public init(queue: DispatchSerialQueue, state: CentralState = .unknown) {
        self.queue = queue
        self._radioState = state
    }

    /// Hops onto ``queue`` (via `queue.async` + a continuation) to run `body`, then returns
    /// its result — the only sanctioned way for off-queue code to configure this fake
    /// (``eventHandler``, ``connectBehavior``, scripted values) or read its counters/state
    /// for assertions. Because `queue` is serial, this also flushes every previously-
    /// scheduled `.async` event delivery before `body` runs.
    ///
    /// This is `async` and **never blocks the calling thread** — it does *not* use
    /// `queue.sync`. That matters under `swift test`'s parallel runner: test bodies execute
    /// on Swift's fixed-width cooperative thread pool, and a blocking `queue.sync` there
    /// would park a cooperative thread, so enough concurrent callers could exhaust the pool
    /// and deadlock every timing test's `Task.sleep`/`withTimeout` continuation (issue #13).
    /// Awaiting a continuation instead keeps the thread free while the hop is pending.
    ///
    /// - Warning: Never `await` this from within an ``eventHandler`` callback, or from any
    ///   other code already executing on `queue` — like `CBCentralManager`'s own queue: the
    ///   caller holds `queue` while awaiting a `body` enqueued *behind* itself, a deadlock.
    public func onQueue<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// The current radio state.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _radioState
    }

    /// Receives every `CentralEvent` this fake delivers, on ``queue``. The
    /// `CentralManaging` protocol witness — configure via ``onQueue(_:)``.
    public var eventHandler: ((CentralEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
        }
    }

    /// Determines how the next call(s) to ``connect(_:options:)`` resolve, for a peripheral
    /// with no entry in ``connectBehaviors``. Defaults to `.succeed`. Configure via
    /// ``onQueue(_:)``.
    public var connectBehavior: ConnectBehavior {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _connectBehavior
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _connectBehavior = newValue
        }
    }

    /// Per-peripheral overrides of ``connectBehavior``, keyed by identifier — lets a
    /// multi-peripheral test script independent outcomes for `connect(_:options:)` calls
    /// against different fakes (e.g. one `.succeed`, one `.hang`). A peripheral with no
    /// entry here falls back to ``connectBehavior``. Empty by default. Configure via
    /// ``onQueue(_:)``.
    public var connectBehaviors: [UUID: ConnectBehavior] {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _connectBehaviors
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _connectBehaviors = newValue
        }
    }

    /// The number of times ``connect(_:options:)`` has been called, across every
    /// peripheral.
    public var connectCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectCallCount
    }

    /// The number of times ``connect(_:options:)`` has been called, keyed by the target
    /// peripheral's identifier — lets a multi-peripheral test assert connection attempts
    /// per peripheral independently. Missing keys mean zero calls for that identifier.
    public var connectCallCounts: [UUID: Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectCallCounts
    }

    /// The `options` passed to the most recent ``connect(_:options:)`` call (`nil` before
    /// any connect, or when the caller passed `nil`). Lets you assert that `WarningOptions`
    /// plumbing reaches the backend seam.
    public var lastConnectOptions: WarningOptions? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastConnectOptions
    }

    /// The number of times ``cancelPeripheralConnection(_:)`` has been called, across every
    /// peripheral.
    public var cancelCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _cancelCallCount
    }

    /// The number of times ``cancelPeripheralConnection(_:)`` has been called, keyed by the
    /// target peripheral's identifier. Missing keys mean zero calls for that identifier.
    public var cancelCallCounts: [UUID: Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _cancelCallCounts
    }

    /// The number of times ``scanForPeripherals(withServices:options:)`` has been called.
    public var scanCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _scanCallCount
    }

    /// The `options` passed to the most recent ``scanForPeripherals(withServices:options:)``
    /// call (`nil` before any scan). Lets you assert `ScanOptions` plumbing without
    /// dictionary assertions.
    public var lastScanOptions: ScanOptions? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastScanOptions
    }

    /// The number of times ``stopScan()`` has been called.
    public var stopScanCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _stopScanCallCount
    }

    /// Peripherals ``retrievePeripherals(withIdentifiers:)`` should return, keyed by
    /// identifier. Empty (i.e. "nothing cached") by default. Configure via
    /// ``onQueue(_:)``.
    public var retrievablePeripherals: [UUID: FakePeripheral] {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _retrievablePeripherals
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _retrievablePeripherals = newValue
        }
    }

    /// Peripherals ``retrieveConnectedPeripherals(withServices:)`` filters over, each
    /// paired with the services it should be treated as containing. Empty (i.e. "nothing
    /// system-connected") by default. Configure via ``onQueue(_:)``.
    ///
    /// Deliberately separate from `FakePeripheral.availableServices` (the discovery-
    /// scripting seam): `availableServices == nil` there means "permissive
    /// auto-discovery", which has no sensible meaning as a connected-services filter — the
    /// two concepts must not be conflated.
    public var systemConnectedPeripherals: [(peripheral: FakePeripheral, services: [ServiceIdentifier])] {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _systemConnectedPeripherals
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _systemConnectedPeripherals = newValue
        }
    }

    /// Simulates CoreBluetooth updating the radio state and, asynchronously, delivers
    /// `CentralEvent.didUpdateState(_:)` on ``queue``. Off-queue safe to call directly —
    /// hops onto `queue` itself. Flush with ``onQueue(_:)`` before asserting the event
    /// landed.
    public func simulateStateChange(_ newState: CentralState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _radioState = newState
            deliver(.didUpdateState(newState))
        }
    }

    /// Simulates CoreBluetooth discovering a peripheral during a scan and, asynchronously,
    /// delivers `CentralEvent.didDiscover(peripheral:advertisement:rssi:)` on ``queue``.
    public func simulateDiscovery(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didDiscover(peripheral: peripheral, advertisement: advertisement, rssi: rssi))
        }
    }

    /// Simulates an unexpected disconnect and, asynchronously, delivers
    /// `CentralEvent.didDisconnect(_:error:)` on ``queue``.
    public func simulateDisconnect(_ peripheral: PeripheralIdentifier, error: NSError?) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didDisconnect(peripheral, error: error))
        }
    }

    #if os(iOS)
    /// Simulates CoreBluetooth restoring preserved state after a background relaunch and,
    /// asynchronously, delivers `CentralEvent.willRestoreState(_:)` on ``queue``.
    ///
    /// Call **before** the `.poweredOn` ``simulateStateChange(_:)`` — CoreBluetooth
    /// guarantees `willRestoreState` precedes `centralManagerDidUpdateState`, and
    /// `Central`'s routing relies on that ordering. Both deliveries are `queue.async`, so
    /// calling the two simulate methods in that order preserves it.
    public func simulateRestoration(_ state: RestoredState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }
    #else
    /// `package` mirror of the iOS-only public `simulateRestoration(_:)` — see the
    /// dual-access note on `RestoredState` (`BLESwiftCore`). **Keep the two in sync.**
    package func simulateRestoration(_ state: RestoredState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }
    #endif

    // MARK: - CentralManaging

    /// Records the call. Does not itself deliver a discovery event — use
    /// ``simulateDiscovery(peripheral:advertisement:rssi:)`` to script sightings.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        dispatchPrecondition(condition: .onQueue(queue))
        _scanCallCount += 1
        _lastScanOptions = options
    }

    /// Records the call.
    public func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        _stopScanCallCount += 1
    }

    /// Records the call and, per ``connectBehaviors`` (falling back to ``connectBehavior``
    /// if `peripheral`'s identifier has no entry there), asynchronously delivers
    /// `.didConnect`, `.didFailToConnect`, or nothing (`.hang`) on ``queue`` — mirroring
    /// that a real `connect(_:options:)` call returns immediately while CoreBluetooth
    /// resolves the attempt later, on the delegate. A no-op (beyond the call count) if
    /// `peripheral` is not a `FakePeripheral` — mixing shim families is a programmer
    /// error, never a trap (see `CentralManaging.connect(_:options:)`).
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectCallCount += 1
        _lastConnectOptions = options

        guard let fakePeripheral = peripheral as? FakePeripheral else { return }

        let identifier = fakePeripheral.peripheralIdentifier
        _connectCallCounts[identifier.uuid, default: 0] += 1
        let behavior = _connectBehaviors[identifier.uuid] ?? _connectBehavior

        switch behavior {
        case .succeed:
            queue.async { [self] in deliver(.didConnect(identifier)) }
        case .fail(let error):
            queue.async { [self] in deliver(.didFailToConnect(identifier, error: error)) }
        case .hang:
            break
        }
    }

    /// Records the call, including a per-peripheral count in ``cancelCallCounts`` (a no-op
    /// beyond the total ``cancelCallCount`` if `peripheral` is not a `FakePeripheral`).
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        _cancelCallCount += 1
        if let fakePeripheral = peripheral as? FakePeripheral {
            _cancelCallCounts[fakePeripheral.identifier, default: 0] += 1
        }
    }

    /// Returns the scripted peripherals from ``retrievablePeripherals`` matching
    /// `identifiers`.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return identifiers.compactMap { _retrievablePeripherals[$0] }
    }

    /// Returns the scripted peripherals (``systemConnectedPeripherals``) whose services
    /// intersect `services` (any-of, mirroring CoreBluetooth). Order follows the scripted
    /// array.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        let query = Set(services)
        return _systemConnectedPeripherals
            .filter { !query.isDisjoint(with: $0.services) }
            .map(\.peripheral)
    }

    private func deliver(_ event: CentralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventHandler?(event)
    }
}
