//
//  Central.swift
//  BLESwift
//

// `@preconcurrency`: The CoreBluetooth types are not `Sendable`. Never mark them as
// unchecked-`Sendable`. `stopAndExtractState()` returns a `CBCentralManager` across this
// actor's isolation boundary, as a one-time transfer of ownership. It type-checks only under
// `@preconcurrency`. Otherwise, the compiler rejects an actor-isolated method that returns a
// non-Sendable type.
import BLESwiftCore
@preconcurrency import CoreBluetooth
import Dispatch
import Foundation
import Logging
import BLESwiftCompat16
import BLESwiftCompat17
#if os(iOS)
import UIKit
#endif

/// The entry point of BLESwift: an actor that wraps one `CBCentralManager`.
///
/// `Central`'s isolation is tied to the `DispatchQueue` on which its `CBCentralManager`
/// delivers delegate callbacks (see ``unownedExecutor``). Each `CentralDelegateProxy` callback
/// already runs on `Central`'s executor and enters actor-isolated code through
/// `assumeIsolated` with no thread hop.
public actor Central {

    /// The serial `DispatchQueue` that backs ``unownedExecutor`` and the CoreBluetooth delegate
    /// callbacks. It must be serial (`DispatchQueue(label:)` is). On the 17 tier, a concurrent
    /// queue is rejected. Below it, the behavior is undefined.
    nonisolated let queue: DispatchQueue

    /// Binds the actor to ``queue``. On the 17 tier and later, it uses `DispatchSerialQueue`'s
    /// executor. Below it, it uses `BLESwiftCompat16.SerialQueueExecutor`.
    nonisolated let executor: QueueExecutor

    /// Ties this actor's isolation to ``queue`` (SE-0424 custom executors). It is public only
    /// because the `Actor` protocol requires it. Do not use it directly.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// The CoreBluetooth shim that this `Central` drives: a real `CBCentralManager`, or a
    /// `FakeCentral` in tests. It is an optional `var`, because ``stopAndExtractState()`` sets
    /// it to `nil` to hand its non-`Sendable` `CBCentralManager` across the isolation boundary.
    /// This is safe only if `Central` gives up its own reference in the same call.
    private var manager: (any CentralManaging)?

    /// Read-only access to ``manager`` for `Central` extensions in other files of this module.
    internal var shim: (any CentralManaging)? { manager }

    /// This `Central`'s `CBCentralManagerDelegate`, held strongly so that it stays alive from
    /// its creation to `CBCentralManager(delegate:queue:options:)`. `willRestoreState` can
    /// arrive before this `Central` installs its handler. It is non-`nil` only for
    /// ``init(configuration:)``. Every other init path delivers events through `eventHandler`.
    private let proxy: CentralDelegateProxy?

    private let configuration: Configuration

    /// Backs the nonisolated ``state`` snapshot. It uses a `Mutex` and not actor-isolated
    /// storage, so any isolation domain can read ``state`` without `await`. Only the
    /// actor-isolated ``handle(_:)`` writes it.
    private let stateBox = Mutex<CentralState>(.unknown)

    /// Sends every ``CentralState`` transition to every ``stateEvents()`` subscriber and
    /// replays the latest value to late subscribers.
    private let stateBroadcaster = Broadcaster<CentralState>(replay: .latest)

    /// The scan in progress, or `nil`. Only one scan can run at a time, because CoreBluetooth
    /// has one physical scanner.
    private var activeScan: ActiveScan?

    /// Backs the nonisolated ``isScanning`` snapshot, for the reason given at ``stateBox``.
    private let isScanningBox = Mutex<Bool>(false)

    /// The connection state machine of each peripheral, by ``PeripheralIdentifier``. No entry
    /// means that the peripheral is idle, because ``PeripheralPhase`` has no `.idle` case. An
    /// entry exists only while the peripheral connects, is connected, or disconnects.
    private var connections: [PeripheralIdentifier: PeripheralPhase] = [:]

    /// One independent auto-reconnect loop for each peripheral. A loop runs while the peripheral
    /// has no ``connections`` entry (during backoff). It is a ledgered unstructured `Task` site.
    /// These events cancel the loop:
    /// - An explicit disconnect of that peripheral.
    /// - A new `connect`.
    /// - `cancelAllOperations` or `disconnectAll()`.
    /// - `deinit`.
    private var reconnectLoops: [PeripheralIdentifier: ReconnectLoop] = [:]

    /// Notification subscriptions that survive an unexpected disconnect, by peripheral. They
    /// wait here until an auto-reconnect succeeds. See:
    /// - ``finishNotificationStreams(for:error:retainSurvivors:)`` (entry).
    /// - ``rearmDormantNotifications(_:)`` (exit through a reconnect).
    /// - ``finishDormantNotifications(for:error:)`` (exit without a reconnect).
    private var dormantNotifications: [PeripheralIdentifier: DormantNotifications] = [:]

    /// The (peripheral, characteristic, operation) triples for which a ``GATTCompatibility``
    /// bypass already logged a warning. A bypass that skips a check that would have failed logs
    /// at `.warning` once for each triple. Compliant hardware stays silent.
    private var warnedCompatBypass: Set<CompatWarnKey> = []

    /// Actor-wide increasing generation counter. It increments when
    /// ``scheduleReconnect(identifier:policy:timeout:warningOptions:compatibility:)`` starts a
    /// loop. Each ``ReconnectLoop`` stores its generation. See
    /// ``clearReconnectLoopIfCurrent(id:generation:)``.
    private var reconnectGeneration: UInt64 = 0

    /// Sends every ``ConnectionEvent`` to all subscribers, with `.none` replay. Unlike
    /// ``stateBroadcaster``, there is no single current value to replay.
    /// ``connectionState(of:)`` and ``connectedPeripherals`` give the snapshot.
    private let connectionBroadcaster = Broadcaster<ConnectionEvent>(replay: .none)

    /// Registry of `didModifyServices` broadcasters, one for each ``PeripheralIdentifier``, for
    /// ``Peripheral/serviceChanges()``. The invalidations of one peripheral never reach the
    /// subscribers of another.
    ///
    /// It is `nonisolated`, so ``Peripheral/serviceChanges()`` can get its `AsyncStream`
    /// synchronously. ``ServiceChangesRegistry`` is `Sendable` and a `Mutex` guards it.
    nonisolated let serviceChangesRegistry = ServiceChangesRegistry()

    #if os(iOS)
    /// ANCS-authorization broadcasters, one for each peripheral, for
    /// ``Peripheral/ancsAuthorizationEvents()``. They follow the same rules as
    /// ``serviceChangesRegistry``: keyed by identifier, never removed, and the streams survive
    /// a disconnect and a reconnect.
    nonisolated let ancsAuthorizationRegistry = ANCSAuthorizationRegistry()
    #endif

    #if !os(macOS)
    /// Live subscribers of ``connectionEventRegistration(services:peripherals:)``, by an
    /// increasing token. It has two uses:
    /// - It is the multicast fan-out target for `CentralEvent.connectionEventDidOccur`.
    /// - Its count drives the backend: register on 0→1 and unregister on 1→0.
    private var connectionEventSubscribers: [UInt64: AsyncStream<SystemConnectionEvent>.Continuation] = [:]

    /// The next token for ``connectionEventSubscribers``.
    private var nextConnectionEventToken: UInt64 = 0
    #endif

    // MARK: - Background restoration state

    /// Sends every ``RestorationEvent`` to all subscribers, with `.allUntilFirstConsumer`
    /// replay. Restoration happens at launch, usually before any consumer subscribes, so the
    /// broadcaster buffers every event and replays them in order to the first
    /// ``restorationEvents()`` consumer.
    private let restorationBroadcaster = Broadcaster<RestorationEvent>(replay: .allUntilFirstConsumer)

    /// The restored state that `CentralEvent.willRestoreState` captured. It is held until the
    /// radio's first `.poweredOn` routes it (``routeRestoredPeripherals(_:)``).
    private var pendingRestoration: RestoredState?

    /// The manual reconnect of each peripheral that was restored in the connecting state,
    /// because CoreBluetooth does not complete such an attempt on its own. It is a ledgered
    /// `Task` site like ``reconnectLoops``. Each entry removes itself when it completes.
    private var restorationTasks: [PeripheralIdentifier: Task<Void, Never>] = [:]

    /// The startup background-task seam that protects the restoration window. On iOS with
    /// restoration enabled, it is a real `UIApplication` background task. Otherwise, it does
    /// nothing.
    private let startupBackgroundTask: any StartupBackgroundTaskRunning

    /// Whether the startup restoration window is open. It makes
    /// ``endStartupBackgroundTask()`` idempotent. It is always `false` when restoration is
    /// disabled.
    private var startupWindowOpen = false

    /// Creates a `Central` and its underlying `CBCentralManager` synchronously, on a new
    /// dedicated `DispatchQueue`. The creation is not deferred behind an async `start()`, so
    /// the `Central` does not miss background restoration events that arrive before an async
    /// step can run.
    ///
    /// - Parameter configuration: Start-time options. The default is `Configuration()`. On
    ///   iOS, if `configuration.restoration` is not `nil`, the `Central` registers its
    ///   identifier with CoreBluetooth at manager creation and opens the startup restoration
    ///   window.
    public init(configuration: Configuration = Configuration()) {
        let queue = DispatchQueue(label: "com.bleswift.Central")
        self.queue = queue
        self.executor = QueueExecutor(queue: queue)
        self.configuration = configuration

        // A registered backend (see `BackendRegistry`) replaces CoreBluetooth completely.
        // Restoration is specific to CoreBluetooth, so the startup window never opens here.
        if let factory = BackendRegistry.centralFactory {
            let backend = factory(queue)
            self.manager = backend
            self.proxy = nil
            self.startupBackgroundTask = NoOpStartupBackgroundTask()
            self.startupWindowOpen = false
            // Hop onto `queue`, because the backend's `eventHandler` setter can be
            // queue-confined. `[weak self]` avoids a retain cycle, as in the CoreBluetooth path.
            queue.sync {
                backend.eventHandler = { [weak self] event in
                    guard let self else { return }
                    self.assumeIsolated(onQueue: self.queue) { $0.handle(event) }
                }
            }
            return
        }

        let proxy = CentralDelegateProxy()
        self.proxy = proxy

        #if os(iOS)
        var options: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: configuration.showPowerAlert
        ]
        if let restoration = configuration.restoration {
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoration.identifier
        }
        let startupBackgroundTask: any StartupBackgroundTaskRunning =
            configuration.restoration == nil ? NoOpStartupBackgroundTask() : UIKitStartupBackgroundTask()
        #else
        let options: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: configuration.showPowerAlert
        ]
        let startupBackgroundTask: any StartupBackgroundTaskRunning = NoOpStartupBackgroundTask()
        #endif

        self.startupBackgroundTask = startupBackgroundTask
        self.startupWindowOpen = configuration.restoration != nil

        self.manager = CBCentralManager(delegate: proxy, queue: queue, options: options)

        // `self` is fully initialized, so the closure can capture it now. Set `proxy.handler`
        // directly (see the doc comment of `proxy`) and not `manager.eventHandler`.
        proxy.handler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated(onQueue: self.queue) { $0.handle(event) }
        }

        // Open the startup background-time window. A no-op runner does nothing off-iOS or
        // without restoration. This call comes after the manager creation, because an escaping
        // closure cannot capture `self` until every stored property is initialized.
        if configuration.restoration != nil {
            startupBackgroundTask.begin { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.handleStartupBackgroundTaskExpiration()
                    }
                }
            }
        }
    }

    /// Creates a `Central` that adopts an existing `CBCentralManager` and, optionally, already
    /// connected `CBPeripheral` objects. It is the counterpart to ``stopAndExtractState()``.
    ///
    /// - Important: `callbackQueue` **must be the exact `DispatchQueue` instance** that created
    ///   `manager`. `CBCentralManager` cannot report its callback queue, so a mismatch is not
    ///   detectable at init. It shows as an `assumeIsolated` trap on the first callback from
    ///   another queue. If `manager` was created with `queue: nil`, pass `DispatchQueue.main`.
    ///
    /// - Parameters:
    ///   - manager: The existing `CBCentralManager` to adopt. It replaces the current delegate.
    ///   - connectedPeripherals: Every `CBPeripheral` that is already connected, if any. Each
    ///     is adopted as a live session with ``ReconnectPolicy/never``. The default is `[]`.
    ///   - callbackQueue: The exact serial `DispatchQueue` on which `manager` delivers
    ///     callbacks.
    ///   - configuration: Start-time options. `showPowerAlert` has no effect, because `manager`
    ///     already exists. The default is `Configuration()`.
    public init(
        adopting manager: CBCentralManager,
        connectedPeripherals: [CBPeripheral] = [],
        callbackQueue: DispatchQueue,
        configuration: Configuration = Configuration()
    ) {
        self.queue = callbackQueue
        self.executor = QueueExecutor(queue: callbackQueue)
        self.configuration = configuration

        // Restoration cannot apply: a restore identifier must be supplied when the manager is
        // *created*, and this manager already exists.
        self.startupBackgroundTask = NoOpStartupBackgroundTask()

        // `manager` already exists, so events use `eventHandler` and not a stored `proxy`.
        self.proxy = nil
        self.manager = manager

        // Set the synchronous `state` snapshot from the adopted manager's current state. The
        // manager can already be past `centralManagerDidUpdateState(_:)`, which does not fire
        // again to correct a stale `.unknown`.
        let adoptedState = CentralState(manager.state)
        stateBox.withLock { $0 = adoptedState }
        stateBroadcaster.yield(adoptedState)

        // Adopt each `connectedPeripherals` entry as a live session (`.never` policy). Every
        // direct write to a stored property must come before the `eventHandler` closures below,
        // because a closure that captures `self` (even weakly) makes `self` escape (SE-0327).
        // After that, direct mutation is not allowed.
        var adopted: [(identifier: PeripheralIdentifier, peripheral: CBPeripheral)] = []
        for connectedPeripheral in connectedPeripherals {
            let identifier = PeripheralIdentifier(uuid: connectedPeripheral.identifier, name: connectedPeripheral.name)
            adopted.append((identifier, connectedPeripheral))
            connections[identifier] = .connected(Session.adopted(
                identifier: identifier,
                peripheral: connectedPeripheral,
                warningOptions: configuration.warningOptions
            ))
            connectionBroadcaster.yield(.connected(identifier))
        }

        // `self` is fully initialized, so a closure can capture it now. Set up event delivery
        // last, after every session exists.
        manager.eventHandler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated(onQueue: self.queue) { $0.handle(event) }
        }
        for (identifier, connectedPeripheral) in adopted {
            connectedPeripheral.eventHandler = { [weak self] event in
                guard let self else { return }
                self.assumeIsolated(onQueue: self.queue) { $0.handle(event, from: identifier) }
            }
        }
    }

    /// Creates a `Central` that drives a custom backend, such as `FakeCentral` of
    /// `BLESwiftTestSupport` or any other `CentralManaging` conformance, instead of a real
    /// `CBCentralManager`. Production code uses ``init(configuration:)`` or
    /// ``init(adopting:connectedPeripherals:callbackQueue:configuration:)``.
    ///
    /// - Important: `queue` **must be the exact `DispatchQueue` instance** that `backend` uses
    ///   for its event deliveries. A mismatch is not detectable at init. It shows as an
    ///   `assumeIsolated` trap on the first event from another queue.
    ///
    /// - Important: **Retention.** Unlike the production initializers, this initializer
    ///   installs closures on `backend.eventHandler` (and on each adopted peripheral's
    ///   handler) that capture `self` **strongly**, and this `Central` holds `backend`. The
    ///   cycle `Central` → `backend` → closure → `Central` is by design, so `backend` alone
    ///   keeps this `Central` alive. ``stopAndExtractState()`` does not break it, because it
    ///   recognizes only a real `CBCentralManager`. To release the `Central` at a known time,
    ///   set `backend.eventHandler = nil` (and the same for each adopted peripheral).
    ///
    /// - Parameters:
    ///   - backend: The `CentralManaging` conformance to drive.
    ///   - queue: The serial `DispatchQueue` that confines `backend`'s events.
    ///   - configuration: Start-time options. The default is `Configuration()`.
    ///   - startupBackgroundTask: An injected startup background-task seam. The default `nil`
    ///     uses a no-op.
    ///   - connectedPeripherals: The `PeripheralRemote` values to adopt as live sessions, as in
    ///     ``init(adopting:connectedPeripherals:callbackQueue:configuration:)``. The default
    ///     is `[]`.
    public init(
        backend: any CentralManaging,
        queue: DispatchQueue,
        configuration: Configuration = Configuration(),
        startupBackgroundTask: (any StartupBackgroundTaskRunning)? = nil,
        connectedPeripherals: [any PeripheralRemote] = []
    ) {
        self.queue = queue
        self.executor = QueueExecutor(queue: queue)
        self.configuration = configuration
        self.manager = backend
        self.proxy = nil

        let runner = startupBackgroundTask ?? NoOpStartupBackgroundTask()
        self.startupBackgroundTask = runner
        self.startupWindowOpen = configuration.restoration != nil

        // Every direct write to a stored property must come before the `eventHandler` closures
        // below. See `init(adopting:...)`.
        var adopted: [(identifier: PeripheralIdentifier, peripheral: any PeripheralRemote)] = []
        for connectedPeripheral in connectedPeripherals {
            let identifier = PeripheralIdentifier(uuid: connectedPeripheral.identifier, name: connectedPeripheral.name)
            adopted.append((identifier, connectedPeripheral))
            connections[identifier] = .connected(Session.adopted(
                identifier: identifier,
                peripheral: connectedPeripheral,
                warningOptions: configuration.warningOptions
            ))
            connectionBroadcaster.yield(.connected(identifier))
        }

        // `self` is fully initialized, so a closure can capture it now. Set up the handlers on
        // `queue` with `queue.sync`. This is safe, because nothing else runs on `queue` yet. The
        // backend's `eventHandler` setter can be queue-confined, as in `FakeCentral` and
        // `FakePeripheral`.
        //
        // The closures capture `self` strongly, unlike the production paths. See the Retention
        // note in this initializer's doc comment.
        queue.sync {
            backend.eventHandler = { event in
                self.assumeIsolated(onQueue: self.queue) { $0.handle(event) }
            }
            for (identifier, connectedPeripheral) in adopted {
                connectedPeripheral.eventHandler = { event in
                    self.assumeIsolated(onQueue: self.queue) { $0.handle(event, from: identifier) }
                }
            }
        }

        if configuration.restoration != nil {
            runner.begin { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.handleStartupBackgroundTaskExpiration()
                    }
                }
            }
        }
    }

    /// Cancels any auto-reconnect loop and any restoration reconnect in progress. An actor
    /// `deinit` can use isolated storage directly, so no `Task` hop is needed.
    deinit {
        for loop in reconnectLoops.values {
            loop.task.cancel()
        }
        for task in restorationTasks.values {
            task.cancel()
        }
        startupBackgroundTask.end()
    }

    /// Stops this `Central`, detaches the delegate of the underlying `CBCentralManager`, and
    /// hands the manager to the caller, so other code can adopt it.
    ///
    /// - Returns: The underlying `CBCentralManager` and every connected `CBPeripheral`, sorted
    ///   by identifier.
    /// - Throws: ``BLESwiftError/stopped`` in these cases:
    ///   - The `Central` is already stopped.
    ///   - A real `CBCentralManager` does not back the `Central`.
    ///   - A tracked peripheral has a connection attempt or a disconnect in progress. Extraction
    ///     then would leave the pending continuation waiting forever.
    public func stopAndExtractState() throws -> (manager: CBCentralManager, peripherals: [CBPeripheral]) {
        guard let currentManager = manager else {
            throw BLESwiftError.stopped
        }
        guard let cbManager = currentManager as? CBCentralManager else {
            throw BLESwiftError.stopped
        }

        // An entry that is not `.connected` blocks extraction. See the throws docs above.
        guard !connections.values.contains(where: { if case .connected = $0 { return false }; return true }) else {
            throw BLESwiftError.stopped
        }

        let connectedPeripherals: [(identifier: PeripheralIdentifier, peripheral: CBPeripheral)] = connections
            .compactMap { identifier, phase in
                guard case .connected(let session) = phase, let cbPeripheral = session.peripheral as? CBPeripheral else { return nil }
                return (identifier, cbPeripheral)
            }
            .sorted { $0.identifier.uuid.uuidString < $1.identifier.uuid.uuidString }

        for id in Array(reconnectLoops.keys) {
            reconnectLoops[id]?.task.cancel()
        }
        reconnectLoops.removeAll()
        for task in restorationTasks.values {
            task.cancel()
        }
        restorationTasks.removeAll()
        pendingRestoration = nil
        endStartupBackgroundTask()
        failAllSessionsPendingGATTContinuations(error: .stopped)
        finishAllSessionsNotificationStreams(error: BLESwiftError.stopped)
        for identifier in Array(dormantNotifications.keys) {
            finishDormantNotifications(for: identifier, error: BLESwiftError.stopped)
        }
        closeAllSessionsL2CAPChannels(error: BLESwiftError.stopped)
        connections.removeAll()

        // Give up this actor's reference before the method returns `cbManager`. This is
        // required. See the doc comment of ``manager``.
        manager = nil
        cbManager.delegate = nil
        // Also detach every extracted peripheral's event delivery. The new owner installs its
        // own delegate.
        for (_, peripheral) in connectedPeripherals {
            peripheral.eventHandler = nil
        }
        proxy?.handler = nil

        return (cbManager, connectedPeripherals.map(\.peripheral))
    }

    // MARK: - Public surface

    /// The current state of the Bluetooth radio, as a synchronous snapshot. You can read it
    /// without `await` from any isolation domain.
    public nonisolated var state: CentralState {
        stateBox.withLock { $0 }
    }

    /// The current Bluetooth authorization status of the app.
    ///
    /// - Note: After ``stopAndExtractState()``, this returns `.notDetermined`, because this
    ///   `Central` no longer owns a manager.
    public var authorization: BluetoothAuthorization {
        guard let manager else { return .notDetermined }
        return type(of: manager).bluetoothAuthorization
    }

    /// Whether a scan is active, as a synchronous snapshot. You can read it without `await`
    /// from any isolation domain.
    public nonisolated var isScanning: Bool {
        isScanningBox.withLock { $0 }
    }

    /// Returns a multicast stream of every ``CentralState`` transition. It replays the latest
    /// state to a late subscriber.
    public func stateEvents() -> AsyncStream<CentralState> {
        stateBroadcaster.stream()
    }

    // MARK: - Connection lifecycle

    /// A snapshot of the connection lifecycle of `id`. It is `.disconnected` when `id` has no
    /// tracked entry. See ``ConnectionState``.
    public func connectionState(of id: PeripheralIdentifier) -> ConnectionState {
        switch connections[id] {
        case .none:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected(let session):
            return .connected(Peripheral(id: session.identifier, central: self))
        case .disconnecting:
            return .disconnecting
        }
    }

    /// A snapshot of the handle of every connected peripheral, sorted by `id.uuid.uuidString`.
    public var connectedPeripherals: [Peripheral] {
        connections.compactMap { identifier, phase -> Peripheral? in
            guard case .connected = phase else { return nil }
            return Peripheral(id: identifier, central: self)
        }.sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }
    }

    /// Returns a multicast stream of every ``ConnectionEvent`` across every peripheral. See
    /// ``ConnectionEvent`` for the events. There is no replay. A subscriber sees only the
    /// events after it subscribes. For the current state, use ``connectionState(of:)`` or
    /// ``connectedPeripherals``.
    public func connectionEvents() -> AsyncStream<ConnectionEvent> {
        connectionBroadcaster.stream()
    }

    #if !os(macOS)
    /// Returns a multicast stream of system-level connection events for peripherals that
    /// match `services` or `peripherals` (any of them). The system delivers an event when a
    /// matching peripheral connects to or disconnects from the *system*. Any app, or the
    /// Bluetooth settings pane, can cause the event. It wraps
    /// `CBCentralManager.registerForConnectionEvents(options:)`.
    ///
    /// A reference count controls the CoreBluetooth registration:
    /// - The first subscriber's stream starts the registration, with that call's match options.
    /// - The last subscriber's termination cancels the registration.
    /// - A later call while subscribers exist joins the multicast without a new registration,
    ///   so it ignores its `services` and `peripherals`. They apply again only after the
    ///   registration drops to zero and starts again.
    ///
    /// This API is not available on macOS.
    ///
    /// - Parameters:
    ///   - services: Match peripherals that expose any of these services, or `nil` for no
    ///     service criterion.
    ///   - peripherals: Match these peripherals, or `nil` for no peripheral criterion. If both
    ///     are `nil`, the registration has no match options, and CoreBluetooth matches nothing.
    /// - Returns: An `AsyncStream` of ``SystemConnectionEvent``. There is no replay. A
    ///   subscriber sees only the events after it subscribes.
    public func connectionEventRegistration(
        services: [ServiceIdentifier]? = nil,
        peripherals: [PeripheralIdentifier]? = nil
    ) -> AsyncStream<SystemConnectionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SystemConnectionEvent.self)
        let token = nextConnectionEventToken
        nextConnectionEventToken += 1
        connectionEventSubscribers[token] = continuation
        if connectionEventSubscribers.count == 1 {
            manager?.registerForConnectionEvents(services: services, peripherals: peripherals?.map(\.uuid))
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.assumeIsolated(onQueue: self.queue) { central in
                    central.removeConnectionEventSubscriber(token)
                }
            }
        }
        return stream
    }

    /// Removes one entry of ``connectionEventSubscribers``. When the last entry goes, it
    /// unregisters from the backend. It is idempotent for each token.
    private func removeConnectionEventSubscriber(_ token: UInt64) {
        guard connectionEventSubscribers.removeValue(forKey: token) != nil else { return }
        if connectionEventSubscribers.isEmpty {
            manager?.unregisterForConnectionEvents()
        }
    }
    #endif

    #if os(iOS)
    /// Resolves `Peripheral.ancsAuthorized`. It returns the backend's value for the live
    /// session, or `false` when `id` is not connected.
    func ancsAuthorized(for id: PeripheralIdentifier) -> Bool {
        guard case .connected(let session) = connections[id] else { return false }
        return session.peripheral.ancsAuthorized
    }
    #endif

    #if os(iOS)
    /// Connects to a known peripheral.
    ///
    /// BLESwift supports concurrent connections to several peripherals. The call fails
    /// immediately with ``BLESwiftError/duplicateConnect(_:)`` only if `id` already has a
    /// tracked entry. A new call for `id` cancels its auto-reconnect loop and replaces its
    /// ``ReconnectPolicy``. See <doc:ConnectionsAndReconnection>.
    ///
    /// - Parameters:
    ///   - id: The peripheral to connect to.
    ///   - timeout: How long to wait before the call throws ``BLESwiftError/connectionTimedOut``.
    ///     The default is 15 seconds. `nil` waits without a limit. On timeout, the call cancels
    ///     the CoreBluetooth attempt, waits for its confirmation, and then throws.
    ///   - reconnect: What to do if the connection is lost unexpectedly later. The default is
    ///     ``ReconnectPolicy/never``.
    ///   - warningOptions: Overrides, for this connection, the iOS system alerts for a
    ///     suspended app. The default is the `warningOptions` of ``Configuration``.
    ///   - compatibility: Accommodations for peripherals that report their GATT database
    ///     incorrectly. The default is ``GATTCompatibility/strict``. It applies to this
    ///     connection only.
    ///   - requiresANCS: iOS only. Requires ANCS authorization for this connection. Track it
    ///     with ``Peripheral/ancsAuthorized`` and ``Peripheral/ancsAuthorizationEvents()``.
    ///     Auto-reconnect attempts reuse this value.
    /// - Returns: A ``Peripheral`` handle for the connection.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/duplicateConnect(_:)``.
    ///   - ``BLESwiftError/unexpectedPeripheral(_:)`` if CoreBluetooth does not know `id`.
    ///   - ``BLESwiftError/connectionTimedOut``.
    ///   - ``BLESwiftError/operationCancelled`` on task cancellation.
    ///   - Any other error that CoreBluetooth reports.
    public func connect(
        _ id: PeripheralIdentifier,
        timeout: Duration? = .seconds(15),
        reconnect: ReconnectPolicy = .never,
        warningOptions: WarningOptions? = nil,
        compatibility: GATTCompatibility = .strict,
        requiresANCS: Bool = false
    ) async throws -> Peripheral {
        try await connectImpl(id, timeout: timeout, reconnect: reconnect, warningOptions: warningOptions, compatibility: compatibility, requiresANCS: requiresANCS)
    }
    #else
    /// Connects to a known peripheral.
    ///
    /// BLESwift supports concurrent connections to several peripherals. The call fails
    /// immediately with ``BLESwiftError/duplicateConnect(_:)`` only if `id` already has a
    /// tracked entry. A new call for `id` cancels its auto-reconnect loop and replaces its
    /// ``ReconnectPolicy``. See <doc:ConnectionsAndReconnection>.
    ///
    /// - Parameters:
    ///   - id: The peripheral to connect to.
    ///   - timeout: How long to wait before the call throws ``BLESwiftError/connectionTimedOut``.
    ///     The default is 15 seconds. `nil` waits without a limit. On timeout, the call cancels
    ///     the CoreBluetooth attempt, waits for its confirmation, and then throws.
    ///   - reconnect: What to do if the connection is lost unexpectedly later. The default is
    ///     ``ReconnectPolicy/never``.
    ///   - warningOptions: Overrides, for this connection, the iOS system alerts for a
    ///     suspended app. The default is the `warningOptions` of ``Configuration``.
    ///   - compatibility: Accommodations for peripherals that report their GATT database
    ///     incorrectly. The default is ``GATTCompatibility/strict``. It applies to this
    ///     connection only.
    /// - Returns: A ``Peripheral`` handle for the connection.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/duplicateConnect(_:)``.
    ///   - ``BLESwiftError/unexpectedPeripheral(_:)`` if CoreBluetooth does not know `id`.
    ///   - ``BLESwiftError/connectionTimedOut``.
    ///   - ``BLESwiftError/operationCancelled`` on task cancellation.
    ///   - Any other error that CoreBluetooth reports.
    public func connect(
        _ id: PeripheralIdentifier,
        timeout: Duration? = .seconds(15),
        reconnect: ReconnectPolicy = .never,
        warningOptions: WarningOptions? = nil,
        compatibility: GATTCompatibility = .strict
    ) async throws -> Peripheral {
        try await connectImpl(id, timeout: timeout, reconnect: reconnect, warningOptions: warningOptions, compatibility: compatibility, requiresANCS: false)
    }
    #endif

    /// The shared body of the two platform variants of `connect(_:...)`. `requiresANCS` is a
    /// public parameter on iOS only and is always `false` elsewhere.
    private func connectImpl(
        _ id: PeripheralIdentifier,
        timeout: Duration?,
        reconnect: ReconnectPolicy,
        warningOptions: WarningOptions?,
        compatibility: GATTCompatibility,
        requiresANCS: Bool
    ) async throws -> Peripheral {
        guard manager != nil else { throw BLESwiftError.stopped }

        // Restoration owns the connection slot until its routing has run. Reject the racing call
        // up front and do not cancel it afterward.
        if pendingRestoration != nil {
            throw BLESwiftError.backgroundRestorationInProgress
        }

        let resolvedWarningOptions = warningOptions ?? configuration.warningOptions

        // Claim the connection slot SYNCHRONOUSLY, before any suspension point. This closes the
        // concurrent-connect TOCTOU deadlock: a second racing `connect(id)` sees the reservation
        // and throws `.duplicateConnect` and does not overwrite the pending continuation (see
        // `reserveConnectingSlot` and `awaitConnect`).
        try reserveConnectingSlot(
            identifier: id,
            policy: reconnect,
            timeout: timeout,
            warningOptions: resolvedWarningOptions,
            compatibility: compatibility,
            requiresANCS: requiresANCS
        )

        // Cancel a reconnect loop for THIS peripheral only. This is safe after the reservation,
        // because a reconnect *attempt* in progress would already own the slot and the
        // reservation would have thrown. A user connect replaces the loop, so notification
        // subscriptions that wait for the loop finish now with `.explicitDisconnect`. The new
        // connection starts with no old state.
        reconnectLoops[id]?.task.cancel()
        reconnectLoops.removeValue(forKey: id)
        finishDormantNotifications(for: id, error: BLESwiftError.explicitDisconnect)

        return try await establishConnection(
            identifier: id,
            policy: reconnect,
            timeout: timeout,
            warningOptions: resolvedWarningOptions
        )
    }

    /// Disconnects `id`, or cancels its connection attempt in progress. An explicit disconnect
    /// is intentional, so it never triggers a ``ReconnectPolicy`` retry. Other peripherals are
    /// not affected.
    ///
    /// Operations in progress on the outgoing connection (reads, writes, notification streams,
    /// and L2CAP channels) fail with ``BLESwiftError/explicitDisconnect``.
    ///
    /// - Parameter id: The peripheral to disconnect.
    /// - Throws: ``BLESwiftError/notConnected`` if `id` has no connection, connection attempt,
    ///   or auto-reconnect loop. ``BLESwiftError/multipleDisconnectNotSupported`` if `id` is
    ///   already disconnecting.
    public func disconnect(_ id: PeripheralIdentifier) async throws {
        switch connections[id] {
        case .none:
            // No tracked entry does not mean that nothing needs to stop. An auto-reconnect loop
            // has no `connections` entry during backoff, so a `disconnect(id)` then must cancel
            // the loop and not throw `.notConnected`.
            if reconnectLoops[id] != nil {
                reconnectLoops[id]?.task.cancel()
                reconnectLoops.removeValue(forKey: id)
                reconnectGeneration += 1
                finishDormantNotifications(for: id, error: BLESwiftError.explicitDisconnect)
                log("disconnect(\(id)) cancelled an in-flight auto-reconnect loop", level: .info, category: "connection")
                return
            }
            throw BLESwiftError.notConnected
        case .disconnecting:
            throw BLESwiftError.multipleDisconnectNotSupported
        case .connecting(let connecting):
            // The slot is reserved but not attached, so no CoreBluetooth attempt exists to
            // cancel, and no disconnect callback would complete a `.disconnecting` transition.
            // Record `.explicitDisconnect`, so the attach in `awaitConnect` resolves it.
            if connecting.continuation == nil {
                var reserved = connecting
                reserved.stopping = BLESwiftError.explicitDisconnect
                connections[id] = .connecting(reserved)
                return
            }
            try await beginDisconnecting(
                identifier: id,
                peripheral: connecting.peripheral,
                disconnectContinuation: nil,
                connectContinuation: connecting.continuation,
                connectFailureReason: BLESwiftError.explicitDisconnect
            )
        case .connected(let session):
            try await beginDisconnecting(
                identifier: id,
                peripheral: session.peripheral,
                disconnectContinuation: nil,
                connectContinuation: nil,
                connectFailureReason: BLESwiftError.explicitDisconnect
            )
        }
    }

    /// Best-effort teardown of every tracked peripheral. It cancels every auto-reconnect loop
    /// and then disconnects every tracked entry.
    ///
    /// It never throws. Observe the individual outcomes on ``connectionEvents()``. It is
    /// idempotent.
    public func disconnectAll() async {
        for id in Array(reconnectLoops.keys) {
            reconnectLoops[id]?.task.cancel()
        }
        if !reconnectLoops.isEmpty {
            reconnectLoops.removeAll()
            reconnectGeneration += 1
            log("disconnectAll() cancelled every in-flight auto-reconnect loop", level: .info, category: "connection")
        }

        // Peripherals in backoff have no `connections` entry, so the disconnect loop below
        // never reaches their parked notification survivors. Finish those here. The
        // `.disconnecting` branch of `handleTermination` finishes the connected peripherals'
        // records.
        for id in Array(dormantNotifications.keys) where connections[id] == nil {
            finishDormantNotifications(for: id, error: BLESwiftError.explicitDisconnect)
        }

        for id in Array(connections.keys) {
            try? await disconnect(id)
        }
    }

    /// Cancels the connection attempt in progress, if any, for every tracked peripheral. It
    /// does not disconnect an established connection.
    ///
    /// Like an explicit `disconnect`, it never triggers a ``ReconnectPolicy`` retry. It does
    /// not touch an active scan.
    ///
    /// - Parameter error: The error that pending operations fail with. The default is
    ///   ``BLESwiftError/cancelled``.
    public func cancelAllOperations(error: Error? = nil) {
        let resolvedError = error ?? BLESwiftError.cancelled

        // Also cancel every auto-reconnect loop. A waiting reconnect is a pending connection
        // attempt. Incrementing the generation counter stops a late loop iteration from
        // clearing a newer loop's entry.
        if !reconnectLoops.isEmpty {
            for id in Array(reconnectLoops.keys) {
                reconnectLoops[id]?.task.cancel()
            }
            reconnectLoops.removeAll()
            reconnectGeneration += 1
            log("cancelAllOperations() cancelled every in-flight auto-reconnect loop", level: .info, category: "connection")
        }

        // A parked notification survivor is also a pending operation. Finish every dormant
        // record with the resolved error.
        for identifier in Array(dormantNotifications.keys) {
            finishDormantNotifications(for: identifier, error: resolvedError)
        }

        for identifier in Array(connections.keys) {
            switch connections[identifier] {
            case .connecting(let connecting):
                // The slot is reserved but not attached. Handle it like `failPendingConnect`.
                if connecting.continuation == nil {
                    var reserved = connecting
                    reserved.stopping = resolvedError
                    connections[identifier] = .connecting(reserved)
                    continue
                }
                connections[identifier] = .disconnecting(Disconnecting(
                    identifier: identifier,
                    peripheral: connecting.peripheral,
                    continuation: nil,
                    connectContinuation: connecting.continuation,
                    connectFailureReason: resolvedError
                ))
                if state == .poweredOn {
                    manager?.cancelPeripheralConnection(connecting.peripheral)
                } else {
                    handleTermination(identifier: identifier, error: nil)
                }
            case .connected:
                failPendingGATTContinuations(for: identifier, error: .cancelled)
            case .disconnecting, .none:
                break
            }
        }
    }

    // MARK: - Connect internals

    /// Resolves after `id` is connected, or throws. It wraps
    /// ``awaitConnect(id:policy:timeout:warningOptions:)`` in
    /// ``withTimeout(clock:_:throwing:operation:)``, which still waits for the real
    /// two-phase-cancel confirmation before it returns.
    ///
    /// The function takes only `identifier`, because `any PeripheralRemote` is not `Sendable`
    /// and cannot cross into `withTimeout`'s `@Sendable` closure.
    /// ``reserveConnectingSlot(identifier:policy:timeout:warningOptions:compatibility:)``
    /// already resolved the peripheral. Every caller must call it first, synchronously, in the
    /// same actor turn.
    private func establishConnection(
        identifier: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions
    ) async throws -> Peripheral {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.connectionTimedOut) {
            try await self.awaitConnect(id: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions)
        }
    }

    /// Synchronously claims the ``connections`` slot of `identifier` for a new connection
    /// attempt, before any suspension point. This prevents the concurrent-connect TOCTOU
    /// deadlock. The function resolves the target peripheral, sets up its event delivery, and
    /// writes a `.connecting` reservation with no continuation. A racing call then fails the
    /// `nil` guard and throws `.duplicateConnect`, and does not overwrite a live attempt.
    ///
    /// Every path that starts a connection through
    /// ``establishConnection(identifier:policy:timeout:warningOptions:)`` must call this
    /// function first, synchronously, in the same actor turn as its own check for an occupied
    /// slot. These paths are:
    /// - User `connect`.
    /// - The auto-reconnect loop.
    /// - The manual reconnect of restoration.
    ///
    /// The adoption paths write a `.connected` entry directly and need no reservation.
    ///
    /// - Throws: ``BLESwiftError/duplicateConnect(_:)`` if the slot is already occupied.
    ///   ``BLESwiftError/unexpectedPeripheral(_:)`` if CoreBluetooth no longer knows
    ///   `identifier`.
    private func reserveConnectingSlot(
        identifier: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions,
        compatibility: GATTCompatibility,
        requiresANCS: Bool = false
    ) throws {
        guard connections[identifier] == nil else {
            throw BLESwiftError.duplicateConnect(identifier)
        }
        guard let target = manager?.retrievePeripherals(withIdentifiers: [identifier.uuid]).first else {
            throw BLESwiftError.unexpectedPeripheral(identifier)
        }

        // Set up event delivery before the attempt goes live, for every path that creates a
        // session. `awaitConnect` issues the actual `connect` only after it attaches its
        // continuation, so no event can arrive first.
        target.eventHandler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated(onQueue: self.queue) { $0.handle(event, from: identifier) }
        }

        connections[identifier] = .connecting(Connecting(
            identifier: identifier,
            peripheral: target,
            policy: policy,
            timeout: timeout,
            warningOptions: warningOptions,
            compatibility: compatibility,
            requiresANCS: requiresANCS,
            continuation: nil,
            stopping: nil
        ))
    }

    /// Attaches a pending connect continuation to the slot that
    /// ``reserveConnectingSlot(identifier:policy:timeout:warningOptions:compatibility:)``
    /// reserved, starts the CoreBluetooth connection attempt, and suspends until
    /// ``handle(_:)`` resolves the continuation. This function never resolves it directly and
    /// does not create the ``connections`` entry.
    ///
    /// When the surrounding `Task` is cancelled, `withTaskCancellationHandler` starts the
    /// two-phase-cancel sequence of a real cancellation (see ``failPendingConnect(for:error:)``).
    /// The handler hops onto ``queue`` through `assumeIsolated`, like `CentralDelegateProxy`.
    private func awaitConnect(
        id: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions
    ) async throws -> Peripheral {
        try await withTaskCancellationHandler {
            let attach = { [self] (continuation: CheckedContinuation<Peripheral, Error>) in
                // Attach to the slot that the caller reserved through `reserveConnectingSlot`. Do
                // NOT create the slot here. A reserved slot is `.connecting` with a `nil`
                // continuation, and no CoreBluetooth attempt has started yet.
                guard case .connecting(var connecting) = connections[id], connecting.continuation == nil else {
                    // The expected reservation is gone or already attached. Resolve the
                    // continuation defensively. Do not orphan it.
                    continuation.resume(throwing: BLESwiftError.operationCancelled)
                    return
                }

                // A cancel, timeout, or disconnect can race in during the reservation window,
                // before any CoreBluetooth `connect` starts, and record its error in `stopping`.
                // Resolve here directly, because nothing needs to be torn down.
                if let stopping = connecting.stopping {
                    connections.removeValue(forKey: id)
                    connecting.peripheral.eventHandler = nil
                    continuation.resume(throwing: stopping)
                    return
                }

                // Normal attach: set the continuation, THEN issue the connect. Never issue it
                // earlier, or a callback could arrive while the slot is not attached.
                connecting.continuation = continuation
                connections[id] = .connecting(connecting)
                connectionBroadcaster.yield(.connecting(id))
                log("Connecting to \(id)", level: .info, category: "connection")
                manager?.connect(connecting.peripheral, options: warningOptions, requiresANCS: connecting.requiresANCS)
            }
            // Pin the isolation on Swift 6.3 and earlier. See `withCancellableGATTContinuation`.
            #if compiler(>=6.4)
            return try await withCheckedThrowingContinuation(attach)
            #else
            return try await withCheckedThrowingContinuation(isolation: self, attach)
            #endif
        } onCancel: {
            self.queue.async {
                self.assumeIsolated(onQueue: self.queue) { central in
                    central.failPendingConnect(for: id, error: BLESwiftError.operationCancelled)
                }
            }
        }
    }

    /// Fails the pending connect for `id`. If the radio is on, it works in two phases: it marks
    /// `stopping`, and then the `didFailToConnect` or `didDisconnect` path resolves the connect.
    /// If the radio is off, it resolves the connect immediately. It is idempotent and does
    /// nothing if nothing is pending.
    private func failPendingConnect(for id: PeripheralIdentifier, error: Error) {
        guard case .connecting(var connecting) = connections[id] else { return }
        guard connecting.stopping == nil else { return }

        // The slot is reserved but not attached, so nothing needs to be cancelled and no
        // callback will arrive. Record the error. The attach in `awaitConnect` resolves it.
        if connecting.continuation == nil {
            connecting.stopping = error
            connections[id] = .connecting(connecting)
            return
        }

        if state == .poweredOn {
            connecting.stopping = error
            connections[id] = .connecting(connecting)
            manager?.cancelPeripheralConnection(connecting.peripheral)
        } else {
            handleTermination(identifier: id, error: error)
        }
    }

    // MARK: - Disconnect internals

    /// Moves `identifier` to `.disconnecting`. If the radio is on, it asks CoreBluetooth to
    /// cancel the connection, and ``handleTermination(identifier:error:)`` confirms the
    /// cancel. If the radio is not powered on, it resolves synchronously. It first cancels the
    /// reconnect loop of `identifier`. Other peripherals are not touched.
    private func beginDisconnecting(
        identifier: PeripheralIdentifier,
        peripheral: any PeripheralRemote,
        disconnectContinuation: CheckedContinuation<Void, Error>?,
        connectContinuation: CheckedContinuation<Peripheral, Error>?,
        connectFailureReason: Error
    ) async throws {
        reconnectLoops[identifier]?.task.cancel()
        reconnectLoops.removeValue(forKey: identifier)

        // Fail the GATT operations in progress on the outgoing session *before* the entry
        // moves away from `.connected`, because its registries live inside `Session`, which is
        // gone after the phase changes.
        failPendingGATTContinuations(for: identifier, error: .explicitDisconnect)

        // Same for notification streams.
        finishNotificationStreams(for: identifier, error: BLESwiftError.explicitDisconnect)

        // Same for open L2CAP channels.
        closeL2CAPChannels(for: identifier, error: BLESwiftError.explicitDisconnect)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connections[identifier] = .disconnecting(Disconnecting(
                identifier: identifier,
                peripheral: peripheral,
                continuation: continuation,
                connectContinuation: connectContinuation,
                connectFailureReason: connectFailureReason
            ))
            log("Disconnecting from \(identifier)", level: .info, category: "connection")
            if state == .poweredOn {
                manager?.cancelPeripheralConnection(peripheral)
            } else {
                handleTermination(identifier: identifier, error: nil)
            }
        }
    }

    // MARK: - Shared connection cleanup

    /// The single cleanup path for every way that a tracked connection (or attempt) for
    /// `identifier` ends: a real `didFailToConnect` or `didDisconnect` callback, or a
    /// synchronous resolution when no radio is available to wait on.
    ///
    /// The cleanup order is:
    /// 1. Fail the GATT continuations in progress.
    /// 2. Finish the notification streams.
    /// 3. Yield `.disconnected`.
    /// 4. Resume the pending continuations.
    /// 5. Start a reconnect loop if the ``ReconnectPolicy`` requires it.
    ///
    /// It then removes the ``connections`` entry of `identifier`. If there is no entry, it only
    /// writes a debug log.
    private func handleTermination(identifier: PeripheralIdentifier, error: Error?) {
        switch connections[identifier] {
        case .none:
            log("Ignoring a disconnect/fail event for untracked peripheral \(identifier)", level: .debug, category: "connection")

        case .connecting(var connecting):
            let resolvedError = connecting.stopping ?? error ?? BLESwiftError.unexpectedDisconnect
            let policy = connecting.policy
            let timeout = connecting.timeout
            let warningOptions = connecting.warningOptions
            let compatibility = connecting.compatibility
            let requiresANCS = connecting.requiresANCS
            let continuation = connecting.continuation
            connecting.continuation = nil
            connections.removeValue(forKey: identifier)

            // Detach event delivery, the counterpart of the attach in `awaitConnect`. A reconnect
            // attaches again on its own.
            connecting.peripheral.eventHandler = nil

            failPendingGATTContinuations(for: identifier, error: .notConnected)
            finishNotificationStreams(for: identifier, error: resolvedError)
            closeL2CAPChannels(for: identifier, error: resolvedError)

            let willReconnect = !policy.isNever
            if !willReconnect {
                finishDormantNotifications(for: identifier, error: resolvedError)
            }
            connectionBroadcaster.yield(.disconnected(identifier, error: resolvedError, willReconnect: willReconnect))

            continuation?.resume(throwing: resolvedError)

            // Do not start a second loop if one already runs for `identifier`. Its own catch
            // block continues the retries. Only a new top-level failure starts a loop here.
            if willReconnect, reconnectLoops[identifier] == nil {
                scheduleReconnect(identifier: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions, compatibility: compatibility, requiresANCS: requiresANCS)
            }

        case .connected(let session):
            let policy = session.policy
            let timeout = session.timeout
            let warningOptions = session.warningOptions
            let compatibility = session.compatibility
            let requiresANCS = session.requiresANCS
            let willReconnect = !policy.isNever

            // Fail the GATT operations and finish the notification streams before the entry is
            // removed. See `beginDisconnecting`. When a reconnect follows, subscriptions that
            // opted into `survivesReconnect` become dormant and do not end.
            let resolvedError = error ?? BLESwiftError.unexpectedDisconnect
            failPendingGATTContinuations(for: identifier, error: .unexpectedDisconnect)
            finishNotificationStreams(for: identifier, error: resolvedError, retainSurvivors: willReconnect)
            closeL2CAPChannels(for: identifier, error: resolvedError)
            connections.removeValue(forKey: identifier)

            // Detach event delivery. A reconnect attempt attaches again at its start.
            session.peripheral.eventHandler = nil

            if !willReconnect {
                finishDormantNotifications(for: identifier, error: resolvedError)
            }
            connectionBroadcaster.yield(.disconnected(identifier, error: error, willReconnect: willReconnect))

            // The same guard against a second loop as in the `.connecting` branch.
            if willReconnect, reconnectLoops[identifier] == nil {
                scheduleReconnect(identifier: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions, compatibility: compatibility, requiresANCS: requiresANCS)
            }

        case .disconnecting(var disconnecting):
            connections.removeValue(forKey: identifier)

            // Detach event delivery. An explicit disconnect never reconnects.
            disconnecting.peripheral.eventHandler = nil

            // Usually a defensive no-op, because `beginDisconnecting` already did it. It stays for
            // the path where `cancelAllOperations()` cancels a pending connect.
            failPendingGATTContinuations(for: identifier, error: .explicitDisconnect)
            finishNotificationStreams(for: identifier, error: BLESwiftError.explicitDisconnect)
            closeL2CAPChannels(for: identifier, error: BLESwiftError.explicitDisconnect)
            finishDormantNotifications(for: identifier, error: BLESwiftError.explicitDisconnect)

            connectionBroadcaster.yield(.disconnected(identifier, error: error, willReconnect: false))

            let disconnectContinuation = disconnecting.continuation
            disconnecting.continuation = nil
            disconnectContinuation?.resume(returning: ())

            let connectContinuation = disconnecting.connectContinuation
            disconnecting.connectContinuation = nil
            connectContinuation?.resume(throwing: disconnecting.connectFailureReason)
        }
    }

    /// Fails every pending connect attempt and every established connection with
    /// ``BLESwiftError/bluetoothUnavailable``. It does not wait for a disconnect callback,
    /// because that callback may not arrive. Reconnect loops are not cancelled. Their attempts
    /// fail on their own, and the policy decides whether to retry.
    private func handleBluetoothUnavailable() {
        for identifier in Array(connections.keys) {
            switch connections[identifier] {
            case .connecting:
                failPendingConnect(for: identifier, error: BLESwiftError.bluetoothUnavailable)
            case .connected:
                handleTermination(identifier: identifier, error: BLESwiftError.bluetoothUnavailable)
            case .disconnecting, .none:
                break
            }
        }
    }

    /// Fails every GATT operation in progress on the connected session of `identifier` with
    /// `error`. It resumes every pending continuation with a throw and cancels every
    /// characteristic FIFO tail and the RSSI tail. This is cleanup step 1 of
    /// ``handleTermination(identifier:error:)``. ``cancelAllOperations(error:)`` also calls it
    /// directly, and the connection then stays intact.
    ///
    /// Unlike ``failAllPendingOperations(error:)``, which concerns only the active scan, it
    /// does nothing if `identifier` is not `.connected`.
    func failPendingGATTContinuations(for identifier: PeripheralIdentifier, error: BLESwiftError) {
        guard case .connected(var session) = connections[identifier] else {
            log("No connected session for \(identifier) — nothing to fail", level: .debug, category: "gatt")
            return
        }

        log("Failing all pending GATT operations for \(identifier): \(error)", level: .warning, category: "gatt")

        for task in session.fifoTails.values {
            task.cancel()
        }
        session.fifoTails.removeAll()
        session.rssiTail?.cancel()
        session.rssiTail = nil
        session.rearmTask?.cancel()
        session.rearmTask = nil

        for continuation in session.pendingReads.values {
            continuation.resume(throwing: error)
        }
        session.pendingReads.removeAll()

        for continuation in session.pendingWrites.values {
            continuation.resume(throwing: error)
        }
        session.pendingWrites.removeAll()

        for continuation in session.pendingNotifyStateChanges.values {
            continuation.resume(throwing: error)
        }
        session.pendingNotifyStateChanges.removeAll()

        session.pendingRSSIRead?.resume(throwing: error)
        session.pendingRSSIRead = nil

        for continuation in session.pendingDiscoverServices.values {
            continuation.resume(throwing: error)
        }
        session.pendingDiscoverServices.removeAll()

        for waiters in session.pendingDiscoverCharacteristics.values {
            for continuation in waiters.values {
                continuation.resume(throwing: error)
            }
        }
        session.pendingDiscoverCharacteristics.removeAll()

        for continuation in session.pendingWriteWithoutResponseReady.values {
            continuation.resume(throwing: error)
        }
        session.pendingWriteWithoutResponseReady.removeAll()

        for continuation in session.pendingDescriptorReads.values {
            continuation.resume(throwing: error)
        }
        session.pendingDescriptorReads.removeAll()

        for continuation in session.pendingDescriptorWrites.values {
            continuation.resume(throwing: error)
        }
        session.pendingDescriptorWrites.removeAll()

        for waiters in session.pendingDiscoverDescriptors.values {
            for continuation in waiters.values {
                continuation.resume(throwing: error)
            }
        }
        session.pendingDiscoverDescriptors.removeAll()

        connections[identifier] = .connected(session)
    }

    /// Calls ``failPendingGATTContinuations(for:error:)`` for every connected peripheral.
    /// ``stopAndExtractState()`` and ``cancelAllOperations(error:)`` use it.
    func failAllSessionsPendingGATTContinuations(error: BLESwiftError) {
        for identifier in Array(connections.keys) {
            failPendingGATTContinuations(for: identifier, error: error)
        }
    }

    /// Finishes every active notification stream on the session of `identifier` with `error`
    /// and clears its registry. This is cleanup step 2 of
    /// ``handleTermination(identifier:error:)``. It must run while the entry is still
    /// `.connected`, because the registry lives inside `Session`.
    ///
    /// It does NOT cancel the pump tasks. Each pump task ends on its own when its raw stream
    /// finishes, and it forwards `error` to its subscriber. A cancel could race that delivery
    /// and hide the disconnect error.
    ///
    /// `retainSurvivors` applies only when a reconnect follows. Tokens registered with
    /// `survivesReconnect: true` become dormant in ``dormantNotifications`` and do not end.
    /// The raw broadcaster still finishes with `error` for everyone. Non-survivors and
    /// composite helpers end as usual. A survivor's pump catches that error, finds that it is
    /// dormant, and suspends in ``awaitResubscription(identifier:characteristic:token:)`` until
    /// the reconnect enables it again or the loop gives up.
    func finishNotificationStreams(for identifier: PeripheralIdentifier, error: Error, retainSurvivors: Bool = false) {
        guard case .connected(var session) = connections[identifier] else {
            log("No connected session for \(identifier) — no notification streams to finish", level: .debug, category: "gatt")
            return
        }
        guard !session.notificationSubscriptions.isEmpty else { return }

        log("Finishing \(session.notificationSubscriptions.count) notification stream(s) for \(identifier): \(error)", level: .debug, category: "gatt")

        let subscriptions = session.notificationSubscriptions
        session.notificationSubscriptions.removeAll()

        var dormantCharacteristics: [CharacteristicIdentifier: DormantSubscription] = [:]
        var survivorPumps: [UUID: Task<Void, Never>] = [:]
        if retainSurvivors {
            for (characteristic, subscription) in subscriptions {
                let survivors = subscription.subscriberTokens.intersection(session.notificationSurvivorTokens)
                guard !survivors.isEmpty else { continue }
                dormantCharacteristics[characteristic] = DormantSubscription(tokens: survivors)
                for token in survivors {
                    if let pump = session.notificationPumps[token] {
                        survivorPumps[token] = pump
                    }
                }
            }
        }
        session.notificationPumps.removeAll()
        connections[identifier] = .connected(session)

        if !dormantCharacteristics.isEmpty {
            if dormantNotifications[identifier] != nil {
                // Unexpected. A stale record means that a previous gap never resolved.
                log("Stale dormant notification record for \(identifier) — finishing it before parking new survivors", level: .warning, category: "gatt")
                finishDormantNotifications(for: identifier, error: error)
            }
            log("Parking \(dormantCharacteristics.count) notification subscription(s) for \(identifier) across the reconnect", level: .debug, category: "gatt")
            dormantNotifications[identifier] = DormantNotifications(
                disconnectError: error,
                characteristics: dormantCharacteristics,
                pumps: survivorPumps
            )
        }

        for subscription in subscriptions.values {
            for waiter in subscription.enableWaiters.values {
                waiter.resume(throwing: error)
            }
            subscription.broadcaster.finish(throwing: error)
        }
    }

    /// Finishes the parked notification survivors of `identifier` with `error` and removes the
    /// dormant record. It is the exit for every gap that does NOT end in a successful
    /// reconnect: policy exhausted, loop cancelled, explicit disconnect, and
    /// `stopAndExtractState`. It resumes the waiter of every parked pump with `error`, and each
    /// pump then finishes its typed stream and exits. It is idempotent and does nothing if no
    /// record exists.
    func finishDormantNotifications(for identifier: PeripheralIdentifier, error: Error) {
        guard let record = dormantNotifications.removeValue(forKey: identifier) else { return }

        log("Finishing \(record.characteristics.count) dormant notification subscription(s) for \(identifier): \(error)", level: .debug, category: "gatt")

        for subscription in record.characteristics.values {
            for waiter in subscription.waiters.values {
                waiter.resume(throwing: error)
            }
        }
    }

    /// Calls ``finishNotificationStreams(for:error:)`` for every connected peripheral.
    /// ``stopAndExtractState()`` uses it.
    func finishAllSessionsNotificationStreams(error: Error) {
        for identifier in Array(connections.keys) {
            finishNotificationStreams(for: identifier, error: error)
        }
    }

    // MARK: - Auto-reconnect

    /// Starts (or restarts) the auto-reconnect loop for `identifier`, per `policy`. It
    /// increments ``reconnectGeneration`` and tags the new task with it.
    /// ``runReconnectLoop(identifier:policy:timeout:warningOptions:compatibility:generation:)``
    /// clears the entry of `identifier` on exit only if the loop still has this generation.
    /// Without the tag, the late cleanup of a superseded loop could remove a newer loop.
    private func scheduleReconnect(
        identifier: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions,
        compatibility: GATTCompatibility,
        requiresANCS: Bool = false
    ) {
        reconnectGeneration += 1
        let generation = reconnectGeneration
        let task = Task<Void, Never> { [weak self] in
            await self?.runReconnectLoop(identifier: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions, compatibility: compatibility, requiresANCS: requiresANCS, generation: generation)
        }
        reconnectLoops[identifier] = ReconnectLoop(task: task, generation: generation)
    }

    /// Removes the ``reconnectLoops`` entry of `identifier` only if `generation` still matches.
    /// See ``scheduleReconnect(identifier:policy:timeout:warningOptions:compatibility:)``.
    private func clearReconnectLoopIfCurrent(id identifier: PeripheralIdentifier, generation: UInt64) {
        if reconnectLoops[identifier]?.generation == generation {
            reconnectLoops.removeValue(forKey: identifier)
        }
    }

    /// Tries repeatedly to reconnect to `identifier` per `policy`, and emits
    /// ``ConnectionEvent/reconnecting(_:attempt:)`` before each attempt. It stops when an
    /// attempt succeeds, when `policy` says to stop, or when this task is cancelled. It is
    /// independent of every other peripheral's loop.
    private func runReconnectLoop(
        identifier: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions,
        compatibility: GATTCompatibility,
        requiresANCS: Bool,
        generation: UInt64
    ) async {
        var attempt = 1
        var lastError: Error?

        while !Task.isCancelled {
            guard let delay = await policy.nextDelay(attempt: attempt, error: lastError) else {
                // Policy exhausted: parked notification survivors finish with the original
                // disconnect error.
                finishDormantNotificationsWithRecordedError(for: identifier)
                clearReconnectLoopIfCurrent(id: identifier, generation: generation)
                return
            }

            do {
                try await configuration.clock.sleep(for: delay)
            } catch {
                // Cancelled during backoff. The canceller (disconnect, connect, disconnectAll, or
                // cancelAllOperations) usually finished the dormant record with its own error.
                // This call is the safety net for any other cancellation.
                finishDormantNotificationsWithRecordedError(for: identifier)
                clearReconnectLoopIfCurrent(id: identifier, generation: generation)
                return
            }

            guard !Task.isCancelled, connections[identifier] == nil else {
                if connections[identifier] == nil {
                    finishDormantNotificationsWithRecordedError(for: identifier)
                }
                clearReconnectLoopIfCurrent(id: identifier, generation: generation)
                return
            }

            connectionBroadcaster.yield(.reconnecting(identifier, attempt: attempt))
            log("Reconnect attempt \(attempt) for \(identifier)", level: .info, category: "connection")

            do {
                // Reserve the slot synchronously, as in user `connect(_:)`, so a racing user
                // `connect(id)` fails cleanly with `.duplicateConnect`.
                try reserveConnectingSlot(
                    identifier: identifier,
                    policy: policy,
                    timeout: timeout,
                    warningOptions: warningOptions,
                    compatibility: compatibility,
                    requiresANCS: requiresANCS
                )
                _ = try await establishConnection(
                    identifier: identifier,
                    policy: policy,
                    timeout: timeout,
                    warningOptions: warningOptions
                )
                clearReconnectLoopIfCurrent(id: identifier, generation: generation)
                return
            } catch {
                lastError = error
                attempt += 1
            }
        }

        // Cancelled between iterations. This is the same safety net as the exit during backoff.
        if connections[identifier] == nil {
            finishDormantNotificationsWithRecordedError(for: identifier)
        }
        clearReconnectLoopIfCurrent(id: identifier, generation: generation)
    }

    /// Calls ``finishDormantNotifications(for:error:)`` with the disconnect error that the
    /// record stores, because the reconnect loop's exits have no error of their own. It never
    /// touches a record while `identifier` has a live entry, because a successful reconnect
    /// owns the record. It does nothing if no record exists.
    private func finishDormantNotificationsWithRecordedError(for identifier: PeripheralIdentifier) {
        guard connections[identifier] == nil, let record = dormantNotifications[identifier] else { return }
        finishDormantNotifications(for: identifier, error: record.disconnectError)
    }

    // MARK: - Event handling

    /// Updates the actor state and fans out the matching public events for a `CentralEvent`.
    /// ``CentralDelegateProxy`` or a test fake forwards the event here.
    func handle(_ event: CentralEvent) {
        switch event {
        case .didUpdateState(let newState):
            let previousState = stateBox.withLock { $0 }
            stateBox.withLock { $0 = newState }
            stateBroadcaster.yield(newState)

            log("Bluetooth state changed: \(previousState) -> \(newState)", level: .info, category: "state")

            if previousState == .poweredOn, newState != .poweredOn {
                failAllPendingOperations(error: .bluetoothUnavailable)
                handleBluetoothUnavailable()
            }

            handleRestorationStateChange(newState)

        case .didDiscover(let peripheral, let advertisement, let rssi):
            handleDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: rssi)

        case .didConnect(let identifier):
            guard case .connecting(var connecting) = connections[identifier] else {
                log("Ignoring didConnect for untracked peripheral \(identifier)", level: .warning, category: "connection")
                return
            }

            // A `didConnect` always means success, even for an attempt marked `stopping`,
            // because CoreBluetooth won the race.
            let continuation = connecting.continuation
            connecting.continuation = nil
            let policy = connecting.policy
            let timeout = connecting.timeout
            let warningOptions = connecting.warningOptions
            let target = connecting.peripheral

            connections[identifier] = .connected(Session(identifier: identifier, peripheral: target, policy: policy, timeout: timeout, warningOptions: warningOptions, compatibility: connecting.compatibility, requiresANCS: connecting.requiresANCS))

            log("Connected to \(identifier)", level: .info, category: "connection")
            connectionBroadcaster.yield(.connected(identifier))
            continuation?.resume(returning: Peripheral(id: identifier, central: self))

            // A reconnect with parked notification survivors: re-arm them. This is a ledgered
            // `Task` site. It is stored on the session. `failPendingGATTContinuations` cancels it.
            if dormantNotifications[identifier] != nil,
               case .connected(var connectedSession) = connections[identifier] {
                connectedSession.rearmTask = Task { [weak self] in
                    await self?.rearmDormantNotifications(identifier)
                }
                connections[identifier] = .connected(connectedSession)
            }

        case .didFailToConnect(let identifier, let error):
            // Same cleanup path as `didDisconnect`.
            handleTermination(identifier: identifier, error: error)

        case .didDisconnect(let identifier, let error):
            handleTermination(identifier: identifier, error: error)

        #if !os(macOS)
        case .connectionEventDidOccur(let peripheralUUID, let kind):
            let event = SystemConnectionEvent(
                peripheral: PeripheralIdentifier(uuid: peripheralUUID, name: nil),
                kind: kind
            )
            for continuation in connectionEventSubscribers.values {
                continuation.yield(event)
            }
        #else
        case .connectionEventDidOccur:
            break
        #endif

        #if os(iOS)
        case .didUpdateANCSAuthorization(let peripheralUUID, let authorized):
            ancsAuthorizationRegistry
                .broadcaster(for: PeripheralIdentifier(uuid: peripheralUUID, name: nil))
                .yield(authorized)
        #else
        case .didUpdateANCSAuthorization:
            break
        #endif

        case .willRestoreState(let restored):
            // Set up each restored peripheral's event delivery now, before the `.poweredOn`
            // routing adopts or reconnects it. Otherwise, a notification from a surviving listen
            // would have nowhere to go.
            for restoredPeripheral in restored.peripherals {
                let peripheralIdentifier = restoredPeripheral.identifier
                guard let target = manager?.retrievePeripherals(withIdentifiers: [peripheralIdentifier.uuid]).first else {
                    continue
                }
                target.eventHandler = { [weak self] event in
                    guard let self else { return }
                    self.assumeIsolated(onQueue: self.queue) { $0.handle(event, from: peripheralIdentifier) }
                }
            }

            // Stage the restored state until the radio's first `.poweredOn` routes it. The
            // broadcaster buffers and replays `.willRestore`, so a later subscriber still sees it.
            pendingRestoration = restored
            restorationBroadcaster.yield(.willRestore(restored))
            log("Will restore state: \(restored.peripherals.count) peripheral(s)", level: .info, category: "restore")
        }
    }

    /// Handles a `PeripheralEvent`. ``PeripheralDelegateProxy`` or a test fake forwards the
    /// event here. It routes GATT completions to their pending continuations (removes, then
    /// resumes) and `didModifyServices` to ``serviceChangesRegistry``, keyed by `peripheral`.
    func handle(_ event: PeripheralEvent, from peripheral: PeripheralIdentifier) {
        switch event {
        case .didDiscoverServices(let error):
            resumeDiscoverServicesWaiters(for: peripheral, error: error)

        case .didDiscoverCharacteristics(let service, let error):
            resumeDiscoverCharacteristicsWaiters(service: service, for: peripheral, error: error)

        case .didWriteValue(let characteristic, let error):
            resumePendingWrite(characteristic: characteristic, for: peripheral, error: error)

        case .didUpdateValue(let characteristic, let value, let error):
            handleDidUpdateValue(characteristic: characteristic, value: value, error: error, from: peripheral)

        case .didUpdateNotificationState(let characteristic, let isNotifying, let error):
            resumePendingNotifyStateChange(characteristic: characteristic, isNotifying: isNotifying, for: peripheral, error: error)

        case .didDiscoverDescriptors(let characteristic, let error):
            resumeDiscoverDescriptorsWaiters(characteristic: characteristic, for: peripheral, error: error)

        case .didUpdateValueForDescriptor(let descriptor, let value, let error):
            resumePendingDescriptorRead(descriptor: descriptor, value: value, for: peripheral, error: error)

        case .didWriteValueForDescriptor(let descriptor, let error):
            resumePendingDescriptorWrite(descriptor: descriptor, for: peripheral, error: error)

        case .didReadRSSI(let rssi, let error):
            resumePendingRSSIRead(rssi: rssi, for: peripheral, error: error)

        case .didModifyServices(let invalidatedServices):
            // There is no actor-level discovery cache. `isDiscovered(_:)` uses CoreBluetooth's
            // service graph, which CoreBluetooth already prunes on `didModifyServices`.
            log("Services modified/invalidated: \(invalidatedServices)", level: .info, category: "gatt")
            // Reset the enumeration caches that the invalidation touched, so a later enumeration
            // discovers anything new.
            if case .connected(var session) = connections[peripheral] {
                session.didEnumerateServices = false
                session.enumeratedCharacteristicServices.subtract(invalidatedServices)
                session.enumeratedDescriptorCharacteristics = session.enumeratedDescriptorCharacteristics
                    .filter { !invalidatedServices.contains($0.service) }
                connections[peripheral] = .connected(session)
            }
            serviceChangesRegistry.broadcaster(for: peripheral).yield(invalidatedServices)

        case .isReadyToSendWriteWithoutResponse:
            resumeWriteWithoutResponseWaiters(for: peripheral)

        case .didOpenL2CAPChannel(let channel, let error):
            resumePendingL2CAPOpen(for: peripheral, channel: channel, error: error)
        }
    }

    // MARK: - GATT event routing

    /// Removes and resumes every waiter in `session.pendingDiscoverServices`. The waiters are
    /// not per service, because `didDiscoverServices(error:)` carries no service identifier.
    /// Every waiter resumes on any completion and then checks its own service again.
    private func resumeDiscoverServicesWaiters(for peripheralIdentifier: PeripheralIdentifier, error: NSError?) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring didDiscoverServices for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        let waiters = session.pendingDiscoverServices
        session.pendingDiscoverServices.removeAll()
        connections[peripheralIdentifier] = .connected(session)
        for waiter in waiters.values {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: ())
            }
        }
    }

    /// Removes a single service-discovery waiter by token and resumes it with
    /// ``BLESwiftError/operationCancelled``. It handles the waiter's cancellation, not a real
    /// completion.
    private func cancelDiscoverServicesWaiter(identifier: PeripheralIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDiscoverServices.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Removes and resumes every waiter for `service` in `pendingDiscoverCharacteristics`. These
    /// waiters are keyed by service, because `didDiscoverCharacteristics` carries it.
    private func resumeDiscoverCharacteristicsWaiters(service: ServiceIdentifier, for peripheralIdentifier: PeripheralIdentifier, error: NSError?) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring didDiscoverCharacteristics for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        let waiters = session.pendingDiscoverCharacteristics.removeValue(forKey: service) ?? [:]
        connections[peripheralIdentifier] = .connected(session)
        for waiter in waiters.values {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: ())
            }
        }
    }

    /// Removes a single characteristic-discovery waiter by service and token and resumes it
    /// with ``BLESwiftError/operationCancelled``. See
    /// ``cancelDiscoverServicesWaiter(identifier:token:)``.
    private func cancelDiscoverCharacteristicsWaiter(identifier: PeripheralIdentifier, service: ServiceIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDiscoverCharacteristics[service]?.removeValue(forKey: token) else { return }
        if session.pendingDiscoverCharacteristics[service]?.isEmpty == true {
            session.pendingDiscoverCharacteristics.removeValue(forKey: service)
        }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Removes and resumes every waiter for `characteristic` in `pendingDiscoverDescriptors`.
    /// The keys work like those of ``resumeDiscoverCharacteristicsWaiters(service:for:error:)``.
    private func resumeDiscoverDescriptorsWaiters(characteristic: CharacteristicIdentifier, for peripheralIdentifier: PeripheralIdentifier, error: NSError?) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring didDiscoverDescriptors for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        let waiters = session.pendingDiscoverDescriptors.removeValue(forKey: characteristic) ?? [:]
        connections[peripheralIdentifier] = .connected(session)
        for waiter in waiters.values {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: ())
            }
        }
    }

    /// Removes a single descriptor-discovery waiter by characteristic and token and resumes it
    /// with ``BLESwiftError/operationCancelled``. See
    /// ``cancelDiscoverCharacteristicsWaiter(identifier:service:token:)``.
    private func cancelDiscoverDescriptorsWaiter(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDiscoverDescriptors[characteristic]?.removeValue(forKey: token) else { return }
        if session.pendingDiscoverDescriptors[characteristic]?.isEmpty == true {
            session.pendingDiscoverDescriptors.removeValue(forKey: characteristic)
        }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Removes and resumes the pending write continuation for `characteristic`, if any. Only
    /// one slot exists, because the per-characteristic FIFO guarantees it.
    private func resumePendingWrite(characteristic: CharacteristicIdentifier, for peripheralIdentifier: PeripheralIdentifier, error: NSError?) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring didWriteValue for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        guard let continuation = session.pendingWrites.removeValue(forKey: characteristic) else {
            log("Ignoring didWriteValue for \(characteristic) with no pending write", level: .debug, category: "gatt")
            return
        }
        connections[peripheralIdentifier] = .connected(session)
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }

    /// Removes the pending write continuation for `characteristic`, if still pending, and
    /// resumes it with ``BLESwiftError/operationCancelled``. It handles a task cancellation or
    /// `withTimeout` timeout, not a real `didWriteValue` completion.
    private func cancelPendingWrite(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingWrites.removeValue(forKey: characteristic) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Removes and resumes the pending notify-state-change continuation for `characteristic`,
    /// if any.
    private func resumePendingNotifyStateChange(characteristic: CharacteristicIdentifier, isNotifying: Bool, for peripheralIdentifier: PeripheralIdentifier, error: NSError?) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring didUpdateNotificationState for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        guard let continuation = session.pendingNotifyStateChanges.removeValue(forKey: characteristic) else {
            connections[peripheralIdentifier] = .connected(session)
            return
        }
        connections[peripheralIdentifier] = .connected(session)
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: isNotifying)
        }
    }

    /// Removes and resumes the pending RSSI-read continuation, if any. Only one slot exists,
    /// because the tail chain of ``runRSSISerialized(identifier:operation:)`` guarantees it.
    private func resumePendingRSSIRead(rssi: Int, for peripheralIdentifier: PeripheralIdentifier, error: NSError?) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring didReadRSSI for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        guard let continuation = session.pendingRSSIRead else {
            log("Ignoring didReadRSSI with no pending read", level: .debug, category: "gatt")
            return
        }
        session.pendingRSSIRead = nil
        connections[peripheralIdentifier] = .connected(session)
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: rssi)
        }
    }

    /// Removes the pending RSSI-read continuation, if still pending, and resumes it with
    /// ``BLESwiftError/operationCancelled``. See
    /// ``cancelPendingWrite(identifier:characteristic:)``.
    private func cancelPendingRSSIRead(identifier: PeripheralIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingRSSIRead else { return }
        session.pendingRSSIRead = nil
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Removes and resumes every waiter in `pendingWriteWithoutResponseReady`. The waiters are
    /// not keyed by characteristic, because CoreBluetooth's readiness signal is peripheral-wide.
    private func resumeWriteWithoutResponseWaiters(for peripheralIdentifier: PeripheralIdentifier) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring isReadyToSendWriteWithoutResponse for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        let waiters = session.pendingWriteWithoutResponseReady
        session.pendingWriteWithoutResponseReady.removeAll()
        connections[peripheralIdentifier] = .connected(session)
        for waiter in waiters.values {
            waiter.resume(returning: ())
        }
    }

    /// Removes a single write-without-response-readiness waiter by token and resumes it with
    /// ``BLESwiftError/operationCancelled``. See
    /// ``cancelDiscoverServicesWaiter(identifier:token:)``.
    private func cancelWriteWithoutResponseWaiter(identifier: PeripheralIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingWriteWithoutResponseReady.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Routes a `didUpdateValueFor` delivery. The first match in this order consumes it:
    /// 1. An active notification subscription.
    /// 2. A pending read continuation.
    /// 3. With restoration enabled, the restoration "unhandled listen" surface.
    /// 4. Otherwise, a log line.
    ///
    /// A `didUpdateValue` error on a notifying characteristic finishes that subscription with
    /// the error.
    private func handleDidUpdateValue(characteristic: CharacteristicIdentifier, value: Data?, error: NSError?, from peripheralIdentifier: PeripheralIdentifier) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            // Between `willRestoreState` and `.poweredOn`, a restored peripheral that is not yet
            // routed can already be notifying. Surface the value on the restoration stream and
            // do not drop it as "untracked".
            if let pending = pendingRestoration,
               pending.peripherals.contains(where: { $0.identifier == peripheralIdentifier }) {
                restorationBroadcaster.yield(.unhandledNotification(peripheralIdentifier, characteristic, value))
                log("Value update from restored (not yet routed) peripheral \(peripheralIdentifier) surfaced on restorationEvents()", level: .info, category: "restore")
                return
            }
            log("Ignoring didUpdateValue for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }

        if let subscription = session.notificationSubscriptions[characteristic] {
            connections[peripheralIdentifier] = .connected(session)
            if let error {
                failNotificationSubscription(identifier: peripheralIdentifier, characteristic: characteristic, error: error)
            } else {
                // A `nil` value yields empty `Data`, as in the pending-read path below.
                subscription.broadcaster.yield(value ?? Data())
            }
            return
        }

        if let continuation = session.pendingReads.removeValue(forKey: characteristic) {
            connections[peripheralIdentifier] = .connected(session)
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: value ?? Data())
            }
            return
        }

        connections[peripheralIdentifier] = .connected(session)
        if configuration.restoration != nil {
            // The restoration "unhandled listen" surface applies only when restoration is enabled.
            restorationBroadcaster.yield(.unhandledNotification(peripheralIdentifier, characteristic, value))
            log("Unhandled value update for \(characteristic) surfaced on restorationEvents()", level: .info, category: "restore")
        } else {
            log("Unhandled value update for \(characteristic) with no active notification subscriber or pending read", level: .debug, category: "gatt")
        }
    }

    /// Removes the pending read continuation for `characteristic`, if still pending, and
    /// resumes it with ``BLESwiftError/operationCancelled``. It handles a task cancellation or
    /// `withTimeout` timeout, not a real `didUpdateValue` completion.
    private func cancelPendingRead(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingReads.removeValue(forKey: characteristic) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Removes and resumes the pending descriptor-read continuation for `descriptor`, if any.
    /// Only one slot exists, because the parent characteristic's FIFO guarantees it.
    private func resumePendingDescriptorRead(descriptor: DescriptorIdentifier, value: Data?, for peripheralIdentifier: PeripheralIdentifier, error: NSError?) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring didUpdateValueForDescriptor for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        guard let continuation = session.pendingDescriptorReads.removeValue(forKey: descriptor) else {
            log("Ignoring didUpdateValueForDescriptor for \(descriptor) with no pending read", level: .debug, category: "gatt")
            return
        }
        connections[peripheralIdentifier] = .connected(session)
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: value ?? Data())
        }
    }

    /// Removes the pending descriptor-read continuation for `descriptor`, if still pending,
    /// and resumes it with ``BLESwiftError/operationCancelled``. It handles a task
    /// cancellation or `withTimeout` timeout, not a real `didUpdateValueForDescriptor`
    /// completion.
    private func cancelPendingDescriptorRead(identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDescriptorReads.removeValue(forKey: descriptor) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Removes and resumes the pending descriptor-write continuation for `descriptor`, if any.
    /// Only one slot exists, because the parent characteristic's FIFO guarantees it.
    private func resumePendingDescriptorWrite(descriptor: DescriptorIdentifier, for peripheralIdentifier: PeripheralIdentifier, error: NSError?) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            log("Ignoring didWriteValueForDescriptor for untracked peripheral \(peripheralIdentifier)", level: .debug, category: "gatt")
            return
        }
        guard let continuation = session.pendingDescriptorWrites.removeValue(forKey: descriptor) else {
            log("Ignoring didWriteValueForDescriptor for \(descriptor) with no pending write", level: .debug, category: "gatt")
            return
        }
        connections[peripheralIdentifier] = .connected(session)
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }

    /// Removes the pending descriptor-write continuation for `descriptor`, if still pending,
    /// and resumes it with ``BLESwiftError/operationCancelled``. See
    /// ``cancelPendingDescriptorRead(identifier:descriptor:)``.
    private func cancelPendingDescriptorWrite(identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDescriptorWrites.removeValue(forKey: descriptor) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    // MARK: - GATT operations

    /// Reads the current value of `characteristic`. `Peripheral.read(from:timeout:)` calls it.
    /// It wraps the discovery-then-read sequence in `timeout` (``BLESwiftError/timedOut``) and
    /// orders it against other operations on the same characteristic.
    func performRead(peripheral identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, timeout: Duration?) async throws -> Data {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.timedOut) {
            try await self.runOnFIFO(identifier: identifier, characteristic: characteristic) {
                try await self.performReadNow(identifier: identifier, characteristic: characteristic)
            }
        }
    }

    /// The discovery-then-read sequence of ``performRead(peripheral:characteristic:timeout:)``,
    /// inside the FIFO chain of `characteristic`.
    private func performReadNow(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) async throws -> Data {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        // Throw an error and do not crash when a read happens while the characteristic listens.
        // CoreBluetooth cannot tell a read completion from a notification.
        if peripheral.isNotifying(characteristic) {
            throw BLESwiftError.readConflictsWithNotification
        }

        try await ensureDiscovered(characteristic, on: peripheral, identifier: identifier)
        try requireProperty(
            [.read],
            operation: .read,
            on: characteristic,
            peripheral: peripheral,
            identifier: identifier,
            bypass: session.compatibility.allowReadWithoutProperty
        )

        return try await withCancellableGATTContinuation(
            register: { continuation in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                session.pendingReads[characteristic] = continuation
                connections[identifier] = .connected(session)
                peripheral.readValue(for: characteristic)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.cancelPendingRead(identifier: identifier, characteristic: characteristic)
                    }
                }
            }
        )
    }

    /// Reports the operations that `characteristic` supports. `Peripheral.properties(of:)`
    /// calls it. It discovers the characteristic lazily and reads its properties directly, so
    /// it needs no completion continuation.
    func properties(peripheral identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) async throws -> CharacteristicProperties {
        try await runOnFIFO(identifier: identifier, characteristic: characteristic) {
            try await self.propertiesNow(identifier: identifier, characteristic: characteristic)
        }
    }

    /// The discovery-then-introspect sequence of ``properties(peripheral:characteristic:)``,
    /// inside the FIFO chain of `characteristic`.
    private func propertiesNow(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) async throws -> CharacteristicProperties {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        try await ensureDiscovered(characteristic, on: peripheral, identifier: identifier)

        return peripheral.properties(of: characteristic)
    }

    /// Writes `data` to `characteristic`. `Peripheral.write(_:to:type:timeout:)` calls it. It
    /// uses the same timeout and FIFO as ``performRead(peripheral:characteristic:timeout:)``.
    func performWrite(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        data: Data,
        type: WriteType,
        timeout: Duration?
    ) async throws {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.timedOut) {
            try await self.runOnFIFO(identifier: identifier, characteristic: characteristic) {
                try await self.performWriteNow(identifier: identifier, characteristic: characteristic, data: data, type: type)
            }
        }
    }

    /// Backs `Peripheral.writeChunked(...)`. It holds the FIFO lane of `characteristic` for the
    /// whole `chunks` sequence (one ``runOnFIFO(identifier:characteristic:operation:)`` job),
    /// so no other write can interleave between chunks. Each chunk uses
    /// ``performWriteNow(identifier:characteristic:data:type:)``, like a normal
    /// ``performWrite(peripheral:characteristic:data:type:timeout:)``: back-pressure for
    /// `.withoutResponse`, and a wait for `didWriteValueFor` for `.withResponse`. `timeout`
    /// applies **per chunk**. `progress` runs after each chunk with the cumulative `bytesSent`.
    /// An empty `chunks` performs no writes and reports a single `(0, totalBytes)`.
    func performChunkedWrite(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        chunks: [Data],
        totalBytes: Int,
        type: WriteType,
        timeout: Duration?,
        progress: @Sendable (WriteProgress) -> Void
    ) async throws {
        guard !chunks.isEmpty else {
            progress(WriteProgress(bytesSent: 0, totalBytes: totalBytes))
            return
        }

        try await runOnFIFO(identifier: identifier, characteristic: characteristic) {
            var bytesSent = 0
            for chunk in chunks {
                // A cancel between chunks stops the sequence while this code holds the FIFO lane.
                // The caller must handle a partially sent payload.
                if Task.isCancelled { throw BLESwiftError.operationCancelled }
                try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.timedOut) {
                    try await self.performWriteNow(
                        identifier: identifier,
                        characteristic: characteristic,
                        data: chunk,
                        type: type
                    )
                }
                bytesSent += chunk.count
                progress(WriteProgress(bytesSent: bytesSent, totalBytes: totalBytes))
            }
        }
    }

    /// The discovery-then-write sequence of
    /// ``performWrite(peripheral:characteristic:data:type:timeout:)``.
    ///
    /// `.withoutResponse` completes immediately, because CoreBluetooth delivers no
    /// `didWriteValueFor` for it. It first waits for `canSendWriteWithoutResponse`, because
    /// CoreBluetooth would otherwise drop the payload.
    private func performWriteNow(
        identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        data: Data,
        type: WriteType
    ) async throws {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        try await ensureDiscovered(characteristic, on: peripheral, identifier: identifier)
        try requireProperty(
            type == .withoutResponse ? [.writeWithoutResponse] : [.write],
            operation: .write,
            on: characteristic,
            peripheral: peripheral,
            identifier: identifier,
            bypass: session.compatibility.allowWriteWithoutProperty
        )

        if type == .withoutResponse {
            try await awaitWriteWithoutResponseReadiness(peripheral: peripheral, identifier: identifier)
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            return
        }

        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                session.pendingWrites[characteristic] = continuation
                connections[identifier] = .connected(session)
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.cancelPendingWrite(identifier: identifier, characteristic: characteristic)
                    }
                }
            }
        )
    }

    /// Waits until `peripheral.canSendWriteWithoutResponse` is `true`, CoreBluetooth's
    /// back-pressure signal for `.withoutResponse` writes. It returns at once if the value is
    /// already `true`. The signal is peripheral-wide, and every waiter resumes on the next one.
    private func awaitWriteWithoutResponseReadiness(peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        if peripheral.canSendWriteWithoutResponse { return }

        // `Mutex`-boxed and not a plain `var`, so `register` (actor-isolated) can write it and
        // `onCancelled` (a `@Sendable` closure) can read it. Swift 6 rejects a mutable local
        // that is captured across that boundary.
        let assignedToken = Mutex<UInt64?>(nil)
        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                let token = session.nextGATTWaiterToken()
                assignedToken.withLock { $0 = token }
                session.pendingWriteWithoutResponseReady[token] = continuation
                connections[identifier] = .connected(session)
            },
            onCancelled: {
                // `assignedToken` is always set when this fires, because `register` runs
                // synchronously before a cancellation can be observed.
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelWriteWithoutResponseWaiter(identifier: identifier, token: token)
                    }
                }
            }
        )
    }

    /// Reads the current value of `descriptor`. `Peripheral.readDescriptor(_:timeout:)` calls
    /// it. It runs in the FIFO lane of the *parent characteristic*, so a descriptor operation
    /// never races a characteristic operation on it.
    func performReadDescriptor(peripheral identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier, timeout: Duration?) async throws -> Data {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.timedOut) {
            try await self.runOnFIFO(identifier: identifier, characteristic: descriptor.characteristic) {
                try await self.performReadDescriptorNow(identifier: identifier, descriptor: descriptor)
            }
        }
    }

    /// The discovery-then-read sequence of
    /// ``performReadDescriptor(peripheral:descriptor:timeout:)``, inside the parent
    /// characteristic's FIFO chain.
    private func performReadDescriptorNow(identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier) async throws -> Data {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        try await ensureDescriptorDiscovered(descriptor, on: peripheral, identifier: identifier)

        return try await withCancellableGATTContinuation(
            register: { continuation in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                session.pendingDescriptorReads[descriptor] = continuation
                connections[identifier] = .connected(session)
                peripheral.readValue(for: descriptor)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.cancelPendingDescriptorRead(identifier: identifier, descriptor: descriptor)
                    }
                }
            }
        )
    }

    /// Writes `data` to `descriptor`. `Peripheral.writeDescriptor(_:value:timeout:)` calls it.
    /// It always writes with a response, because a `CBDescriptor` write has no write type.
    func performWriteDescriptor(peripheral identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier, data: Data, timeout: Duration?) async throws {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.timedOut) {
            try await self.runOnFIFO(identifier: identifier, characteristic: descriptor.characteristic) {
                try await self.performWriteDescriptorNow(identifier: identifier, descriptor: descriptor, data: data)
            }
        }
    }

    /// The discovery-then-write sequence of
    /// ``performWriteDescriptor(peripheral:descriptor:data:timeout:)``, inside the parent
    /// characteristic's FIFO chain.
    private func performWriteDescriptorNow(identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier, data: Data) async throws {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        try await ensureDescriptorDiscovered(descriptor, on: peripheral, identifier: identifier)

        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                session.pendingDescriptorWrites[descriptor] = continuation
                connections[identifier] = .connected(session)
                peripheral.writeValue(data, for: descriptor)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.cancelPendingDescriptorWrite(identifier: identifier, descriptor: descriptor)
                    }
                }
            }
        )
    }

    /// Reads the current RSSI of the peripheral. `Peripheral.readRSSI(timeout:)` calls it. RSSI
    /// has no characteristic, so it runs through its own single tail and not the
    /// per-characteristic FIFO map.
    func performReadRSSI(peripheral identifier: PeripheralIdentifier, timeout: Duration?) async throws -> Int {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.timedOut) {
            try await self.runRSSISerialized(identifier: identifier) {
                try await self.performReadRSSINow(identifier: identifier)
            }
        }
    }

    /// The RSSI read of ``performReadRSSI(peripheral:timeout:)``, inside the RSSI tail chain.
    private func performReadRSSINow(identifier: PeripheralIdentifier) async throws -> Int {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        return try await withCancellableGATTContinuation(
            register: { continuation in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                session.pendingRSSIRead = continuation
                connections[identifier] = .connected(session)
                peripheral.readRSSI()
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.cancelPendingRSSIRead(identifier: identifier)
                    }
                }
            }
        )
    }

    /// The maximum payload length, in bytes, for a single write of `type`.
    /// `Peripheral.maximumWriteValueLength(for:)` calls it. It never throws. It returns
    /// ``Central/defaultMaximumWriteValueLength`` if `identifier` is not connected.
    func maximumWriteValueLength(peripheral identifier: PeripheralIdentifier, for type: WriteType) -> Int {
        guard case .connected(let session) = connections[identifier] else {
            return Central.defaultMaximumWriteValueLength
        }
        return session.peripheral.maximumWriteValueLength(for: type)
    }

    /// The fallback when no connected peripheral can answer: the classic ATT_MTU-3 default,
    /// which is the 23-byte default ATT_MTU minus the 3-byte write-request header.
    static let defaultMaximumWriteValueLength = 20

    // MARK: - Property enforcement

    /// Throws ``BLESwiftError/unsupportedCharacteristicOperation(_:required:)`` when the
    /// advertised properties of `characteristic` include none of `required`. If `bypass` (from
    /// the session's ``GATTCompatibility``) is set, it skips a check that fails and logs a
    /// warning once for each (peripheral, characteristic, operation). Run it AFTER lazy
    /// discovery, because the properties are known only then.
    private func requireProperty(
        _ required: CharacteristicProperties,
        operation: CompatOperation,
        on characteristic: CharacteristicIdentifier,
        peripheral: any PeripheralRemote,
        identifier: PeripheralIdentifier,
        bypass: Bool
    ) throws {
        let properties = peripheral.properties(of: characteristic)
        guard properties.isDisjoint(with: required) else { return }
        guard bypass else {
            throw BLESwiftError.unsupportedCharacteristicOperation(characteristic, required: required)
        }
        let key = CompatWarnKey(peripheral: identifier, characteristic: characteristic, operation: operation)
        if warnedCompatBypass.insert(key).inserted {
            log("Compatibility bypass: \(operation) on \(characteristic) despite missing \(required) property", level: .warning, category: "gatt")
        }
    }

    // MARK: - Lazy discovery

    /// Ensures that `characteristic` (and its service) is discovered on `peripheral`. It
    /// returns early when the shim's `isDiscovered(_:)` is true, because CoreBluetooth's graph
    /// IS the cache.
    ///
    /// - Throws: ``BLESwiftError/missingService(_:)`` or
    ///   ``BLESwiftError/missingCharacteristic(_:)`` if the item is still not discovered after
    ///   discovery completes, and any error that CoreBluetooth reports.
    private func ensureDiscovered(_ characteristic: CharacteristicIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        try await ensureServiceDiscovered(characteristic.service, on: peripheral, identifier: identifier)
        try await ensureCharacteristicDiscovered(characteristic, on: peripheral, identifier: identifier)
    }

    /// Ensures that `service` is discovered. It calls `discoverServices(_:)` and waits for its
    /// completion only if `peripheral.isDiscovered(service)` is false. See
    /// ``ensureDiscovered(_:on:identifier:)``.
    private func ensureServiceDiscovered(_ service: ServiceIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        guard !peripheral.isDiscovered(service) else { return }

        // `.all` discovery replaces the targeted call with ONE `discoverServices(nil)` for each
        // connection, cached on the session (`didDiscoverAllServices`). It serves modules that
        // fill their GATT table only under unfiltered discovery.
        if case .connected(let session) = connections[identifier], session.compatibility.discovery == .all {
            if !session.didDiscoverAllServices {
                try await awaitDiscoverAllServices(on: peripheral, identifier: identifier)
                // Read the entry again, because the await suspended. Do not write a stale copy.
                guard case .connected(var refreshed) = connections[identifier] else {
                    throw BLESwiftError.notConnected
                }
                refreshed.didDiscoverAllServices = true
                connections[identifier] = .connected(refreshed)
            }
            guard peripheral.isDiscovered(service) else {
                throw BLESwiftError.missingService(service)
            }
            return
        }

        // `Mutex`-boxed for the reason given in `awaitWriteWithoutResponseReadiness`.
        let assignedToken = Mutex<UInt64?>(nil)
        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                let token = session.nextGATTWaiterToken()
                assignedToken.withLock { $0 = token }
                session.pendingDiscoverServices[token] = continuation
                connections[identifier] = .connected(session)
                peripheral.discoverServices([service])
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverServicesWaiter(identifier: identifier, token: token)
                    }
                }
            }
        )

        guard peripheral.isDiscovered(service) else {
            throw BLESwiftError.missingService(service)
        }
    }

    /// Ensures that `characteristic` is discovered. It calls `discoverCharacteristics(_:for:)`
    /// and waits for its completion only if the characteristic is not discovered. See
    /// ``ensureDiscovered(_:on:identifier:)``.
    private func ensureCharacteristicDiscovered(_ characteristic: CharacteristicIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        guard !peripheral.isDiscovered(characteristic) else { return }

        // `Mutex`-boxed for the reason given in `awaitWriteWithoutResponseReadiness`.
        let assignedToken = Mutex<UInt64?>(nil)
        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                let token = session.nextGATTWaiterToken()
                assignedToken.withLock { $0 = token }
                session.pendingDiscoverCharacteristics[characteristic.service, default: [:]][token] = continuation
                connections[identifier] = .connected(session)
                peripheral.discoverCharacteristics([characteristic], for: characteristic.service)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverCharacteristicsWaiter(identifier: identifier, service: characteristic.service, token: token)
                    }
                }
            }
        )

        guard peripheral.isDiscovered(characteristic) else {
            throw BLESwiftError.missingCharacteristic(characteristic)
        }
    }

    /// Ensures that `descriptor` (and its characteristic and service) is discovered on
    /// `peripheral`. It extends the lazy discovery chain by one level.
    ///
    /// - Throws: Any error that ``ensureDiscovered(_:on:identifier:)`` throws, and
    ///   ``BLESwiftError/missingDescriptor(_:)`` if the descriptor is still not discovered.
    private func ensureDescriptorDiscovered(_ descriptor: DescriptorIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        try await ensureDiscovered(descriptor.characteristic, on: peripheral, identifier: identifier)
        try await ensureDescriptorsDiscovered(descriptor, on: peripheral, identifier: identifier)
    }

    /// Ensures that `descriptor` is discovered. If needed, it calls `discoverDescriptors(for:)`
    /// on the descriptor's characteristic. Descriptors have no filter and are always discovered
    /// as a group, so an undiscovered descriptor triggers a full new discovery.
    private func ensureDescriptorsDiscovered(_ descriptor: DescriptorIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        guard !peripheral.isDiscovered(descriptor) else { return }

        // `Mutex`-boxed for the reason given in `awaitWriteWithoutResponseReadiness`.
        let assignedToken = Mutex<UInt64?>(nil)
        let characteristic = descriptor.characteristic
        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                let token = session.nextGATTWaiterToken()
                assignedToken.withLock { $0 = token }
                session.pendingDiscoverDescriptors[characteristic, default: [:]][token] = continuation
                connections[identifier] = .connected(session)
                peripheral.discoverDescriptors(for: characteristic)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverDescriptorsWaiter(identifier: identifier, characteristic: characteristic, token: token)
                    }
                }
            }
        )

        guard peripheral.isDiscovered(descriptor) else {
            throw BLESwiftError.missingDescriptor(descriptor)
        }
    }

    // MARK: - GATT enumeration

    /// Lists the services of `identifier`. If they are not enumerated yet, it first discovers
    /// them (`discoverServices(nil)`). `Peripheral.discoverServices()` calls it.
    ///
    /// The result is cached for each connection (``Session/didEnumerateServices``) until a
    /// `didModifyServices` invalidation resets it.
    ///
    /// - Throws: ``BLESwiftError/notConnected``, ``BLESwiftError/operationCancelled`` on task
    ///   cancellation, or any error that CoreBluetooth reports.
    func enumerateServices(peripheral identifier: PeripheralIdentifier) async throws -> [ServiceIdentifier] {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        if !session.didEnumerateServices {
            try await awaitDiscoverAllServices(on: peripheral, identifier: identifier)
            // Read the entry again. The await suspended, so the session may be torn down and
            // rebuilt. Do not write back a stale copy.
            guard case .connected(var refreshed) = connections[identifier] else {
                throw BLESwiftError.notConnected
            }
            refreshed.didEnumerateServices = true
            connections[identifier] = .connected(refreshed)
        }

        return peripheral.discoveredServices
    }

    /// Lists the characteristics of `service` on `identifier`. The first time, it discovers the
    /// service (if needed) and then all of its characteristics.
    /// `Peripheral.discoverCharacteristics(for:)` calls it.
    ///
    /// The result is cached for each service (``Session/enumeratedCharacteristicServices``)
    /// until an invalidation.
    ///
    /// - Throws: ``BLESwiftError/notConnected``, ``BLESwiftError/missingService(_:)``,
    ///   ``BLESwiftError/operationCancelled``, or any error that CoreBluetooth reports.
    func enumerateCharacteristics(
        peripheral identifier: PeripheralIdentifier,
        service: ServiceIdentifier
    ) async throws -> [CharacteristicIdentifier] {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        // Discover the service first. A real `discoverCharacteristics(_:for:)` does nothing,
        // with no error, on an undiscovered service. This call also gives `.missingService`.
        try await ensureServiceDiscovered(service, on: peripheral, identifier: identifier)

        guard case .connected(let refreshed) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        if !refreshed.enumeratedCharacteristicServices.contains(service) {
            try await awaitDiscoverAllCharacteristics(service: service, on: peripheral, identifier: identifier)
            guard case .connected(var updated) = connections[identifier] else {
                throw BLESwiftError.notConnected
            }
            updated.enumeratedCharacteristicServices.insert(service)
            connections[identifier] = .connected(updated)
        }

        return peripheral.discoveredCharacteristics(for: service)
    }

    /// Lists the descriptors of `characteristic` on `identifier`. It discovers the service and
    /// characteristic (if needed) and then the descriptors.
    /// `Peripheral.discoverDescriptors(for:)` calls it.
    ///
    /// The result is cached for each characteristic
    /// (``Session/enumeratedDescriptorCharacteristics``).
    ///
    /// - Throws: ``BLESwiftError/notConnected``, any error that discovering the characteristic
    ///   throws, ``BLESwiftError/operationCancelled``, or any error that CoreBluetooth reports.
    func enumerateDescriptors(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier
    ) async throws -> [DescriptorIdentifier] {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        // Discover the service and characteristic first. This does nothing if already discovered.
        try await ensureDiscovered(characteristic, on: peripheral, identifier: identifier)

        guard case .connected(let refreshed) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        if !refreshed.enumeratedDescriptorCharacteristics.contains(characteristic) {
            try await awaitDiscoverAllDescriptors(characteristic: characteristic, on: peripheral, identifier: identifier)
            guard case .connected(var updated) = connections[identifier] else {
                throw BLESwiftError.notConnected
            }
            updated.enumeratedDescriptorCharacteristics.insert(characteristic)
            connections[identifier] = .connected(updated)
        }

        return peripheral.discoveredDescriptors(for: characteristic)
    }

    /// Issues `discoverServices(nil)` (discover all) and suspends until ``handle(_:from:)``
    /// resolves it. It works like ``ensureServiceDiscovered(_:on:identifier:)`` except for the
    /// `nil` filter.
    private func awaitDiscoverAllServices(on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        // `Mutex`-boxed for the reason given in `awaitWriteWithoutResponseReadiness`.
        let assignedToken = Mutex<UInt64?>(nil)
        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                let token = session.nextGATTWaiterToken()
                assignedToken.withLock { $0 = token }
                session.pendingDiscoverServices[token] = continuation
                connections[identifier] = .connected(session)
                peripheral.discoverServices(nil)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverServicesWaiter(identifier: identifier, token: token)
                    }
                }
            }
        )
    }

    /// Issues `discoverCharacteristics(nil, for: service)` (discover *all* characteristics of
    /// the service) and suspends until ``handle(_:from:)`` resolves it. It works like
    /// ``ensureCharacteristicDiscovered(_:on:identifier:)`` except for the `nil` filter.
    private func awaitDiscoverAllCharacteristics(
        service: ServiceIdentifier,
        on peripheral: any PeripheralRemote,
        identifier: PeripheralIdentifier
    ) async throws {
        let assignedToken = Mutex<UInt64?>(nil)
        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                let token = session.nextGATTWaiterToken()
                assignedToken.withLock { $0 = token }
                session.pendingDiscoverCharacteristics[service, default: [:]][token] = continuation
                connections[identifier] = .connected(session)
                peripheral.discoverCharacteristics(nil, for: service)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverCharacteristicsWaiter(identifier: identifier, service: service, token: token)
                    }
                }
            }
        )
    }

    /// Issues `discoverDescriptors(for: characteristic)` and suspends until it resolves. It is
    /// the enumeration twin of ``ensureDescriptorsDiscovered(_:on:identifier:)``, without the
    /// per-descriptor cache check.
    private func awaitDiscoverAllDescriptors(
        characteristic: CharacteristicIdentifier,
        on peripheral: any PeripheralRemote,
        identifier: PeripheralIdentifier
    ) async throws {
        let assignedToken = Mutex<UInt64?>(nil)
        try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                let token = session.nextGATTWaiterToken()
                assignedToken.withLock { $0 = token }
                session.pendingDiscoverDescriptors[characteristic, default: [:]][token] = continuation
                connections[identifier] = .connected(session)
                peripheral.discoverDescriptors(for: characteristic)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverDescriptorsWaiter(identifier: identifier, characteristic: characteristic, token: token)
                    }
                }
            }
        )
    }

    // MARK: - Notifications

    /// Registers one `Peripheral.notifications(for:policy:)` subscriber and starts its pump
    /// task. The pump task bridges the shared raw-`Data` multicast and the subscriber's typed
    /// stream. The caller enqueues this function before it returns the stream, so the queue's
    /// FIFO order runs it before
    /// ``handleNotificationStreamTermination(peripheral:characteristic:token:)`` can be
    /// enqueued.
    ///
    /// The pump `Task` is a ledgered site. The actor starts it and stores it in
    /// `Session.notificationPumps`, keyed by `token`. The termination handler cancels it.
    ///
    /// - Parameters:
    ///   - survivesReconnect: Whether this subscriber's stream is parked, and not finished,
    ///     across an unexpected disconnect that a ``ReconnectPolicy`` will retry.
    ///   - deliver: Decodes and yields one raw value. It returns `nil` on success or the decode
    ///     error. A decode error finishes only this subscriber's stream.
    ///   - finish: Finishes the subscriber's typed stream. It finishes with the error if the
    ///     value is non-`nil`.
    func startNotificationPump(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID,
        survivesReconnect: Bool,
        deliver: @escaping @Sendable (Data) -> Error?,
        finish: @escaping @Sendable (Error?) -> Void
    ) {
        guard case .connected(var session) = connections[identifier] else {
            finish(BLESwiftError.notConnected)
            return
        }
        if survivesReconnect {
            session.notificationSurvivorTokens.insert(token)
        }

        let pump = Task { [weak self] in
            guard let self else {
                finish(BLESwiftError.notConnected)
                return
            }
            await self.runNotificationPump(
                identifier: identifier,
                characteristic: characteristic,
                token: token,
                survivesReconnect: survivesReconnect,
                deliver: deliver,
                finish: finish
            )
        }
        session.notificationPumps[token] = pump
        connections[identifier] = .connected(session)
    }

    /// The body of one subscriber's pump task. It subscribes to the raw multicast (and enables
    /// notifications if it is the first subscriber), forwards values through `deliver`, and
    /// finishes the typed stream when the raw stream ends.
    ///
    /// A `survivesReconnect` pump loops and does not finish when its raw stream fails at a
    /// disconnect that a ``ReconnectPolicy`` will retry. The pump then:
    /// 1. Finds its token parked in ``dormantNotifications``. A decode error happens while
    ///    connected, so the token is not parked then, and the stream finishes.
    /// 2. Suspends in ``awaitResubscription(identifier:characteristic:token:)``.
    /// 3. Resumes forwarding on the raw stream that the reconnect hands back.
    private func runNotificationPump(
        identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID,
        survivesReconnect: Bool,
        deliver: @Sendable (Data) -> Error?,
        finish: @Sendable (Error?) -> Void
    ) async {
        var raw: AsyncThrowingStream<Data, Error>
        do {
            raw = try await subscribeToNotifications(peripheral: identifier, characteristic: characteristic, token: token)
        } catch {
            finish(error)
            return
        }

        while true {
            do {
                for try await data in raw {
                    if let decodeError = deliver(data) {
                        throw decodeError
                    }
                }
                finish(nil)
                break
            } catch {
                if survivesReconnect,
                   !(error is CancellationError),
                   isDormantNotificationToken(token, identifier: identifier, characteristic: characteristic) {
                    do {
                        raw = try await awaitResubscription(identifier: identifier, characteristic: characteristic, token: token)
                        continue
                    } catch let resubscriptionError {
                        finish(resubscriptionError)
                        break
                    }
                }
                finish(error)
                break
            }
        }

        // Safety-net release, idempotent by token. The primary release path is the typed
        // stream's `onTermination`. This call covers a pump that was cancelled between that
        // no-op (before registration) and the registration above.
        releaseNotificationSubscriber(peripheral: identifier, characteristic: characteristic, token: token)
    }

    /// Whether `token` is parked in the dormant record of `identifier` for `characteristic`.
    /// A surviving pump uses it to tell a disconnect that waits for a reconnect (park) from
    /// every other raw-stream failure (finish).
    private func isDormantNotificationToken(_ token: UUID, identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) -> Bool {
        dormantNotifications[identifier]?.characteristics[characteristic]?.tokens.contains(token) ?? false
    }

    /// Suspends a surviving pump until one of three things happens: the reconnect enables its
    /// characteristic again (the pump resumes with the new raw stream), the re-enable fails,
    /// or the gap ends without a reconnect (the pump resumes with a throw). It uses the
    /// isolation-pinned continuation and cancellation hop of
    /// ``withCancellableGATTContinuation(register:onCancelled:)``.
    private func awaitResubscription(
        identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await withTaskCancellationHandler {
            let attach = { [self] (continuation: CheckedContinuation<AsyncThrowingStream<Data, Error>, Error>) in
                // Check dormancy again in the same actor turn as the registration. The gap may
                // have ended between the pump's `isDormantNotificationToken` check and this attach.
                guard var record = dormantNotifications[identifier],
                      var subscription = record.characteristics[characteristic],
                      subscription.tokens.contains(token) else {
                    continuation.resume(throwing: dormantNotifications[identifier]?.disconnectError ?? BLESwiftError.notConnected)
                    return
                }
                subscription.waiters[token] = continuation
                record.characteristics[characteristic] = subscription
                dormantNotifications[identifier] = record
            }
            // Pin the isolation on Swift 6.3 and earlier. See `withCancellableGATTContinuation`.
            #if compiler(>=6.4)
            return try await withCheckedThrowingContinuation(attach)
            #else
            return try await withCheckedThrowingContinuation(isolation: self, attach)
            #endif
        } onCancel: {
            self.queue.async {
                self.assumeIsolated(onQueue: self.queue) { central in
                    central.cancelResubscriptionWaiter(identifier: identifier, characteristic: characteristic, token: token)
                }
            }
        }
    }

    /// Removes a single parked resubscription waiter by token and resumes it with
    /// ``BLESwiftError/operationCancelled``. It handles the pump's cancellation, not a real
    /// re-enable result. It leaves the token's dormancy bookkeeping to
    /// ``handleNotificationStreamTermination(peripheral:characteristic:token:)``.
    private func cancelResubscriptionWaiter(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, token: UUID) {
        guard var record = dormantNotifications[identifier],
              var subscription = record.characteristics[characteristic],
              let continuation = subscription.waiters.removeValue(forKey: token) else { return }
        record.characteristics[characteristic] = subscription
        dormantNotifications[identifier] = record
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Reacts when a subscriber's typed stream terminates. It cancels and forgets the
    /// subscriber's pump task and releases the subscriber's reference count.
    ///
    /// A token whose pump is not in the session's ledger may be parked in
    /// ``dormantNotifications``, because its consumer broke during a reconnect gap or a
    /// re-enable. This function also removes such a token's dormancy bookkeeping, so a
    /// characteristic that no one waits for is not enabled again.
    func handleNotificationStreamTermination(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID
    ) {
        if case .connected(var session) = connections[identifier],
           let pump = session.notificationPumps.removeValue(forKey: token) {
            connections[identifier] = .connected(session)
            pump.cancel()
        } else if var record = dormantNotifications[identifier],
                  var dormantSubscription = record.characteristics[characteristic],
                  dormantSubscription.tokens.remove(token) != nil {
            let waiter = dormantSubscription.waiters.removeValue(forKey: token)
            let pump = record.pumps.removeValue(forKey: token)
            if dormantSubscription.tokens.isEmpty {
                record.characteristics.removeValue(forKey: characteristic)
            } else {
                record.characteristics[characteristic] = dormantSubscription
            }
            if record.characteristics.isEmpty {
                dormantNotifications.removeValue(forKey: identifier)
            } else {
                dormantNotifications[identifier] = record
            }
            waiter?.resume(throwing: BLESwiftError.operationCancelled)
            pump?.cancel()
        }
        releaseNotificationSubscriber(peripheral: identifier, characteristic: characteristic, token: token)
    }

    /// Registers `token` as one subscriber of the raw-`Data` notification multicast of
    /// `characteristic` and returns a new stream of it. Typed subscribers (through their pump)
    /// and the composite helpers use it.
    ///
    /// For the first subscriber, it registers the subscription BEFORE it enables notifications,
    /// which closes the loss window. Then discovery runs, and it waits for
    /// `setNotifyValue(true)`. If that fails, every current subscriber's stream (and enablement
    /// waiter) finishes with the error.
    ///
    /// A joiner is added to the existing subscription. If the enable handshake is still in
    /// progress, the joiner first waits for its confirmation. The composite helpers'
    /// listen-before-write guarantee depends on this wait.
    ///
    /// This function is NOT serialized through the per-characteristic FIFO. A subscription must
    /// be possible while a read on the same characteristic is pending, so that notification
    /// routing can take precedence (see
    /// ``handleDidUpdateValue(characteristic:value:error:from:)``).
    func subscribeToNotifications(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard case .connected(var session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }

        if var existing = session.notificationSubscriptions[characteristic] {
            existing.subscriberTokens.insert(token)
            let broadcaster = existing.broadcaster
            let confirmed = existing.enableConfirmed
            session.notificationSubscriptions[characteristic] = existing
            connections[identifier] = .connected(session)
            let stream = broadcaster.stream()
            if !confirmed {
                try await awaitNotificationEnablement(identifier: identifier, characteristic: characteristic, token: token)
            }
            return stream
        }

        // First subscriber: register BEFORE the enable (see the doc comment).
        var subscription = NotificationSubscription()
        subscription.subscriberTokens.insert(token)
        let broadcaster = subscription.broadcaster
        let peripheral = session.peripheral
        session.notificationSubscriptions[characteristic] = subscription
        connections[identifier] = .connected(session)
        let stream = broadcaster.stream()

        log("Enabling notifications on \(characteristic)", level: .debug, category: "gatt")

        do {
            try await ensureDiscovered(characteristic, on: peripheral, identifier: identifier)
            try requireProperty(
                [.notify, .indicate],
                operation: .notify,
                on: characteristic,
                peripheral: peripheral,
                identifier: identifier,
                bypass: session.compatibility.allowNotifyWithoutProperty
            )
            try await enableNotifications(identifier: identifier, characteristic: characteristic, peripheral: peripheral)
            confirmNotificationEnablement(identifier: identifier, characteristic: characteristic)
        } catch {
            failNotificationSubscription(identifier: identifier, characteristic: characteristic, error: error)
            throw error
        }

        return stream
    }

    /// The `setNotifyValue(true)` enable handshake, shared by
    /// ``subscribeToNotifications(peripheral:characteristic:token:)`` (first subscriber) and
    /// ``rearmDormantNotifications(_:)`` (reconnect). It issues the enable and waits for the
    /// `didUpdateNotificationState` confirmation.
    ///
    /// It ignores the confirmation's `isNotifying` payload on purpose. A stale
    /// disable-confirmation from a released subscription must not fail a new enable that is
    /// still waiting for its own confirmation.
    private func enableNotifications(
        identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        peripheral: any PeripheralRemote
    ) async throws {
        _ = try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<Bool, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                session.pendingNotifyStateChanges[characteristic] = continuation
                connections[identifier] = .connected(session)
                peripheral.setNotifyValue(true, for: characteristic)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.cancelPendingNotifyStateChange(identifier: identifier, characteristic: characteristic)
                    }
                }
            }
        )
    }

    /// Enables again the parked notification survivors of `identifier` after a successful
    /// reconnect. For each dormant characteristic, in UUID order, it:
    /// 1. Registers a new subscription in the CURRENT session.
    /// 2. Creates one raw stream for each parked pump BEFORE the enable, so there is no loss
    ///    window.
    /// 3. Runs discovery and the enable handshake again.
    /// 4. Hands each parked pump its stream.
    ///
    /// A characteristic can ALREADY have a live subscription, for example when a subscriber
    /// raced in after `.connected`, as the docs advise. The survivors then join that
    /// subscription, and wait for its enable handshake if it is in progress. The function
    /// issues NO second CCCD write, which keeps one enable for each characteristic.
    ///
    /// A characteristic that fails to enable again fails only its own streams. The cause can be
    /// a characteristic that a GATT change removed, or an enable error.
    ///
    /// At the end, the function yields
    /// ``ConnectionEvent/notificationsRestored(_:restored:failed:)``. It does not yield the
    /// event if:
    /// - Every survivor left during the gap.
    /// - The session vanished during the re-enable.
    /// - A new disconnect or `cancelAllOperations` cancelled this task.
    ///
    /// In the last two cases, the untouched characteristics stay dormant for the next
    /// reconnect, or the next termination's cleanup finishes them.
    private func rearmDormantNotifications(_ identifier: PeripheralIdentifier) async {
        guard let record = dormantNotifications[identifier] else { return }
        let characteristics = record.characteristics.keys.sorted { $0.uuidString < $1.uuidString }
        var restored: [CharacteristicIdentifier] = []
        var failed: [CharacteristicIdentifier: any Error] = [:]

        log("Re-arming \(characteristics.count) notification subscription(s) for \(identifier) after reconnect", level: .debug, category: "gatt")

        for characteristic in characteristics {
            // A cancelled re-arm (a second disconnect, cancelAllOperations) must not continue.
            // Otherwise, a late resumption could race the re-arm of the NEW session.
            if Task.isCancelled { return }
            guard case .connected(var session) = connections[identifier] else { return }
            // A consumer that broke during the gap may have emptied this characteristic or the
            // whole record. Then nothing is left to re-arm here.
            guard let dormantSubscription = dormantNotifications[identifier]?.characteristics[characteristic],
                  !dormantSubscription.tokens.isEmpty else { continue }
            let peripheral = session.peripheral

            if var existing = session.notificationSubscriptions[characteristic] {
                // Merge: a new subscriber already registered this characteristic and owns, or is
                // completing, its enable handshake. Never overwrite it, because that would orphan
                // its broadcaster and drop its single-slot enable continuation. Never issue a
                // second CCCD write. Join it, like the joiner path of `subscribeToNotifications`.
                existing.subscriberTokens.formUnion(dormantSubscription.tokens)
                let broadcaster = existing.broadcaster
                let confirmed = existing.enableConfirmed
                session.notificationSubscriptions[characteristic] = existing
                connections[identifier] = .connected(session)

                var streams: [UUID: AsyncThrowingStream<Data, Error>] = [:]
                for token in dormantSubscription.tokens {
                    streams[token] = broadcaster.stream()
                }

                do {
                    if !confirmed, let waiterToken = dormantSubscription.tokens.first {
                        try await awaitNotificationEnablement(identifier: identifier, characteristic: characteristic, token: waiterToken)
                    }
                    completeRearm(identifier: identifier, characteristic: characteristic, streams: streams)
                    restored.append(characteristic)
                } catch {
                    guard !Task.isCancelled, case .connected = connections[identifier] else { return }
                    log("Failed to re-arm notifications on \(characteristic) (merge): \(error)", level: .warning, category: "gatt")
                    // The owning subscriber's failure path already tore the subscription down, or
                    // only this waiter was cancelled. Fail only the survivors.
                    failRearm(identifier: identifier, characteristic: characteristic, error: error)
                    failed[characteristic] = error
                }
                continue
            }

            // Register the new subscription BEFORE the enable, as in `subscribeToNotifications`.
            var subscription = NotificationSubscription()
            subscription.subscriberTokens = dormantSubscription.tokens
            let broadcaster = subscription.broadcaster
            session.notificationSubscriptions[characteristic] = subscription
            connections[identifier] = .connected(session)

            // One raw stream for each surviving token, created before the enable, so a value that
            // arrives during the handshake is buffered and not lost.
            var streams: [UUID: AsyncThrowingStream<Data, Error>] = [:]
            for token in dormantSubscription.tokens {
                streams[token] = broadcaster.stream()
            }

            do {
                try await ensureDiscovered(characteristic, on: peripheral, identifier: identifier)
                try await enableNotifications(identifier: identifier, characteristic: characteristic, peripheral: peripheral)
                confirmNotificationEnablement(identifier: identifier, characteristic: characteristic)
                completeRearm(identifier: identifier, characteristic: characteristic, streams: streams)
                restored.append(characteristic)
            } catch {
                guard !Task.isCancelled, case .connected = connections[identifier] else {
                    // The session vanished during the re-arm (another disconnect), or this task was
                    // cancelled. Stop. Leave this characteristic and any untouched ones dormant.
                    // The new termination parks them again or finishes them.
                    return
                }
                log("Failed to re-arm notifications on \(characteristic): \(error)", level: .warning, category: "gatt")
                failNotificationSubscription(identifier: identifier, characteristic: characteristic, error: error)
                failRearm(identifier: identifier, characteristic: characteristic, error: error)
                failed[characteristic] = error
            }
        }

        if Task.isCancelled { return }
        dormantNotifications.removeValue(forKey: identifier)
        if case .connected(var session) = connections[identifier] {
            session.rearmTask = nil
            connections[identifier] = .connected(session)
        }

        if !restored.isEmpty || !failed.isEmpty {
            connectionBroadcaster.yield(.notificationsRestored(identifier, restored: restored, failed: failed))
        }
    }

    /// The synchronous success tail of one characteristic's re-arm. It takes the
    /// characteristic's dormant entry, moves the surviving pumps back into the session's ledger
    /// (marking their tokens as survivors again), and resumes each parked pump with its
    /// pre-created raw stream.
    private func completeRearm(
        identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        streams: [UUID: AsyncThrowingStream<Data, Error>]
    ) {
        guard var record = dormantNotifications[identifier],
              var dormantSubscription = record.characteristics.removeValue(forKey: characteristic) else { return }
        let waiters = dormantSubscription.waiters
        dormantSubscription.waiters = [:]
        let tokens = dormantSubscription.tokens
        var pumps: [UUID: Task<Void, Never>] = [:]
        for token in tokens {
            if let pump = record.pumps.removeValue(forKey: token) {
                pumps[token] = pump
            }
        }
        dormantNotifications[identifier] = record

        if case .connected(var session) = connections[identifier] {
            for (token, pump) in pumps {
                session.notificationPumps[token] = pump
            }
            session.notificationSurvivorTokens.formUnion(tokens)
            connections[identifier] = .connected(session)
        }

        for (token, continuation) in waiters {
            if let stream = streams[token] {
                continuation.resume(returning: stream)
            } else {
                continuation.resume(throwing: BLESwiftError.notConnected)
            }
        }
    }

    /// The synchronous failure tail of one characteristic's re-arm. It takes the
    /// characteristic's dormant entry and resumes each parked pump with `error`, so it fails
    /// only this characteristic's surviving streams.
    private func failRearm(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, error: Error) {
        guard var record = dormantNotifications[identifier],
              var dormantSubscription = record.characteristics.removeValue(forKey: characteristic) else { return }
        let waiters = dormantSubscription.waiters
        dormantSubscription.waiters = [:]
        for token in dormantSubscription.tokens {
            record.pumps.removeValue(forKey: token)
        }
        dormantNotifications[identifier] = record

        for continuation in waiters.values {
            continuation.resume(throwing: error)
        }
    }

    /// Suspends a joiner until the enable handshake in progress for `characteristic` confirms
    /// or fails. A cancellation removes and resumes only this joiner's own waiter.
    private func awaitNotificationEnablement(
        identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID
    ) async throws {
        do {
            try await withCancellableGATTContinuation(
                register: { (continuation: CheckedContinuation<Void, Error>) in
                    guard case .connected(var session) = connections[identifier],
                          var subscription = session.notificationSubscriptions[characteristic] else {
                        continuation.resume(throwing: BLESwiftError.notConnected)
                        return
                    }
                    guard !subscription.enableConfirmed else {
                        continuation.resume(returning: ())
                        return
                    }
                    subscription.enableWaiters[token] = continuation
                    session.notificationSubscriptions[characteristic] = subscription
                    connections[identifier] = .connected(session)
                },
                onCancelled: {
                    self.queue.async {
                        self.assumeIsolated(onQueue: self.queue) { central in
                            central.cancelNotificationEnablementWaiter(identifier: identifier, characteristic: characteristic, token: token)
                        }
                    }
                }
            )
        } catch {
            releaseNotificationSubscriber(peripheral: identifier, characteristic: characteristic, token: token)
            throw error
        }
    }

    /// Marks the subscription of `characteristic` as confirmed by the enable, and removes and
    /// resumes every enablement waiter.
    private func confirmNotificationEnablement(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) {
        guard case .connected(var session) = connections[identifier],
              var subscription = session.notificationSubscriptions[characteristic] else { return }
        subscription.enableConfirmed = true
        let waiters = subscription.enableWaiters
        subscription.enableWaiters = [:]
        session.notificationSubscriptions[characteristic] = subscription
        connections[identifier] = .connected(session)

        log("Notifications enabled on \(characteristic)", level: .debug, category: "gatt")

        for waiter in waiters.values {
            waiter.resume(returning: ())
        }
    }

    /// Fails the whole subscription of `characteristic`. It removes the subscription, resumes
    /// every enablement waiter with `error`, and finishes the raw broadcaster with `error`.
    ///
    /// It does not issue `setNotifyValue(false)`. After an enable failure, the enable was never
    /// confirmed. After a value error, the delivery already fails.
    private func failNotificationSubscription(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, error: Error) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let subscription = session.notificationSubscriptions.removeValue(forKey: characteristic) else { return }
        connections[identifier] = .connected(session)

        log("Notification subscription on \(characteristic) failed: \(error)", level: .warning, category: "gatt")

        for waiter in subscription.enableWaiters.values {
            waiter.resume(throwing: error)
        }
        subscription.broadcaster.finish(throwing: error)
    }

    /// Releases one subscriber's reference on the subscription of `characteristic`. It is
    /// idempotent for each `token`.
    ///
    /// The **last** release removes the subscription, finishes its broadcaster, and issues
    /// `setNotifyValue(false)`, only while the peripheral is connected and the radio is
    /// `.poweredOn`. Otherwise CoreBluetooth logs "API MISUSE". It does not wait for the
    /// disable confirmation.
    func releaseNotificationSubscriber(peripheral identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, token: UUID) {
        guard case .connected(var session) = connections[identifier] else { return }
        session.notificationSurvivorTokens.remove(token)
        guard var subscription = session.notificationSubscriptions[characteristic] else {
            connections[identifier] = .connected(session)
            return
        }
        guard subscription.subscriberTokens.remove(token) != nil else {
            connections[identifier] = .connected(session)
            return
        }

        // Remove and resume this token's enablement waiter, if any. A release can arrive while
        // the joiner is still suspended and waits for the confirmation.
        let waiter = subscription.enableWaiters.removeValue(forKey: token)

        if subscription.subscriberTokens.isEmpty {
            session.notificationSubscriptions.removeValue(forKey: characteristic)
            connections[identifier] = .connected(session)
            waiter?.resume(throwing: BLESwiftError.operationCancelled)
            subscription.broadcaster.finish()

            log("Last subscriber released — disabling notifications on \(characteristic)", level: .debug, category: "gatt")

            if state == .poweredOn {
                session.peripheral.setNotifyValue(false, for: characteristic)
            }
        } else {
            session.notificationSubscriptions[characteristic] = subscription
            connections[identifier] = .connected(session)
            waiter?.resume(throwing: BLESwiftError.operationCancelled)
        }
    }

    /// The number of live subscriber tokens on the subscription of `characteristic` for `id`.
    /// It is a test hook (`@testable`), not public API. Subscriber registration is
    /// asynchronous, so multi-subscriber tests wait for this count first.
    func notificationSubscriberCount(for characteristic: CharacteristicIdentifier, on id: PeripheralIdentifier) -> Int {
        guard case .connected(let session) = connections[id] else { return 0 }
        return session.notificationSubscriptions[characteristic]?.subscriberTokens.count ?? 0
    }

    /// The number of surviving pumps parked in
    /// ``awaitResubscription(identifier:characteristic:token:)`` for `characteristic` on the
    /// dormant record of `id`. It is a test hook (`@testable`), not public API, and the
    /// dormant counterpart of ``notificationSubscriberCount(for:on:)``. A pump parks
    /// asynchronously after the disconnect, so tests of the gap wait for this count first.
    func dormantNotificationWaiterCount(for characteristic: CharacteristicIdentifier, on id: PeripheralIdentifier) -> Int {
        dormantNotifications[id]?.characteristics[characteristic]?.waiters.count ?? 0
    }

    /// Removes the pending notify-state-change continuation for `characteristic`, if still
    /// pending, and resumes it with ``BLESwiftError/operationCancelled``. See
    /// ``cancelPendingRead(identifier:characteristic:)``.
    private func cancelPendingNotifyStateChange(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingNotifyStateChanges.removeValue(forKey: characteristic) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Removes a single enablement waiter by token and resumes it with
    /// ``BLESwiftError/operationCancelled``. The subscription and the other waiters stay
    /// intact.
    private func cancelNotificationEnablementWaiter(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, token: UUID) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard var subscription = session.notificationSubscriptions[characteristic],
              let continuation = subscription.enableWaiters.removeValue(forKey: token) else { return }
        session.notificationSubscriptions[characteristic] = subscription
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    // MARK: - Composite helpers

    /// Backs `Peripheral.writeAndAwaitNotification(write:to:awaitOn:timeout:)`. It subscribes
    /// to `notifyCharacteristic` FIRST, then writes, then returns the first notification value,
    /// which keeps the listen-before-write order. The timeout covers the whole sequence and
    /// throws ``BLESwiftError/listenTimedOut``.
    func performWriteAndAwaitNotification(
        peripheral identifier: PeripheralIdentifier,
        writeCharacteristic: CharacteristicIdentifier,
        notifyCharacteristic: CharacteristicIdentifier,
        data: Data,
        timeout: Duration?
    ) async throws -> Data {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.listenTimedOut) {
            try await self.writeAndAwaitNotificationNow(
                identifier: identifier,
                writeCharacteristic: writeCharacteristic,
                notifyCharacteristic: notifyCharacteristic,
                data: data
            )
        }
    }

    /// The subscribe, write, and await-first-value sequence of
    /// ``performWriteAndAwaitNotification(peripheral:writeCharacteristic:notifyCharacteristic:data:timeout:)``.
    private func writeAndAwaitNotificationNow(
        identifier: PeripheralIdentifier,
        writeCharacteristic: CharacteristicIdentifier,
        notifyCharacteristic: CharacteristicIdentifier,
        data: Data
    ) async throws -> Data {
        let token = UUID()
        let raw = try await subscribeToNotifications(peripheral: identifier, characteristic: notifyCharacteristic, token: token)
        do {
            try await performWrite(peripheral: identifier, characteristic: writeCharacteristic, data: data, type: .withResponse, timeout: nil)
            var iterator = raw.makeAsyncIterator()
            guard let response = try await iterator.next() else {
                throw BLESwiftError.missingData
            }
            releaseNotificationSubscriber(peripheral: identifier, characteristic: notifyCharacteristic, token: token)
            return response
        } catch {
            releaseNotificationSubscriber(peripheral: identifier, characteristic: notifyCharacteristic, token: token)
            throw error
        }
    }

    /// Backs `Peripheral.writeAndAssemble(write:to:assembleFrom:expectedLength:timeout:)`.
    /// It is like
    /// ``performWriteAndAwaitNotification(peripheral:writeCharacteristic:notifyCharacteristic:data:timeout:)``,
    /// but it collects packets until exactly `expectedLength` bytes arrive. More bytes throw
    /// ``BLESwiftError/tooMuchData(expected:received:)``. The timeout covers the whole assembly.
    func performWriteAndAssemble(
        peripheral identifier: PeripheralIdentifier,
        writeCharacteristic: CharacteristicIdentifier,
        notifyCharacteristic: CharacteristicIdentifier,
        data: Data,
        expectedLength: Int,
        timeout: Duration?
    ) async throws -> Data {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.listenTimedOut) {
            try await self.writeAndAssembleNow(
                identifier: identifier,
                writeCharacteristic: writeCharacteristic,
                notifyCharacteristic: notifyCharacteristic,
                data: data,
                expectedLength: expectedLength
            )
        }
    }

    /// The subscribe, write, and assemble loop of
    /// ``performWriteAndAssemble(peripheral:writeCharacteristic:notifyCharacteristic:data:expectedLength:timeout:)``.
    private func writeAndAssembleNow(
        identifier: PeripheralIdentifier,
        writeCharacteristic: CharacteristicIdentifier,
        notifyCharacteristic: CharacteristicIdentifier,
        data: Data,
        expectedLength: Int
    ) async throws -> Data {
        let token = UUID()
        let raw = try await subscribeToNotifications(peripheral: identifier, characteristic: notifyCharacteristic, token: token)
        do {
            try await performWrite(peripheral: identifier, characteristic: writeCharacteristic, data: data, type: .withResponse, timeout: nil)

            var assembled = Data()
            var iterator = raw.makeAsyncIterator()
            while assembled.count < expectedLength {
                guard let packet = try await iterator.next() else {
                    throw BLESwiftError.missingData
                }
                assembled.append(packet)
                if assembled.count > expectedLength {
                    throw BLESwiftError.tooMuchData(expected: expectedLength, received: assembled)
                }
            }

            releaseNotificationSubscriber(peripheral: identifier, characteristic: notifyCharacteristic, token: token)
            return assembled
        } catch {
            releaseNotificationSubscriber(peripheral: identifier, characteristic: notifyCharacteristic, token: token)
            throw error
        }
    }

    /// Backs `Peripheral.flush(_:quietPeriod:)`. It consumes and discards raw packets until a
    /// full `quietPeriod` passes with no packet. Every packet restarts the window.
    ///
    /// - Throws: ``BLESwiftError/invalidArgument(_:)`` if `quietPeriod` is not strictly
    ///   positive.
    func performFlush(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        quietPeriod: Duration
    ) async throws {
        guard quietPeriod > .zero else {
            throw BLESwiftError.invalidArgument("flush(_:quietPeriod:) requires a quietPeriod greater than zero; got \(quietPeriod)")
        }

        let token = UUID()
        let raw = try await subscribeToNotifications(peripheral: identifier, characteristic: characteristic, token: token)
        defer { releaseNotificationSubscriber(peripheral: identifier, characteristic: characteristic, token: token) }

        let iterator = SequentialAccessIterator(raw)
        var flushedPacketCount = 0

        while true {
            let packet: Data?
            do {
                packet = try await withTimeout(clock: configuration.clock, quietPeriod, throwing: BLESwiftError.timedOut) {
                    try await iterator.next()
                }
            } catch BLESwiftError.timedOut {
                // A full quiet period passed with no packet. The flush is complete.
                break
            }
            guard packet != nil else {
                // The raw stream ended cleanly. Nothing is left to flush.
                break
            }
            flushedPacketCount += 1
        }

        if Task.isCancelled {
            throw BLESwiftError.operationCancelled
        }

        log("Flushed \(flushedPacketCount) packet(s) from \(characteristic)", level: .debug, category: "gatt")
    }

    // MARK: - Cancellable continuations

    /// Suspends until `register` resumes the continuation. Either a real CoreBluetooth
    /// completion resumes it, or, on cancellation, `onCancelled` does. `onCancelled` hops onto
    /// ``queue`` through `assumeIsolated`, removes whatever `register` stored, and resumes it.
    ///
    /// Every GATT continuation uses this function and not a bare
    /// `withCheckedThrowingContinuation`, because a cancelled `Task` does not resume a
    /// suspended continuation. Otherwise, a `timeout:` would hang and not throw
    /// ``BLESwiftError/timedOut``.
    private func withCancellableGATTContinuation<T: Sendable>(
        register: (CheckedContinuation<T, Error>) -> Void,
        onCancelled: @escaping @Sendable () -> Void
    ) async throws -> T {
        // On Swift 6.3 and earlier, the compiler loses the inferred #isolation through the
        // cancellation-handler closure and runs `register` off the actor's executor. That
        // silently breaks the queue confinement for backend calls, so pin the isolation
        // explicitly. Swift 6.4 deprecates that overload for a nonisolated(nonsending) one,
        // which inherits the actor correctly.
        try await withTaskCancellationHandler {
            #if compiler(>=6.4)
            try await withCheckedThrowingContinuation(register)
            #else
            try await withCheckedThrowingContinuation(isolation: self, register)
            #endif
        } onCancel: {
            onCancelled()
        }
    }

    // MARK: - L2CAP

    /// Opens an L2CAP channel to `psm` on `identifier`.
    /// `Peripheral.openL2CAPChannel(psm:timeout:)` calls it. It wraps the open in `timeout`,
    /// registers the resulting transport, and returns an ``L2CAPChannel``.
    func performOpenL2CAPChannel(
        peripheral identifier: PeripheralIdentifier,
        psm: L2CAPPSM,
        timeout: Duration?
    ) async throws -> L2CAPChannel {
        try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.timedOut) {
            let transport = try await self.awaitL2CAPOpen(identifier: identifier, psm: psm)
            return try await self.registerL2CAPChannel(identifier: identifier, transport: transport)
        }
    }

    /// Issues the CoreBluetooth L2CAP open and suspends until ``handle(_:from:)`` resolves it.
    /// It follows the remove-then-resume and cancellation rules of every GATT continuation. It
    /// registers the waiter under a new token before it issues the open, so a `didOpen` that
    /// arrives synchronously still finds the waiter.
    private func awaitL2CAPOpen(identifier: PeripheralIdentifier, psm: L2CAPPSM) async throws -> any L2CAPChannelRemote {
        guard case .connected(var session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let token = session.nextGATTWaiterToken()
        connections[identifier] = .connected(session)

        return try await withCancellableGATTContinuation(
            register: { (continuation: CheckedContinuation<any L2CAPChannelRemote, Error>) in
                guard case .connected(var session) = connections[identifier] else {
                    continuation.resume(throwing: BLESwiftError.notConnected)
                    return
                }
                let peripheral = session.peripheral
                session.pendingL2CAPOpens[token] = continuation
                connections[identifier] = .connected(session)
                peripheral.openL2CAPChannel(psm)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated(onQueue: self.queue) { central in
                        central.cancelPendingL2CAPOpen(identifier: identifier, token: token)
                    }
                }
            }
        )
    }

    /// Removes and resumes the oldest pending L2CAP-open waiter (FIFO by token) for
    /// `identifier`. On an error, it resumes with the error. On success, it resumes with the
    /// transport. If no waiter is pending, it closes the channel so that the channel does not
    /// leak.
    private func resumePendingL2CAPOpen(for identifier: PeripheralIdentifier, channel: (any L2CAPChannelRemote)?, error: NSError?) {
        guard case .connected(var session) = connections[identifier] else {
            channel?.close(error: BLESwiftError.notConnected)
            return
        }
        guard let token = session.pendingL2CAPOpens.keys.min() else {
            log("Ignoring didOpenL2CAPChannel for \(identifier) with no pending open", level: .debug, category: "l2cap")
            channel?.close(error: BLESwiftError.notConnected)
            return
        }
        let continuation = session.pendingL2CAPOpens.removeValue(forKey: token)
        connections[identifier] = .connected(session)
        if let error {
            continuation?.resume(throwing: error)
        } else if let channel {
            continuation?.resume(returning: channel)
        } else {
            continuation?.resume(throwing: BLESwiftError.l2capOpenFailed)
        }
    }

    /// Removes a single pending L2CAP-open waiter by token and resumes it with
    /// ``BLESwiftError/operationCancelled``. It handles a cancellation, not a real `didOpen`.
    /// Other pending opens stay untouched.
    private func cancelPendingL2CAPOpen(identifier: PeripheralIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingL2CAPOpens.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Registers a newly opened `transport` under a new token and returns the public
    /// ``L2CAPChannel`` handle. If the peripheral disconnects between the open and this call,
    /// it closes the transport and throws ``BLESwiftError/notConnected``.
    private func registerL2CAPChannel(identifier: PeripheralIdentifier, transport: any L2CAPChannelRemote) throws -> L2CAPChannel {
        guard case .connected(var session) = connections[identifier] else {
            transport.close(error: BLESwiftError.notConnected)
            throw BLESwiftError.notConnected
        }
        let token = UUID()
        session.l2capChannels[token] = transport
        connections[identifier] = .connected(session)
        log("Opened L2CAP channel \(transport.psm) for \(identifier)", level: .info, category: "l2cap")
        return L2CAPChannel(remote: transport, token: token, peripheral: identifier, central: self)
    }

    /// Closes and deregisters a single L2CAP channel, for an explicit `L2CAPChannel.close()`.
    /// It does nothing if the session is gone or the token is unknown.
    func closeL2CAPChannel(peripheral identifier: PeripheralIdentifier, token: UUID) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let transport = session.l2capChannels.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        transport.close(error: nil)
    }

    /// Closes every open L2CAP channel on the session of `identifier` with `error`. It is the
    /// L2CAP counterpart of ``finishNotificationStreams(for:error:)``. Run it while the entry
    /// is still `.connected`, because the channels live inside `Session`.
    func closeL2CAPChannels(for identifier: PeripheralIdentifier, error: Error) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard !session.l2capChannels.isEmpty else { return }
        log("Closing \(session.l2capChannels.count) L2CAP channel(s) for \(identifier): \(error)", level: .debug, category: "l2cap")
        let channels = session.l2capChannels
        session.l2capChannels.removeAll()
        connections[identifier] = .connected(session)
        for transport in channels.values {
            transport.close(error: error)
        }
    }

    /// Calls ``closeL2CAPChannels(for:error:)`` for every connected peripheral.
    /// ``stopAndExtractState()`` uses it.
    func closeAllSessionsL2CAPChannels(error: Error) {
        for identifier in Array(connections.keys) {
            closeL2CAPChannels(for: identifier, error: error)
        }
    }

    // MARK: - Per-characteristic FIFO

    /// Runs GATT operations on the same characteristic one at a time. It waits for the previous
    /// tail `Task` of `characteristic` before it runs `operation`, and then replaces the tail.
    /// Different characteristics interleave freely.
    ///
    /// `operation` runs **inline**, in this call's task, and not in a new `Task { }`. Such a
    /// `Task` would not inherit the caller's cancellation, and `withTimeout` could not reach
    /// the continuation-based waits of `operation`.
    private func runOnFIFO<T: Sendable>(
        identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        operation: () async throws -> T
    ) async throws -> T {
        guard case .connected(var session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }

        let previousTail = session.fifoTails[characteristic]
        let (doneStream, doneContinuation) = AsyncStream<Void>.makeStream()
        let myTail = Task<Void, Never> {
            for await _ in doneStream {}
        }
        session.fifoTails[characteristic] = myTail
        connections[identifier] = .connected(session)

        defer { doneContinuation.finish() }

        await previousTail?.value

        guard case .connected = connections[identifier] else {
            throw BLESwiftError.notConnected
        }

        return try await operation()
    }

    /// The RSSI counterpart to ``runOnFIFO(identifier:characteristic:operation:)``. It orders
    /// `readRSSI()` calls through ``Session/rssiTail`` (a single tail, not a per-characteristic
    /// map). `operation` runs inline for the reason given at that function.
    private func runRSSISerialized<T: Sendable>(
        identifier: PeripheralIdentifier,
        operation: () async throws -> T
    ) async throws -> T {
        guard case .connected(var session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }

        let previousTail = session.rssiTail
        let (doneStream, doneContinuation) = AsyncStream<Void>.makeStream()
        let myTail = Task<Void, Never> {
            for await _ in doneStream {}
        }
        session.rssiTail = myTail
        connections[identifier] = .connected(session)

        defer { doneContinuation.finish() }

        await previousTail?.value

        guard case .connected = connections[identifier] else {
            throw BLESwiftError.notConnected
        }

        return try await operation()
    }

    /// Fails the active scan with `error`. It runs whenever the radio leaves `.poweredOn`.
    ///
    /// Connection and GATT operations fail through ``handleBluetoothUnavailable()`` and
    /// ``handleTermination(identifier:error:)`` instead, because a scan has no
    /// connection-scoped route.
    func failAllPendingOperations(error: BLESwiftError) {
        log("Failing all pending operations: \(error)", level: .warning, category: "state")
        failActiveScan(error)
    }

    // MARK: - Scanning

    /// Scans for nearby peripherals that advertise `services`. It yields a ``ScanEvent`` for
    /// every sighting. CoreBluetooth has one physical scanner, so a call while a scan is
    /// active immediately fails the *new* stream with ``BLESwiftError/alreadyScanning``.
    ///
    /// The scan stops when the consumer stops it (`break` or task cancel), when `timeout`
    /// elapses, or when the radio leaves ``CentralState/poweredOn``. In the last case the
    /// stream throws ``BLESwiftError/bluetoothUnavailable``. A connection to a sighted
    /// peripheral does not affect the scan. See <doc:Scanning>.
    ///
    /// - Parameters:
    ///   - services: The services to scan for. `nil` scans for all peripherals. Apple
    ///     discourages this outside short, time-boxed scans.
    ///   - allowDuplicates: Whether to report repeat sightings as ``ScanEvent/updated(_:)``
    ///     and to track loss through `lossTimeout`. The default is `false`.
    ///   - rssiThreshold: The minimum RSSI change, in dBm, for a repeat sighting to produce
    ///     ``ScanEvent/updated(_:)``. The default `nil` disables throttling.
    ///   - lossTimeout: How long a sighted peripheral can stay unseen before the scan reports
    ///     ``ScanEvent/lost(_:)``. It applies only when `allowDuplicates` is `true`. The
    ///     default is 15 seconds.
    ///   - timeout: The maximum duration of the scan. The default `nil` scans until the
    ///     consumer stops it. When the timeout elapses, the stream finishes without an error.
    /// - Returns: A single-consumer stream of ``ScanEvent``s.
    ///
    /// - Note: On iOS, if the app is in the background, `allowDuplicates: true` fails the scan
    ///   with ``BLESwiftError/allowDuplicatesInBackgroundNotSupported``. No `services` fails
    ///   it with ``BLESwiftError/missingServiceIdentifiersInBackground``.
    public func scan(
        services: [ServiceIdentifier]?,
        allowDuplicates: Bool = false,
        rssiThreshold: Int? = nil,
        lossTimeout: Duration = .seconds(15),
        timeout: Duration? = nil
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        scan(
            filter: ScanFilter(services: services),
            allowDuplicates: allowDuplicates,
            rssiThreshold: rssiThreshold,
            lossTimeout: lossTimeout,
            timeout: timeout
        )
    }

    /// Scans for nearby peripherals that match `filter`. It yields a ``ScanEvent`` for every
    /// matching sighting. Only ``ScanFilter/services`` reaches the radio. The actor applies
    /// every other filter field to each sighting before it records it. A non-matching sighting
    /// is dropped entirely: not stored, not loss-tracked, and no event.
    ///
    /// All other behavior is the same as
    /// ``scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``, which is a thin
    /// wrapper over this method:
    /// - The single-scan rule (``BLESwiftError/alreadyScanning``).
    /// - The stop when the consumer stops.
    /// - `timeout`.
    /// - The iOS backgrounding guards.
    ///
    /// - Parameters:
    ///   - filter: The match criteria.
    ///   - allowDuplicates: Whether to keep reporting sightings of an already discovered
    ///     peripheral as ``ScanEvent/updated(_:)``, and to track its loss through
    ///     `lossTimeout`. The default is `false`.
    ///   - rssiThreshold: The minimum absolute RSSI change, in dBm, for a repeat sighting to
    ///     produce ``ScanEvent/updated(_:)``. The default `nil` disables throttling.
    ///   - lossTimeout: How long a sighted peripheral can stay unseen before the scan reports
    ///     ``ScanEvent/lost(_:)``. It applies only when `allowDuplicates` is `true`. The
    ///     default is 15 seconds.
    ///   - timeout: The maximum duration of the scan. The default `nil` scans until the
    ///     consumer stops it. When the timeout elapses, the stream finishes cleanly.
    /// - Returns: A single-consumer stream of ``ScanEvent``s.
    public func scan(
        filter: ScanFilter,
        allowDuplicates: Bool = false,
        rssiThreshold: Int? = nil,
        lossTimeout: Duration = .seconds(15),
        timeout: Duration? = nil
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScanEvent.self)

        guard activeScan == nil else {
            continuation.finish(throwing: BLESwiftError.alreadyScanning)
            return stream
        }

        let services = filter.services
        let missingServices = services?.isEmpty ?? true
        if missingServices {
            let warning = "scan(services:) called with nil/empty services — Apple discourages this: it "
                + "increases battery and CPU usage, and does not work in the background."
            log("\(warning)", level: .warning, category: "scan")
        }

        let scan = ActiveScan(
            continuation: continuation,
            allowDuplicates: allowDuplicates,
            rssiThreshold: rssiThreshold,
            lossTimeout: lossTimeout,
            filter: filter
        )
        activeScan = scan
        isScanningBox.withLock { $0 = true }

        manager?.scanForPeripherals(withServices: services, options: ScanOptions(allowDuplicates: allowDuplicates))

        #if os(iOS)
        installBackgroundGuardIfNeeded(scan: scan, allowDuplicates: allowDuplicates, missingServices: missingServices)
        #endif

        if let timeout {
            scan.timeoutTask = Task { [weak self, clock = configuration.clock] in
                try? await clock.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutActiveScan()
            }
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.assumeIsolated(onQueue: self.queue) { central in
                    central.finishActiveScan()
                }
            }
        }

        log("Scan started (allowDuplicates: \(allowDuplicates))", level: .info, category: "scan")

        return stream
    }

    /// Routes a `CentralEvent/didDiscover` event to the active scan, if any. It silently drops
    /// a discovery that arrives after the scan ended. It emits at most one ``ScanEvent``, and
    /// none if the scan's filter rejects the sighting or throttling suppresses it.
    private func handleDiscovery(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int) {
        guard let scan = activeScan else { return }

        let newDiscovery = Discovery(peripheral: peripheral, advertisement: advertisement, rssi: rssi)

        // A non-matching sighting is dropped entirely: not stored, not loss-tracked, no event.
        if let filter = scan.filter, !filter.matches(newDiscovery) {
            return
        }

        // Only allowDuplicates scans track loss. The timer is refreshed even if throttling
        // applies below, because a throttled sighting still shows that the peripheral is not
        // silent.
        if scan.allowDuplicates {
            scheduleLossTimer(for: peripheral, in: scan)
        }

        guard let existing = scan.discoveries[peripheral.uuid] else {
            scan.discoveries[peripheral.uuid] = newDiscovery
            scan.continuation.yield(.discovered(newDiscovery))
            return
        }

        // Throttled: do not update the stored discovery, so the next sighting's change is still
        // measured against the last *reported* RSSI, and do not yield anything.
        if let threshold = scan.rssiThreshold, abs(existing.rssi - rssi) < threshold {
            return
        }

        scan.discoveries[peripheral.uuid] = newDiscovery

        if scan.allowDuplicates {
            scan.continuation.yield(.updated(newDiscovery))
        }
    }

    /// Sets the loss-expiry deadline of `peripheral`. It cancels any existing timer and starts
    /// a new timer of `lossTimeout`. It runs only for `allowDuplicates` scans.
    ///
    /// This is an approved `Task { }` site. The task is stored in `ActiveScan.lossTimers`, so
    /// it is always cancellable.
    private func scheduleLossTimer(for peripheral: PeripheralIdentifier, in scan: ActiveScan) {
        scan.lossTimers[peripheral.uuid]?.cancel()

        let lossTimeout = scan.lossTimeout
        scan.lossTimers[peripheral.uuid] = Task { [weak self, clock = configuration.clock] in
            try? await clock.sleep(for: lossTimeout)
            guard !Task.isCancelled else { return }
            await self?.handleLoss(of: peripheral)
        }
    }

    /// Reports `peripheral` as ``ScanEvent/lost(_:)`` if the active scan still tracks it. It
    /// does nothing if the scan sighted the peripheral again or already ended.
    private func handleLoss(of peripheral: PeripheralIdentifier) {
        guard let scan = activeScan else { return }
        guard let discovery = scan.discoveries.removeValue(forKey: peripheral.uuid) else { return }
        scan.lossTimers.removeValue(forKey: peripheral.uuid)
        scan.continuation.yield(.lost(discovery))
    }

    /// Finishes the active scan's stream cleanly after its `timeout:` elapses. The stream's
    /// `onTermination` then triggers ``finishActiveScan()``.
    private func timeoutActiveScan() {
        guard activeScan != nil else { return }
        log("Scan timed out", level: .info, category: "scan")
        activeScan?.continuation.finish()
    }

    /// Finishes the active scan's stream with `error`, if a scan is active. It runs when the
    /// radio leaves `.poweredOn` (through ``failAllPendingOperations(error:)``) and, on iOS,
    /// when a backgrounding guard fires.
    private func failActiveScan(_ error: BLESwiftError) {
        guard activeScan != nil else { return }
        log("Failing active scan: \(error)", level: .warning, category: "scan")
        activeScan?.continuation.finish(throwing: error)
    }

    /// The single cleanup path for a scan that ended. It:
    /// - Cancels every loss timer and the timeout task.
    /// - Removes the backgrounding observer (iOS).
    /// - Stops the hardware scan, only if the radio is still `.poweredOn`.
    /// - Clears ``activeScan`` and ``isScanning``.
    ///
    /// The `onTermination` handler of
    /// ``scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)`` calls it, and so
    /// does `teardownScanNow`, which `findFirst` uses for a deterministic teardown. It is
    /// idempotent: it guards on a non-`nil` ``activeScan``.
    private func finishActiveScan() {
        guard let scan = activeScan else { return }
        activeScan = nil
        isScanningBox.withLock { $0 = false }

        for task in scan.lossTimers.values {
            task.cancel()
        }
        scan.timeoutTask?.cancel()

        #if os(iOS)
        if let observer = scan.backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif

        if manager?.radioState == .poweredOn {
            manager?.stopScan()
        }

        log("Scan stopped", level: .info, category: "scan")
    }

    /// Scans with `filter` and returns the first matching ``Discovery``. It stops the scan.
    ///
    /// The scan is fully torn down (`isScanning` is `false`) before this function returns or
    /// throws, on every exit path: success, timeout, error, and task cancellation.
    ///
    /// - Parameters:
    ///   - filter: The match criteria. See
    ///     ``scan(filter:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``.
    ///   - timeout: How long to wait for a match before the call throws
    ///     ``BLESwiftError/timedOut``. The default `nil` waits without a limit. Pass a value,
    ///     because Apple discourages an unfiltered scan that stays on.
    /// - Returns: The first ``Discovery`` that matches `filter`.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/timedOut`` when `timeout` elapses, or the scan's stream ends
    ///     without a match.
    ///   - ``BLESwiftError/alreadyScanning`` if a scan is already active.
    ///   - `CancellationError` on task cancellation.
    ///   - Any error that ends the scan (for example ``BLESwiftError/bluetoothUnavailable``).
    public func findFirst(matching filter: ScanFilter, timeout: Duration? = nil) async throws -> Discovery {
        // On success, `scan` claims `activeScan` synchronously. When it refuses
        // (`.alreadyScanning`), it leaves `activeScan` untouched. So a change of `activeScan`
        // across the call identifies the scan that is OURS to tear down. It is `nil` after a
        // refusal, because someone else's scan must survive the error path below.
        let previous = activeScan
        let stream = scan(filter: filter)
        let ourScan = activeScan !== previous ? activeScan : nil

        do {
            let discovery = try await withTimeout(clock: configuration.clock, timeout, throwing: BLESwiftError.timedOut) {
                for try await event in stream {
                    if case .discovered(let discovery) = event {
                        return discovery
                    }
                }
                // The stream ended (for example an inner timeout) without a match.
                throw BLESwiftError.timedOut
            }
            teardownScanNow(ourScan)
            return discovery
        } catch {
            teardownScanNow(ourScan)
            throw error
        }
    }

    /// Synchronously tears down `scan` if it is still the active scan. It is the deterministic
    /// counterpart to the ``finishActiveScan()`` hop that `onTermination` drives through
    /// `queue.async`, which can land *after* a `findFirst` caller has resumed. After this
    /// function, that pending hop is a guarded no-op. It is idempotent and ignores a `nil` or
    /// superseded `scan`.
    private func teardownScanNow(_ scan: ActiveScan?) {
        guard let scan, activeScan === scan else { return }
        scan.continuation.finish()
        finishActiveScan()
    }

    /// Connects to a peripheral by a saved `UUID`, with an optional fallback to a scan.
    ///
    /// The function first tries ``knownPeripherals(withIdentifiers:)``, which does not use
    /// the radio. If CoreBluetooth no longer knows `identifier` and `fallbackScan` is
    /// non-`nil`, it runs ``findFirst(matching:timeout:)`` and connects to the result. That
    /// peripheral can have a *different* UUID. Save the returned ``Peripheral/id`` again.
    /// See <doc:Scanning#Saved-devices>.
    ///
    /// - Parameters:
    ///   - identifier: The saved peripheral `UUID` to resolve.
    ///   - fallbackScan: Match criteria for a fallback scan when `identifier` is no longer
    ///     known. The default `nil` disables the fallback.
    ///   - reconnect: What to do if the connection is lost unexpectedly later. The default is
    ///     ``ReconnectPolicy/never``.
    ///   - timeout: Applies to each phase separately: the fallback scan gets `timeout`, and
    ///     then the connect attempt gets `timeout` again. The default is 15 seconds. `nil`
    ///     waits without a limit.
    ///   - compatibility: Accommodations for peripherals that report their GATT database
    ///     incorrectly. The default is ``GATTCompatibility/strict``. It applies to this
    ///     connection only.
    /// - Returns: A ``Peripheral`` handle for the connection.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/unexpectedPeripheral(_:)`` when `identifier` is unknown and
    ///     `fallbackScan` is `nil`.
    ///   - ``BLESwiftError/timedOut`` when the fallback scan finds no match in time.
    ///   - Any error that ``connect(_:timeout:reconnect:warningOptions:compatibility:)`` throws.
    public func connect(
        identifier: UUID,
        fallbackScan: ScanFilter? = nil,
        reconnect: ReconnectPolicy = .never,
        timeout: Duration? = .seconds(15),
        compatibility: GATTCompatibility = .strict
    ) async throws -> Peripheral {
        if let known = try knownPeripherals(withIdentifiers: [identifier]).first {
            return try await connect(known, timeout: timeout, reconnect: reconnect, compatibility: compatibility)
        }

        guard let fallbackScan else {
            throw BLESwiftError.unexpectedPeripheral(PeripheralIdentifier(uuid: identifier, name: nil))
        }

        let discovery = try await findFirst(matching: fallbackScan, timeout: timeout)
        return try await connect(discovery.peripheral, timeout: timeout, reconnect: reconnect, compatibility: compatibility)
    }

    #if os(iOS)
    /// Installs a `UIApplication.didEnterBackgroundNotification` observer that fails the scan
    /// if Apple's background-scanning restrictions require it. If `allowDuplicates` is false
    /// and services are present, it installs nothing.
    ///
    /// The observer re-enters actor isolation through `queue.async` and `assumeIsolated`, not
    /// `Task { }`, because the notification handler can fire on an arbitrary thread.
    private func installBackgroundGuardIfNeeded(scan: ActiveScan, allowDuplicates: Bool, missingServices: Bool) {
        guard allowDuplicates || missingServices else { return }

        scan.backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.assumeIsolated(onQueue: self.queue) { central in
                    if allowDuplicates {
                        central.failActiveScan(.allowDuplicatesInBackgroundNotSupported)
                    } else if missingServices {
                        central.failActiveScan(.missingServiceIdentifiersInBackground)
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Background restoration

    #if os(iOS)
    /// Returns a stream of every ``RestorationEvent``. It replays to the first consumer, in
    /// order, every event since this `Central` was created. Restoration happens at launch,
    /// usually before any consumer subscribes.
    ///
    /// Events appear only when ``Configuration/restoration`` is set.
    public func restorationEvents() -> AsyncStream<RestorationEvent> {
        restorationBroadcaster.stream()
    }
    #else
    /// Internal mirror of the iOS-only public `restorationEvents()`. See the dual-access note
    /// in `RestorationConfiguration.swift`. Off iOS, only `@testable` can reach it.
    func restorationEvents() -> AsyncStream<RestorationEvent> {
        restorationBroadcaster.stream()
    }
    #endif

    /// Reacts to a radio state change for restoration. On `.poweredOn`, it completes a staged
    /// restoration, or closes the startup window if nothing is pending. For any other state,
    /// it fails a staged restoration with ``BLESwiftError/bluetoothUnavailable`` and emits
    /// ``RestorationEvent/failedToRestoreConnection(_:error:)`` for each failure.
    private func handleRestorationStateChange(_ newState: CentralState) {
        if newState == .poweredOn {
            if let pending = pendingRestoration {
                pendingRestoration = nil
                routeRestoredPeripherals(pending)
            } else {
                closeStartupWindowIfIdle()
            }
        } else {
            if let pending = pendingRestoration {
                pendingRestoration = nil
                for peripheral in pending.peripherals {
                    restorationBroadcaster.yield(.failedToRestoreConnection(peripheral.identifier, error: BLESwiftError.bluetoothUnavailable))
                }
                log("Restoration failed: Bluetooth unavailable", level: .warning, category: "restore")
            }
            // Do not touch the `restorationTasks` in progress. The radio loss fails each one on
            // its own, and `closeStartupWindowIfIdle()` closes the window only after every entry
            // resolves.
            closeStartupWindowIfIdle()
        }
    }

    /// Routes `.poweredOn` restoration:
    /// - A restored-*connected* peripheral is adopted as a live session.
    /// - A restored-*connecting* peripheral gets its own manual reconnect task.
    /// - A restored-*disconnecting* or *disconnected* peripheral gets
    ///   ``RestorationEvent/failedToRestoreConnection(_:error:)``.
    ///
    /// The startup window closes after every outcome resolves.
    ///
    /// - Warning: No known way exists to reproduce or test the `disconnecting` and
    ///   `disconnected` paths on real hardware.
    private func routeRestoredPeripherals(_ restored: RestoredState) {
        if restored.peripherals.isEmpty {
            log("No peripherals to restore", level: .info, category: "restore")
        }

        for peripheral in restored.peripherals {
            switch peripheral.state {
            case .connected:
                adoptRestoredConnection(peripheral.identifier)
            case .connecting:
                startRestorationConnect(peripheral.identifier)
            case .disconnecting, .disconnected:
                log("Restored peripheral \(peripheral.identifier) was \(peripheral.state) — nothing to restore", level: .info, category: "restore")
                restorationBroadcaster.yield(.failedToRestoreConnection(peripheral.identifier, error: BLESwiftError.notConnected))
            }
        }

        closeStartupWindowIfIdle()
    }

    /// Adopts a restored-*connected* peripheral as a live session. No CoreBluetooth connection
    /// work is needed, so GATT operations work immediately. It emits `.connected` on
    /// ``connectionEvents()``.
    ///
    /// The policy is ``ReconnectPolicy/never``, because no `connect` call specified one.
    private func adoptRestoredConnection(_ identifier: PeripheralIdentifier) {
        guard connections[identifier] == nil else {
            restorationBroadcaster.yield(.failedToRestoreConnection(identifier, error: BLESwiftError.duplicateConnect(identifier)))
            log("Cannot adopt restored connection to \(identifier): already has a tracked entry", level: .warning, category: "restore")
            return
        }
        guard let target = manager?.retrievePeripherals(withIdentifiers: [identifier.uuid]).first else {
            restorationBroadcaster.yield(.failedToRestoreConnection(identifier, error: BLESwiftError.unexpectedPeripheral(identifier)))
            log("Cannot adopt restored connection to \(identifier): CoreBluetooth no longer knows it", level: .warning, category: "restore")
            return
        }

        // Set up event delivery before the session goes live. This is idempotent with the early
        // setup in the `.willRestoreState` case of `handle(_: CentralEvent)`.
        target.eventHandler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated(onQueue: self.queue) { $0.handle(event, from: identifier) }
        }

        connections[identifier] = .connected(Session.adopted(
            identifier: identifier,
            peripheral: target,
            warningOptions: configuration.warningOptions
        ))
        log("Restored connection to \(identifier)", level: .info, category: "restore")
        connectionBroadcaster.yield(.connected(identifier))
        restorationBroadcaster.yield(.restoredConnection(identifier))
    }

    /// Issues the manual reconnect for a restored-*connecting* peripheral. CoreBluetooth
    /// restores the attempt but does not complete it, so BLESwift must connect explicitly. The
    /// default timeout is 15 s. ``RestorationConfiguration`` can change it.
    private func startRestorationConnect(_ identifier: PeripheralIdentifier) {
        let timeout = configuration.restoration?.connectingTimeout ?? .seconds(15)
        log("Restored peripheral \(identifier) was connecting — issuing manual re-connect (timeout: \(timeout))", level: .info, category: "restore")
        restorationTasks[identifier] = Task { [weak self] in
            await self?.runRestorationConnect(identifier: identifier, timeout: timeout)
        }
    }

    /// The body of one ``restorationTasks`` entry. It makes one manual connect attempt for
    /// `identifier`, then removes its own entry and closes the startup window if idle.
    ///
    /// It calls ``establishConnection(identifier:policy:timeout:warningOptions:)`` directly and
    /// not `connect(...)`, because the public method's `pendingRestoration` guard keeps *user*
    /// calls out of this window.
    private func runRestorationConnect(identifier: PeripheralIdentifier, timeout: Duration) async {
        // Guard against a race between expiration and routing. This task's body runs one hop
        // after it starts. If the startup background task expired in that gap, this is the one
        // place that must still fail the connect, even though the window is closed.
        guard startupWindowOpen else {
            // Silent when cancelled, because a cancel is a teardown and not an expiration.
            if !Task.isCancelled {
                log("Startup window closed before the restoration connect could start — failing restoration for \(identifier)", level: .warning, category: "restore")
                restorationBroadcaster.yield(.failedToRestoreConnection(identifier, error: BLESwiftError.startupBackgroundTaskExpired))
            }
            restorationTasks.removeValue(forKey: identifier)
            return
        }

        do {
            // Reserve the slot synchronously. This throws `.duplicateConnect` if a user
            // `connect(id)` for the same restored id arrived first.
            try reserveConnectingSlot(
                identifier: identifier,
                policy: .never,
                timeout: timeout,
                warningOptions: configuration.warningOptions,
                compatibility: .strict
            )
            _ = try await establishConnection(
                identifier: identifier,
                policy: .never,
                timeout: timeout,
                warningOptions: configuration.warningOptions
            )
            log("Restored connection to \(identifier) via manual re-connect", level: .info, category: "restore")
            restorationBroadcaster.yield(.restoredConnection(identifier))
        } catch {
            log("Failed to restore connection to \(identifier): \(error)", level: .warning, category: "restore")
            restorationBroadcaster.yield(.failedToRestoreConnection(identifier, error: error))
        }
        restorationTasks.removeValue(forKey: identifier)
        closeStartupWindowIfIdle()
    }

    /// Reacts when iOS expires the startup background task before restoration finished. A
    /// staged but unrouted ``pendingRestoration`` and every ``restorationTasks`` entry in
    /// progress fail with ``BLESwiftError/startupBackgroundTaskExpired``.
    private func handleStartupBackgroundTaskExpiration() {
        guard startupWindowOpen else { return }
        log("Startup background task expired during restoration", level: .warning, category: "restore")

        if let pending = pendingRestoration {
            pendingRestoration = nil
            for peripheral in pending.peripherals {
                restorationBroadcaster.yield(.failedToRestoreConnection(peripheral.identifier, error: BLESwiftError.startupBackgroundTaskExpired))
            }
        }

        // Snapshot the keys first. Never iterate a map while changing it.
        for identifier in Array(restorationTasks.keys) {
            // Each task's own catch removes its entry after the cancel. The code below closes the
            // window unconditionally.
            failPendingConnect(for: identifier, error: BLESwiftError.startupBackgroundTaskExpired)
        }

        endStartupBackgroundTask()
    }

    /// Closes the startup restoration window after every restoration outcome resolves. It does
    /// nothing while anything is pending, so it is safe to call at any time.
    private func closeStartupWindowIfIdle() {
        guard pendingRestoration == nil, restorationTasks.isEmpty else { return }
        endStartupBackgroundTask()
    }

    /// Closes the startup restoration window and ends the platform background task (see
    /// `StartupBackgroundTaskRunning`) exactly once. ``startupWindowOpen`` makes it idempotent.
    /// It does nothing if restoration was never enabled.
    private func endStartupBackgroundTask() {
        guard startupWindowOpen else { return }
        startupWindowOpen = false
        startupBackgroundTask.end()
        log("Startup restoration window closed", level: .debug, category: "restore")
    }

    // MARK: - Logging

    /// Writes `message` to the `swift-log` `Logger` of ``configuration``. It is BLESwift's
    /// single internal log call site.
    private func log(_ message: @autoclosure () -> Logger.Message, level: Logger.Level, category: String) {
        configuration.logger.log(level: level, message(), metadata: ["category": .string(category)])
    }
}

// MARK: - Connection state machine

/// The internal connection state machine of `Central` for each peripheral. It is file-private,
/// like its associated structs. ``Central/connectionState(of:)`` projects it into the public
/// ``ConnectionState``. It has no `.idle` case. No ``Central/connections`` entry means idle.
private enum PeripheralPhase {
    /// A connection attempt is in progress.
    case connecting(Connecting)
    /// The peripheral is connected.
    case connected(Session)
    /// The peripheral is disconnecting, after an explicit `disconnect(_:)` or after
    /// `cancelAllOperations` cancelled a pending connection attempt.
    case disconnecting(Disconnecting)
}

/// One auto-reconnect loop of a peripheral, tracked in ``Central/reconnectLoops``. It pairs
/// the loop's `Task` with the generation that it started with. See
/// ``Central/clearReconnectLoopIfCurrent(id:generation:)``.
private struct ReconnectLoop {
    var task: Task<Void, Never>
    var generation: UInt64
}

/// The GATT operation for which a ``GATTCompatibility`` bypass skipped a property check, as
/// part of a ``CompatWarnKey``.
private enum CompatOperation: Hashable {
    case read
    case write
    case notify
}

/// One (peripheral, characteristic, operation) triple. `Central.warnedCompatBypass` uses it
/// to log a compatibility-bypass warning once for each triple.
private struct CompatWarnKey: Hashable {
    let peripheral: PeripheralIdentifier
    let characteristic: CharacteristicIdentifier
    let operation: CompatOperation
}

/// State of a connection attempt in progress. It holds the peripheral's pending connect
/// continuation and the `stopping` flag of the two-phase cancel.
private struct Connecting {
    let identifier: PeripheralIdentifier
    let peripheral: any PeripheralRemote
    let policy: ReconnectPolicy
    let timeout: Duration?
    let warningOptions: WarningOptions
    let compatibility: GATTCompatibility
    /// Whether the connect required ANCS. It has an effect on iOS only and is always `false`
    /// elsewhere. Reconnect attempts reuse it.
    let requiresANCS: Bool
    /// The pending connect continuation. It is `nil` when the slot is reserved but not
    /// attached (between `reserveConnectingSlot`, which writes this entry, and `awaitConnect`,
    /// which attaches the continuation), and after it is taken, resumed, and cleared.
    /// `Central.handleTermination(identifier:error:)` resumes it exactly once. A cancellation
    /// request never resumes it directly.
    var continuation: CheckedContinuation<Peripheral, Error>?
    /// Non-`nil` after a cancellation (task cancellation, timeout, or `cancelAllOperations`)
    /// was requested for this attempt. It is the error that `continuation` resumes with after
    /// CoreBluetooth confirms.
    var stopping: Error?
}

/// State of one established connection, including all of its GATT bookkeeping. The disconnect
/// cleanup drops the bookkeeping together with the connection, and peripherals stay isolated
/// from each other at no extra cost.
private struct Session {
    let identifier: PeripheralIdentifier
    let peripheral: any PeripheralRemote
    let policy: ReconnectPolicy
    let timeout: Duration?
    let warningOptions: WarningOptions
    let compatibility: GATTCompatibility
    /// See `Connecting.requiresANCS`. The session carries it, so the reconnect loop reuses it.
    let requiresANCS: Bool

    // The init is explicit because the synthesized memberwise init is private
    // (`nextWaiterTokenValue` is a private stored property) and so not accessible at file scope.
    init(
        identifier: PeripheralIdentifier,
        peripheral: any PeripheralRemote,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions,
        compatibility: GATTCompatibility,
        requiresANCS: Bool = false
    ) {
        self.identifier = identifier
        self.peripheral = peripheral
        self.policy = policy
        self.timeout = timeout
        self.warningOptions = warningOptions
        self.compatibility = compatibility
        self.requiresANCS = requiresANCS
    }

    // MARK: - GATT

    /// Per-characteristic FIFO tail chain. See
    /// `Central.runOnFIFO(identifier:characteristic:operation:)`.
    var fifoTails: [CharacteristicIdentifier: Task<Void, Never>] = [:]

    /// The RSSI counterpart to ``fifoTails``. `readRSSI()` has no characteristic, so it uses a
    /// single tail and not a per-characteristic map. See
    /// `Central.runRSSISerialized(identifier:operation:)`.
    var rssiTail: Task<Void, Never>?

    /// The pending read continuation of each characteristic. Only one slot exists, because
    /// ``fifoTails`` guarantees it. The code removes the continuation and then resumes it.
    var pendingReads: [CharacteristicIdentifier: CheckedContinuation<Data, Error>] = [:]

    /// The pending write continuation of each characteristic that is being written
    /// (`.withResponse` only). `.withoutResponse` completes immediately and never registers
    /// here. See ``pendingReads``.
    var pendingWrites: [CharacteristicIdentifier: CheckedContinuation<Void, Error>] = [:]

    /// The pending notify-state-change continuation of each characteristic. It resumes with
    /// the resulting `isNotifying` value.
    var pendingNotifyStateChanges: [CharacteristicIdentifier: CheckedContinuation<Bool, Error>] = [:]

    /// The single pending RSSI-read continuation, if any. Only one slot exists, because
    /// ``rssiTail`` guarantees it.
    var pendingRSSIRead: CheckedContinuation<Int, Error>?

    /// Pending service-discovery waiters, keyed by an increasing token and **not** by service.
    /// `didDiscoverServices(error:)` carries no service identifier, so every waiter resumes on
    /// every completion and then checks its own service again. The token lets the code remove
    /// a single cancelled waiter and leave the others.
    var pendingDiscoverServices: [UInt64: CheckedContinuation<Void, Error>] = [:]

    /// Pending characteristic-discovery waiters, keyed by service (which
    /// `didDiscoverCharacteristics(service:error:)` does carry) and then by waiter token.
    var pendingDiscoverCharacteristics: [ServiceIdentifier: [UInt64: CheckedContinuation<Void, Error>]] = [:]

    /// Pending waiters for `.isReadyToSendWriteWithoutResponse`. They are not keyed by
    /// characteristic, because CoreBluetooth's readiness signal is peripheral-wide.
    var pendingWriteWithoutResponseReady: [UInt64: CheckedContinuation<Void, Error>] = [:]

    /// The pending descriptor-read continuation of each descriptor. Only one slot exists,
    /// because the parent characteristic's FIFO lane guarantees it.
    var pendingDescriptorReads: [DescriptorIdentifier: CheckedContinuation<Data, Error>] = [:]

    /// The pending descriptor-write continuation of each descriptor that is being written
    /// (descriptor writes are always with-response). See ``pendingDescriptorReads``.
    var pendingDescriptorWrites: [DescriptorIdentifier: CheckedContinuation<Void, Error>] = [:]

    /// Pending descriptor-discovery waiters, keyed by characteristic and then by waiter token.
    var pendingDiscoverDescriptors: [CharacteristicIdentifier: [UInt64: CheckedContinuation<Void, Error>]] = [:]

    // MARK: - GATT enumeration cache

    /// Whether a full service enumeration has completed for this connection. Targeted
    /// discovery can check an identifier, but "list all services" has none, so this flag is the
    /// cache. It resets to `false` on `didModifyServices`.
    var didEnumerateServices = false

    /// Whether the one-time `discoverServices(nil)` of ``GATTCompatibility/DiscoveryMode/all``
    /// has run for this connection. It limits `.all` to one unfiltered discovery for each
    /// connection.
    var didDiscoverAllServices = false

    /// Services whose characteristics are fully enumerated for this connection.
    /// `didModifyServices` removes invalidated entries.
    var enumeratedCharacteristicServices: Set<ServiceIdentifier> = []

    /// Characteristics whose descriptors are fully enumerated for this connection.
    var enumeratedDescriptorCharacteristics: Set<CharacteristicIdentifier> = []

    // MARK: - Notifications

    /// The active notification subscription of each characteristic that is listened to. It
    /// lives inside `Session`, so the disconnect cleanup drops it.
    var notificationSubscriptions: [CharacteristicIdentifier: NotificationSubscription] = [:]

    /// The pump task of each subscriber of
    /// `Peripheral.notifications(for:policy:survivesReconnect:)`. It is a ledgered `Task { }`
    /// site (see
    /// `Central.startNotificationPump(peripheral:characteristic:token:survivesReconnect:deliver:finish:)`).
    var notificationPumps: [UUID: Task<Void, Never>] = [:]

    /// Tokens registered with `survivesReconnect: true`. At a disconnect, the code intersects
    /// them with each subscription's `subscriberTokens`. The result decides which tokens park
    /// in `Central.dormantNotifications` and which finish.
    var notificationSurvivorTokens: Set<UUID> = []

    /// The re-arm task in progress after this session's reconnect, if any. It is a ledgered
    /// `Task` site (see `Central.rearmDormantNotifications(_:)`).
    /// `Central.failPendingGATTContinuations(for:error:)` cancels it.
    var rearmTask: Task<Void, Never>?

    // MARK: - L2CAP

    /// Pending L2CAP channel-open waiters, keyed by the same increasing token as the GATT
    /// discovery waiters. They match in FIFO order: a `didOpenL2CAPChannel` resolves the
    /// oldest waiter.
    var pendingL2CAPOpens: [UInt64: CheckedContinuation<any L2CAPChannelRemote, Error>] = [:]

    /// The transport of every open L2CAP channel, by the registration token of its
    /// `L2CAPChannel` handle. The disconnect cleanup or an explicit `L2CAPChannel.close()`
    /// tears it down.
    var l2capChannels: [UUID: any L2CAPChannelRemote] = [:]

    /// Builds the `Session` for every **adoption** path. The peripheral is already connected,
    /// so no `connect` call specified a policy or timeout. The policy is
    /// ``ReconnectPolicy/never``.
    static func adopted(
        identifier: PeripheralIdentifier,
        peripheral: any PeripheralRemote,
        warningOptions: WarningOptions
    ) -> Session {
        Session(
            identifier: identifier,
            peripheral: peripheral,
            policy: .never,
            timeout: nil,
            warningOptions: warningOptions,
            compatibility: .strict
        )
    }

    /// Backs ``nextGATTWaiterToken()``.
    private var nextWaiterTokenValue: UInt64 = 0

    /// Returns a new, increasing token that identifies one GATT waiter, so the code can remove
    /// a single cancelled waiter by key and leave the others.
    mutating func nextGATTWaiterToken() -> UInt64 {
        defer { nextWaiterTokenValue += 1 }
        return nextWaiterTokenValue
    }
}

/// The active notification subscription of one characteristic. It has the raw-`Data`
/// multicast that every subscriber shares, and the reference count that drives the
/// `setNotifyValue` lifecycle.
private struct NotificationSubscription {
    /// The raw-`Data` multicast. Each subscriber decodes in its own decode layer, so one
    /// subscriber's decode failure cannot affect the others.
    let broadcaster = ThrowingBroadcaster<Data>()

    /// One token for each live subscriber. A token set and not a bare count makes the release
    /// idempotent, so a double release cannot underflow the reference count.
    var subscriberTokens: Set<UUID> = []

    /// Whether the `setNotifyValue(true)` handshake has completed. Notifications that arrive
    /// before the confirmation are still multicast. Late joiners wait for this flag.
    var enableConfirmed = false

    /// Joiners that wait for ``enableConfirmed``, by subscriber token. The code removes a
    /// waiter and then resumes it.
    var enableWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
}

/// The notification subscriptions of one peripheral, parked between an unexpected disconnect
/// and a successful auto-reconnect. See `Central.dormantNotifications`.
private struct DormantNotifications {
    /// The disconnect's error. The surviving streams finish with it if the reconnect never
    /// succeeds.
    let disconnectError: Error
    /// For each characteristic, the surviving subscriber tokens and the parked pump
    /// continuation of each token.
    var characteristics: [CharacteristicIdentifier: DormantSubscription]
    /// Surviving pump tasks by token, so that a typed stream's termination during the gap can
    /// cancel one. On re-arm, the code moves them back into `Session.notificationPumps`.
    var pumps: [UUID: Task<Void, Never>]
}

/// The parked survivors of one characteristic. See ``DormantNotifications``.
private struct DormantSubscription {
    /// The surviving subscriber tokens.
    var tokens: Set<UUID>
    /// Continuations of pumps parked in
    /// `Central.awaitResubscription(identifier:characteristic:token:)`, by token. The code
    /// removes a continuation and then resumes it.
    var waiters: [UUID: CheckedContinuation<AsyncThrowingStream<Data, Error>, Error>] = [:]
}

/// A single-consumer box around an `AsyncThrowingStream` iterator. It lets
/// `Central.performFlush(peripheral:characteristic:quietPeriod:)` call `await next()` again
/// in successive `withTimeout` races, whose `@Sendable` closures cannot capture a mutable
/// local iterator.
///
/// `iterator` is `nonisolated(unsafe)`. The type is not `@unchecked Sendable`, which a grep
/// check forbids. Access is strictly sequential by construction: each `withTimeout` window
/// completes before the next begins.
private final class SequentialAccessIterator<Element: Sendable>: Sendable {
    nonisolated(unsafe) private var iterator: AsyncThrowingStream<Element, Error>.Iterator

    init(_ stream: AsyncThrowingStream<Element, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    /// Advances the boxed iterator. Callers must keep the strictly sequential access that the
    /// type documents.
    func next() async throws -> Element? {
        try await iterator.next()
    }
}

/// State while disconnecting, after an explicit `disconnect` call (`continuation` is
/// non-`nil`) or after `cancelAllOperations` cancelled a pending connect attempt (`nil`).
private struct Disconnecting {
    let identifier: PeripheralIdentifier
    let peripheral: any PeripheralRemote
    /// The `disconnect()` call's continuation, if an explicit disconnect entered this state.
    var continuation: CheckedContinuation<Void, Error>?
    /// The connect attempt's continuation, carried over if `disconnect` or
    /// `cancelAllOperations` interrupted a `.connecting` phase. With `continuation`, it
    /// resolves (with `connectFailureReason`) when the cleanup runs.
    var connectContinuation: CheckedContinuation<Peripheral, Error>?
    /// The error that `connectContinuation` resolves with: `.explicitDisconnect` for
    /// `disconnect`, or the error from `cancelAllOperations(error:)`.
    let connectFailureReason: Error
}
