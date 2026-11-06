//
//  FakeCentral.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation
import BLESwiftCompat17

/// A scriptable stand-in for `CBCentralManager`. It conforms to `CentralManaging`.
///
/// You cannot instantiate or script `CBCentralManager` in tests. `FakeCentral` lets you drive the
/// shim protocol's call sites and script the events that a real manager delivers with its
/// delegate. It needs no hardware and no mocking library. Construct it with ``init(queue:state:)``.
///
/// **Concurrency: a queue confines it and no lock protects it.** Every stored property is
/// `nonisolated(unsafe)`. This is safe because of a structural invariant:
/// - Every `CentralManaging` method and property accessor asserts `dispatchPrecondition(condition:
///   .onQueue(queue))` at entry and touches state inline. The serial queue is the synchronization,
///   as it is for a real `CBCentralManager`.
/// - Event delivery is always `queue.async`, which mirrors CoreBluetooth's asynchronous delegate
///   delivery. A caller that needs an event to have arrived uses ``onQueue(_:)``.
/// - ``onQueue(_:)`` is the only door for off-queue code to configure or inspect state. The one
///   exception is `static var bluetoothAuthorization`. It belongs to no single fake's queue, so a
///   `Mutex` backs it.
public final class FakeCentral: CentralManaging, Sendable {

    /// How a scripted call to ``connect(_:options:)`` resolves.
    public enum ConnectBehavior: Sendable {
        /// Deliver `CentralEvent.didConnect` on the queue, asynchronously, as CoreBluetooth does.
        case succeed
        /// Deliver `CentralEvent.didFailToConnect` on the queue, asynchronously.
        case fail(NSError)
        /// Never deliver an event, to simulate a connection attempt that never completes. Use it to
        /// test timeout and cancellation.
        case hang
    }

    /// The queue that confines every method and event delivery.
    public let queue: DispatchQueue

    nonisolated(unsafe) private var _radioState: CentralState
    nonisolated(unsafe) private var _eventHandler: ((CentralEvent) -> Void)?
    nonisolated(unsafe) private var _connectBehavior: ConnectBehavior = .succeed
    nonisolated(unsafe) private var _connectBehaviors: [UUID: ConnectBehavior] = [:]
    nonisolated(unsafe) private var _connectCallCount = 0
    nonisolated(unsafe) private var _connectCallCounts: [UUID: Int] = [:]
    nonisolated(unsafe) private var _lastConnectOptions: WarningOptions?
    nonisolated(unsafe) private var _lastConnectRequiresANCS: Bool?
    nonisolated(unsafe) private var _connectionEventRegistrationCount = 0
    nonisolated(unsafe) private var _connectionEventUnregistrationCount = 0
    nonisolated(unsafe) private var _lastConnectionEventServices: [ServiceIdentifier]?
    nonisolated(unsafe) private var _lastConnectionEventPeripherals: [UUID]?
    nonisolated(unsafe) private var _cancelCallCount = 0
    nonisolated(unsafe) private var _cancelCallCounts: [UUID: Int] = [:]
    nonisolated(unsafe) private var _scanCallCount = 0
    nonisolated(unsafe) private var _lastScanOptions: ScanOptions?
    nonisolated(unsafe) private var _lastScanServices: [ServiceIdentifier]??
    nonisolated(unsafe) private var _stopScanCallCount = 0
    nonisolated(unsafe) private var _retrievablePeripherals: [UUID: FakePeripheral] = [:]
    nonisolated(unsafe) private var _systemConnectedPeripherals: [(peripheral: FakePeripheral, services: [ServiceIdentifier])] = []

    /// Backs ``bluetoothAuthorization``. A `static var` (it mirrors `CBManager.authorization`)
    /// belongs to no single fake's queue, so a `Mutex` protects it.
    private static let authorizationBox = Mutex<BluetoothAuthorization>(.allowedAlways)

    /// The `BluetoothAuthorization` that this fake reports. A `Mutex` protects it, so you can set
    /// it directly, with no ``onQueue(_:)`` hop.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        get { authorizationBox.withLock { $0 } }
        set { authorizationBox.withLock { $0 = newValue } }
    }

    /// Creates a `FakeCentral` confined to `queue`.
    ///
    /// - Parameters:
    ///   - queue: The queue that confines every method and event delivery. It must be the queue
    ///     that the `Central` actor's executor uses. It must be serial (`DispatchQueue(label:)`
    ///     makes a serial queue).
    ///   - state: The initial `CentralState`. The default is `.unknown`. A real `CBCentralManager`
    ///     has this state before its first `centralManagerDidUpdateState(_:)`.
    public init(queue: DispatchQueue, state: CentralState = .unknown) {
        self.queue = queue
        self._radioState = state
    }

    /// Runs `body` on ``queue`` and returns its result. Off-queue code must use this to configure
    /// this fake or to read its counters and state. Because `queue` is serial, it also flushes
    /// every `.async` event delivery that is already scheduled.
    ///
    /// It never blocks the calling thread, and deliberately does not use `queue.sync`. Under the
    /// parallel runner of `swift test`, test bodies run on a cooperative thread pool of fixed
    /// width. A blocking `queue.sync` there can park enough threads to deadlock other tests' timing
    /// continuations.
    ///
    /// - Warning: Never `await` this function from an ``eventHandler`` callback or from other code
    ///   that already runs on `queue`. The caller would hold `queue` while it awaits a `body` that
    ///   waits behind it, and that deadlocks.
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

    /// Receives every `CentralEvent` that this fake delivers, on ``queue``. It witnesses the
    /// `CentralManaging` requirement. Configure it with ``onQueue(_:)``.
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

    /// How ``connect(_:options:requiresANCS:)`` resolves for a peripheral that has no entry in
    /// ``connectBehaviors``. The default is `.succeed`. Configure it with ``onQueue(_:)``.
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

    /// Per-peripheral overrides of ``connectBehavior``, keyed by identifier. A test with several
    /// peripherals uses this to script independent connect results, such as one `.succeed` and one
    /// `.hang`. A peripheral with no entry uses ``connectBehavior``. The default is empty.
    /// Configure it with ``onQueue(_:)``.
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

    /// The number of ``connect(_:options:requiresANCS:)`` calls, across every peripheral.
    public var connectCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectCallCount
    }

    /// The number of ``connect(_:options:requiresANCS:)`` calls, keyed by the target peripheral's
    /// identifier. A test with several peripherals uses this to assert each one's connection
    /// attempts. A missing key means zero calls.
    public var connectCallCounts: [UUID: Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectCallCounts
    }

    /// The `options` of the latest ``connect(_:options:requiresANCS:)`` call. It is `nil` before
    /// any connect, or when the caller passed `nil`. Use it to assert that the `WarningOptions`
    /// reach the backend seam.
    public var lastConnectOptions: WarningOptions? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastConnectOptions
    }

    /// The `requiresANCS` flag of the latest ``connect(_:options:requiresANCS:)`` call. It is `nil`
    /// before any connect. Use it to assert that the value reaches the backend seam.
    public var lastConnectRequiresANCS: Bool? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastConnectRequiresANCS
    }

    /// The number of calls to ``registerForConnectionEvents(services:peripherals:)``.
    public var connectionEventRegistrationCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectionEventRegistrationCount
    }

    /// The number of calls to ``unregisterForConnectionEvents()``.
    public var connectionEventUnregistrationCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectionEventUnregistrationCount
    }

    /// The `services` of the latest ``registerForConnectionEvents(services:peripherals:)`` call. It
    /// is `nil` before any call, or when the caller passed `nil`.
    public var lastConnectionEventServices: [ServiceIdentifier]? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastConnectionEventServices
    }

    /// The peripheral UUIDs of the latest ``registerForConnectionEvents(services:peripherals:)``
    /// call. It is `nil` before any call, or when the caller passed `nil`.
    public var lastConnectionEventPeripherals: [UUID]? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastConnectionEventPeripherals
    }

    /// The number of calls to ``cancelPeripheralConnection(_:)``, across every peripheral.
    public var cancelCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _cancelCallCount
    }

    /// The number of ``cancelPeripheralConnection(_:)`` calls, keyed by the target peripheral's
    /// identifier. A missing key means zero calls.
    public var cancelCallCounts: [UUID: Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _cancelCallCounts
    }

    /// The number of calls to ``scanForPeripherals(withServices:options:)``.
    public var scanCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _scanCallCount
    }

    /// The `options` of the latest ``scanForPeripherals(withServices:options:)`` call. It is `nil`
    /// before any scan. Use it to assert `ScanOptions` without dictionary comparisons.
    public var lastScanOptions: ScanOptions? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastScanOptions
    }

    /// The `services` of the latest ``scanForPeripherals(withServices:options:)`` call. The type is
    /// a double optional. The outer `nil` means that no scan has started. The inner `nil` means
    /// that the last scan was unscoped (`services: nil`). Use it to assert that
    /// `ScanFilter.services` reaches the radio seam.
    public var lastScanServices: [ServiceIdentifier]?? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastScanServices
    }

    /// The number of calls to ``stopScan()``.
    public var stopScanCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _stopScanCallCount
    }

    /// The peripherals that ``retrievePeripherals(withIdentifiers:)`` returns, keyed by identifier.
    /// The default is empty (nothing cached). Configure it with ``onQueue(_:)``.
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

    /// The peripherals that ``retrieveConnectedPeripherals(withServices:)`` filters, each with the
    /// services that the fake treats it as containing. The default is empty. Configure it with
    /// ``onQueue(_:)``.
    ///
    /// This is separate from `FakePeripheral.availableServices` on purpose. There, `nil` means
    /// permissive auto-discovery, which has no meaning as a filter for connected services.
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

    /// Simulates a radio state update. It then delivers `CentralEvent.didUpdateState(_:)`
    /// asynchronously on ``queue``. You can call it off the queue, because it hops onto `queue`
    /// itself. Flush with ``onQueue(_:)`` before you assert that the event arrived.
    public func simulateStateChange(_ newState: CentralState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _radioState = newState
            deliver(.didUpdateState(newState))
        }
    }

    /// Simulates a peripheral discovery during a scan. It then delivers
    /// `CentralEvent.didDiscover(peripheral:advertisement:rssi:)` asynchronously on ``queue``.
    public func simulateDiscovery(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didDiscover(peripheral: peripheral, advertisement: advertisement, rssi: rssi))
        }
    }

    /// Simulates an unexpected disconnect. It then delivers `CentralEvent.didDisconnect(_:error:)`
    /// asynchronously on ``queue``.
    public func simulateDisconnect(_ peripheral: PeripheralIdentifier, error: NSError?) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didDisconnect(peripheral, error: error))
        }
    }

    /// Simulates a system-level connection event for `peripheral`. It then delivers
    /// `CentralEvent.connectionEventDidOccur(peripheral:event:)` asynchronously on ``queue``.
    public func simulateConnectionEvent(_ kind: SystemConnectionEvent.Kind, for peripheral: PeripheralIdentifier) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.connectionEventDidOccur(peripheral: peripheral.uuid, event: kind))
        }
    }

    /// Simulates an ANCS authorization change for `peripheral`. It then delivers
    /// `CentralEvent.didUpdateANCSAuthorization(peripheral:authorized:)` asynchronously on
    /// ``queue``. Also set `FakePeripheral.ancsAuthorized`, because a real `CBPeripheral` shows the
    /// new value when the callback arrives.
    public func simulateANCSAuthorization(_ authorized: Bool, for peripheral: PeripheralIdentifier) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didUpdateANCSAuthorization(peripheral: peripheral.uuid, authorized: authorized))
        }
    }

    #if os(iOS)
    /// Simulates CoreBluetooth restoring preserved state after a background relaunch. It then
    /// delivers `CentralEvent.willRestoreState(_:)` asynchronously on ``queue``.
    ///
    /// Call it **before** the `.poweredOn` ``simulateStateChange(_:)``. CoreBluetooth guarantees
    /// that `willRestoreState` comes before `centralManagerDidUpdateState`, and `Central`'s routing
    /// relies on that order. Both deliveries use `queue.async`, so calling the two simulate
    /// methods in that order keeps the order.
    public func simulateRestoration(_ state: RestoredState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }
    #else
    /// A `package` mirror of the public `simulateRestoration(_:)`, which exists on iOS only. See
    /// the dual-access note on `RestoredState` (`BLESwiftCore`). **Keep the two in sync.**
    package func simulateRestoration(_ state: RestoredState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }
    #endif

    // MARK: - CentralManaging

    /// Records the call. It does not deliver a discovery event. To script sightings, use
    /// ``simulateDiscovery(peripheral:advertisement:rssi:)``.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        dispatchPrecondition(condition: .onQueue(queue))
        _scanCallCount += 1
        _lastScanOptions = options
        _lastScanServices = services
    }

    /// Records the call.
    public func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        _stopScanCallCount += 1
    }

    /// Records the call. It then delivers `.didConnect` or `.didFailToConnect` asynchronously on
    /// ``queue``, as ``connectBehaviors`` defines (``connectBehavior`` if there is no entry). For
    /// `.hang`, it delivers nothing. If `peripheral` is not a `FakePeripheral`, the function only
    /// counts the call and does not trap.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectCallCount += 1
        _lastConnectOptions = options
        _lastConnectRequiresANCS = requiresANCS

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

    /// Records the call and counts it for the peripheral in ``cancelCallCounts``. If `peripheral`
    /// is not a `FakePeripheral`, the function only adds to the total ``cancelCallCount``.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        _cancelCallCount += 1
        if let fakePeripheral = peripheral as? FakePeripheral {
            _cancelCallCounts[fakePeripheral.identifier, default: 0] += 1
        }
    }

    /// Returns the scripted peripherals from ``retrievablePeripherals`` that match `identifiers`.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return identifiers.compactMap { _retrievablePeripherals[$0] }
    }

    /// Returns the scripted peripherals (``systemConnectedPeripherals``) that have a service in
    /// `services` (any of them, as CoreBluetooth does). The order follows the scripted array.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        let query = Set(services)
        return _systemConnectedPeripherals
            .filter { !query.isDisjoint(with: $0.services) }
            .map(\.peripheral)
    }

    /// Records the call and its match options. It does not deliver events. To script events, use
    /// ``simulateConnectionEvent(_:for:)``.
    public func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionEventRegistrationCount += 1
        _lastConnectionEventServices = services
        _lastConnectionEventPeripherals = peripherals
    }

    /// Records the call.
    public func unregisterForConnectionEvents() {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionEventUnregistrationCount += 1
    }

    private func deliver(_ event: CentralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventHandler?(event)
    }
}
