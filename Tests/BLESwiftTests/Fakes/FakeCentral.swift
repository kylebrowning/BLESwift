//
//  FakeCentral.swift
//  BLESwiftTests
//

import CoreBluetooth
import Dispatch
import Synchronization
@testable import BLESwift

/// A scriptable stand-in for `CBCentralManager`, conforming to `CentralManaging`.
///
/// `CBCentralManager` cannot be instantiated or scripted in tests, so `FakeCentral` lets
/// tests drive the shim protocol's call sites (`connect`, `scanForPeripherals`, …) and
/// script the events a real manager would eventually deliver via its delegate, without
/// any hardware or third-party mocking library.
///
/// **Concurrency — queue-confined, not lock-protected.** Every stored property is
/// `nonisolated(unsafe)`, and that is safe only because of an invariant this type
/// enforces structurally, not because the state is otherwise synchronized:
/// - **Every CB-mirroring method (the `CentralManaging` conformance) and every property
///   getter/setter asserts `dispatchPrecondition(condition: .onQueue(queue))` at entry**,
///   then touches state inline. Nothing in this type calls `queue.sync` to protect a
///   read or write — the single serial queue itself *is* the synchronization, exactly as
///   it is for a real `CBCentralManager`, whose delegate is only ever called back on the
///   queue it was created with. Once the eventual `Central` actor exists (Phase 3) and is
///   isolated to this same queue, it will call these methods directly, already on-queue —
///   calling `queue.sync` from in here would be a reentrant deadlock against that actor.
/// - **Event delivery is always `queue.async`, never inline.** This mirrors
///   CoreBluetooth's own asynchronous delegate delivery and means a "simulate" call
///   returns before its event lands; tests that need the event to have landed call
///   ``onQueue(_:)`` (which, being on the same serial queue, only returns once every
///   previously-scheduled `.async` block — including the pending delivery — has run).
/// - **`onQueue(_:)` is the only place `queue.sync` appears in this type**, and is the
///   only sanctioned door for off-queue (test) code to configure or inspect state: it
///   hops onto `queue`, where every precondition-guarded accessor above is legal to call.
///   `static var authorization` is the one exception — it is not scoped to any single
///   fake's queue, so it is backed by a `Mutex` instead (see its doc comment).
final class FakeCentral: CentralManaging, Sendable {

    /// How a scripted call to ``connect(_:options:)`` resolves.
    enum ConnectBehavior: Sendable {
        /// Deliver `CentralEvent.didConnect` on the queue, asynchronously — as CB would.
        case succeed
        /// Deliver `CentralEvent.didFailToConnect` on the queue, asynchronously.
        case fail(NSError)
        /// Never deliver an event, simulating a connection attempt that never completes
        /// (for exercising timeout/cancellation behavior in later phases).
        case hang
    }

    /// The queue every CB-mirroring method and event delivery is confined to.
    let queue: DispatchSerialQueue

    nonisolated(unsafe) private var _state: CBManagerState
    nonisolated(unsafe) private var _eventSink: ((CentralEvent) -> Void)?
    nonisolated(unsafe) private var _connectBehavior: ConnectBehavior = .succeed
    nonisolated(unsafe) private var _connectCallCount = 0
    nonisolated(unsafe) private var _lastConnectOptions: [String: Any]?
    nonisolated(unsafe) private var _cancelCallCount = 0
    nonisolated(unsafe) private var _scanCallCount = 0
    nonisolated(unsafe) private var _stopScanCallCount = 0
    nonisolated(unsafe) private var _retrievablePeripherals: [UUID: FakePeripheral] = [:]

    /// Backs ``authorization``. Unlike every other stored property here, `authorization`
    /// is a `static var` mirroring the `CBManager.authorization` *class* property — it
    /// isn't scoped to one fake instance's queue, so it can't be confined the same way,
    /// and is protected by a `Mutex` instead (per Phase 0's guidance: `Mutex` is
    /// unconditionally usable for tiny non-actor state on our deployment floor).
    private static let authorizationBox = Mutex<CBManagerAuthorization>(.allowedAlways)

    /// The `CBManagerAuthorization` this fake reports. Settable directly — `Mutex`
    /// protects it, so no queue confinement or `onQueue(_:)` hop is needed.
    static var authorization: CBManagerAuthorization {
        get { authorizationBox.withLock { $0 } }
        set { authorizationBox.withLock { $0 = newValue } }
    }

    /// Creates a `FakeCentral` confined to `queue`.
    ///
    /// - Parameters:
    ///   - queue: The queue every CB-mirroring method and event delivery is confined to —
    ///     the same queue the eventual `Central` actor's executor is tied to.
    ///   - state: The initial `CBManagerState`. Defaults to `.unknown`, matching a real
    ///     `CBCentralManager` before its first `centralManagerDidUpdateState(_:)`.
    init(queue: DispatchSerialQueue, state: CBManagerState = .unknown) {
        self.queue = queue
        self._state = state
    }

    /// Runs `body` synchronously on ``queue`` and returns its result — the only
    /// sanctioned way for off-queue (test) code to configure this fake (``eventSink``,
    /// ``connectBehavior``, scripted values) or read its counters/state for assertions.
    /// Because `queue` is serial, this also flushes every previously-scheduled `.async`
    /// event delivery before `body` runs.
    ///
    /// - Warning: Never call this from within an ``eventSink`` callback, or from any other
    ///   code already executing on `queue` — like `CBCentralManager`'s own queue, doing so
    ///   is a reentrant deadlock.
    func onQueue<T>(_ body: () -> T) -> T {
        queue.sync(execute: body)
    }

    /// The current radio state.
    var state: CBManagerState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _state
    }

    /// Receives every ``CentralEvent`` this fake delivers, on ``queue``. Configure via
    /// ``onQueue(_:)``. Not part of the `CentralManaging` shim protocol itself.
    var eventSink: ((CentralEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventSink
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventSink = newValue
        }
    }

    /// Determines how the next call(s) to ``connect(_:options:)`` resolve. Defaults to
    /// `.succeed`. Configure via ``onQueue(_:)``.
    var connectBehavior: ConnectBehavior {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _connectBehavior
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _connectBehavior = newValue
        }
    }

    /// The number of times ``connect(_:options:)`` has been called.
    var connectCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectCallCount
    }

    /// The `options` dictionary passed to the most recent ``connect(_:options:)`` call
    /// (`nil` before any connect, or when the caller passed `nil`). Lets tests assert
    /// that `WarningOptions` plumbing reaches CoreBluetooth's connect options.
    var lastConnectOptions: [String: Any]? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastConnectOptions
    }

    /// The number of times ``cancelPeripheralConnection(_:)`` has been called.
    var cancelCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _cancelCallCount
    }

    /// The number of times ``scanForPeripherals(withServices:options:)`` has been called.
    var scanCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _scanCallCount
    }

    /// The number of times ``stopScan()`` has been called.
    var stopScanCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _stopScanCallCount
    }

    /// Peripherals ``retrievePeripherals(withIdentifiers:)`` should return, keyed by
    /// identifier. Empty (i.e. "nothing cached") by default. Configure via
    /// ``onQueue(_:)``.
    var retrievablePeripherals: [UUID: FakePeripheral] {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _retrievablePeripherals
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _retrievablePeripherals = newValue
        }
    }

    /// Simulates CoreBluetooth updating the radio state and, asynchronously, delivers
    /// ``CentralEvent/didUpdateState(_:)`` on ``queue``. Off-queue safe to call directly —
    /// hops onto `queue` itself. Flush with ``onQueue(_:)`` before asserting the event
    /// landed.
    func simulateStateChange(_ newState: CBManagerState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _state = newState
            deliver(.didUpdateState(newState))
        }
    }

    /// Simulates CoreBluetooth discovering a peripheral during a scan and, asynchronously,
    /// delivers ``CentralEvent/didDiscover(peripheral:advertisement:rssi:)`` on ``queue``.
    func simulateDiscovery(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didDiscover(peripheral: peripheral, advertisement: advertisement, rssi: rssi))
        }
    }

    /// Simulates an unexpected disconnect and, asynchronously, delivers
    /// ``CentralEvent/didDisconnect(_:error:)`` on ``queue``.
    func simulateDisconnect(_ peripheral: PeripheralIdentifier, error: NSError?) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didDisconnect(peripheral, error: error))
        }
    }

    /// Simulates CoreBluetooth restoring preserved state after a background relaunch and,
    /// asynchronously, delivers ``CentralEvent/willRestoreState(_:)`` on ``queue``.
    ///
    /// Call **before** the `.poweredOn` ``simulateStateChange(_:)`` — CoreBluetooth
    /// guarantees `willRestoreState` precedes `centralManagerDidUpdateState` (Phase 0
    /// verified constraint), and `Central`'s routing relies on that ordering. Both
    /// deliveries are `queue.async`, so calling the two simulate methods in that order
    /// preserves it.
    func simulateRestoration(_ state: RestoredState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }

    // MARK: - CentralManaging

    /// Records the call. Does not itself deliver a discovery event — use
    /// ``simulateDiscovery(peripheral:advertisement:rssi:)`` to script sightings.
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        _scanCallCount += 1
    }

    /// Records the call.
    func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        _stopScanCallCount += 1
    }

    /// Records the call and, per ``connectBehavior``, asynchronously delivers
    /// `.didConnect`, `.didFailToConnect`, or nothing (`.hang`) on ``queue`` — mirroring
    /// that a real `connect(_:options:)` call returns immediately while CoreBluetooth
    /// resolves the attempt later, on the delegate. A no-op (beyond the call count) if
    /// `peripheral` is not a `FakePeripheral` — mixing shim families is a programmer
    /// error, never a trap (see ``CentralManaging/connect(_:options:)``).
    func connect(_ peripheral: any PeripheralRemote, options: [String: Any]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectCallCount += 1
        _lastConnectOptions = options

        guard let fakePeripheral = peripheral as? FakePeripheral else { return }

        let behavior = _connectBehavior
        let identifier = fakePeripheral.peripheralIdentifier

        switch behavior {
        case .succeed:
            queue.async { [self] in deliver(.didConnect(identifier)) }
        case .fail(let error):
            queue.async { [self] in deliver(.didFailToConnect(identifier, error: error)) }
        case .hang:
            break
        }
    }

    /// Records the call. A no-op beyond the call count if `peripheral` is not a
    /// `FakePeripheral`.
    func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        _cancelCallCount += 1
    }

    /// Returns the scripted peripherals from ``retrievablePeripherals`` matching
    /// `identifiers`.
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return identifiers.compactMap { _retrievablePeripherals[$0] }
    }

    private func deliver(_ event: CentralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventSink?(event)
    }
}
