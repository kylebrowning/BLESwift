//
//  Central.swift
//  BLESwift
//

// `@preconcurrency`: CoreBluetooth's types aren't `Sendable` (never mark them
// unchecked-`Sendable`). `stopAndExtractState()` hands a `CBCentralManager` back across
// this actor's isolation boundary as a one-time ownership transfer, which only type-checks
// under `@preconcurrency`'s unaudited Sendability — without it, returning a non-Sendable
// type from an actor-isolated method is rejected outright.
import BLESwiftCore
@preconcurrency import CoreBluetooth
import Dispatch
import Foundation
import Logging
import Synchronization
#if os(iOS)
import UIKit
#endif

/// BLESwift's entry point: an actor wrapping a single `CBCentralManager`.
///
/// `Central`'s isolation is tied directly to the `DispatchSerialQueue` its `CBCentralManager`
/// delivers delegate callbacks on (see ``unownedExecutor``), so every `CentralDelegateProxy`
/// callback already runs on `Central`'s own executor and forwards into actor-isolated code
/// via `assumeIsolated` with no thread hop.
public actor Central {

    /// The `DispatchSerialQueue` backing ``unownedExecutor`` and CoreBluetooth's delegate callbacks.
    nonisolated let queue: DispatchSerialQueue

    /// Ties this actor's isolation to ``queue`` (SE-0424 custom executors). Public only
    /// because it satisfies the `Actor` protocol requirement — not for direct client use.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// The CoreBluetooth shim this `Central` drives — a real `CBCentralManager` in
    /// production, a `FakeCentral` in tests. `Optional var`, not `let`: ``stopAndExtractState()``
    /// nils this out to hand off its `CBCentralManager` (not `Sendable`) across the isolation
    /// boundary, which is only sound if `Central` gives up its own reference in the same call.
    private var manager: (any CentralManaging)?

    /// Read-only access to ``manager`` for same-module extensions of `Central` (`private` is file-scoped).
    internal var shim: (any CentralManaging)? { manager }

    /// This `Central`'s `CBCentralManagerDelegate`, strongly owned here so it outlives the gap
    /// between creation and `CBCentralManager(delegate:queue:options:)` — `willRestoreState`
    /// can arrive before this `Central` wires its handler. Non-`nil` only for
    /// ``init(configuration:)``; every other init path wires event delivery via `eventHandler` instead.
    private let proxy: CentralDelegateProxy?

    private let configuration: Configuration

    /// Backs the nonisolated, synchronously-readable ``state`` snapshot. `Mutex` rather than
    /// actor-isolated storage so ``state`` can be read without `await` from any isolation
    /// domain; the actor-isolated ``handle(_:)`` is the only writer.
    private let stateBox = Mutex<CentralState>(.unknown)

    /// Multicasts every ``CentralState`` transition to every ``stateEvents()`` subscriber,
    /// replaying the latest value to late subscribers.
    private let stateBroadcaster = Broadcaster<CentralState>(replay: .latest)

    /// The in-progress scan, if any — `nil` when no
    /// ``scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)`` call is active.
    /// At most one at a time (CoreBluetooth exposes a single physical scanner).
    private var activeScan: ActiveScan?

    /// Backs the nonisolated ``isScanning`` snapshot — same rationale as ``stateBox``.
    private let isScanningBox = Mutex<Bool>(false)

    /// This `Central`'s per-peripheral connection state machine, keyed by ``PeripheralIdentifier``.
    /// Absence of an entry IS that peripheral's idle state — there is no `.idle` case in
    /// ``PeripheralPhase``; an entry exists only while connecting, connected, or disconnecting.
    private var connections: [PeripheralIdentifier: PeripheralPhase] = [:]

    /// One independent auto-reconnect loop per peripheral, running while that peripheral has
    /// no ``connections`` entry (mid-backoff) — a ledgered unstructured `Task` site. Cancelled
    /// by that peripheral's own disconnect, a new `connect`, `cancelAllOperations`/
    /// `disconnectAll()`, or `deinit`.
    private var reconnectLoops: [PeripheralIdentifier: ReconnectLoop] = [:]

    /// Actor-wide monotonic generation allocator, incremented whenever
    /// ``scheduleReconnect(identifier:policy:timeout:warningOptions:)`` starts a new loop.
    /// Each ``ReconnectLoop`` stores its generation; see ``clearReconnectLoopIfCurrent(id:generation:)``.
    private var reconnectGeneration: UInt64 = 0

    /// Multicasts every ``ConnectionEvent``. Replay `.none` — unlike ``stateBroadcaster``,
    /// there's no single current-value snapshot to replay (``connectionState(of:)``/
    /// ``connectedPeripherals`` serve that purpose).
    private let connectionBroadcaster = Broadcaster<ConnectionEvent>(replay: .none)

    /// Per-peripheral `didModifyServices` broadcaster registry, for
    /// ``Peripheral/serviceChanges()`` — each ``PeripheralIdentifier`` gets its own
    /// broadcaster so one peripheral's invalidations never reach another's subscribers.
    ///
    /// `nonisolated` so ``Peripheral/serviceChanges()`` can fetch its `AsyncStream`
    /// synchronously; ``ServiceChangesRegistry`` is itself `Sendable` and internally `Mutex`-guarded.
    nonisolated let serviceChangesRegistry = ServiceChangesRegistry()

    // MARK: - Background restoration state

    /// Multicasts every ``RestorationEvent``. Replay `.allUntilFirstConsumer`: restoration
    /// happens during app launch, typically before any consumer has subscribed, so every
    /// event is buffered and replayed in order to the first ``restorationEvents()`` consumer.
    private let restorationBroadcaster = Broadcaster<RestorationEvent>(replay: .allUntilFirstConsumer)

    /// The restored state captured by `CentralEvent.willRestoreState`, held until the
    /// radio's first `.poweredOn` routes it (``routeRestoredPeripherals(_:)``).
    private var pendingRestoration: RestoredState?

    /// One in-flight manual re-connect per restored-*connecting* peripheral — CoreBluetooth
    /// never completes a restored-connecting attempt on its own. A ledgered `Task` site
    /// (like ``reconnectLoops``), keyed by the peripheral being re-connected; each entry
    /// removes itself on completion.
    private var restorationTasks: [PeripheralIdentifier: Task<Void, Never>] = [:]

    /// The startup background-task seam protecting the restoration window — a real
    /// `UIApplication` background task on iOS with restoration enabled, a no-op otherwise.
    private let startupBackgroundTask: any StartupBackgroundTaskRunning

    /// Whether the startup restoration window is still open. Guards
    /// ``endStartupBackgroundTask()``'s idempotence; always `false` when restoration is disabled.
    private var startupWindowOpen = false

    /// Creates a `Central`, synchronously creating its underlying `CBCentralManager` on a
    /// fresh, dedicated `DispatchSerialQueue`. Manager creation is synchronous (not deferred
    /// behind an async `start()`) so background restoration events arriving before an async
    /// step could run are never missed.
    ///
    /// - Parameter configuration: Start-time options. Defaults to `Configuration()`. On iOS,
    ///   a non-`nil` `configuration.restoration` registers its identifier with CoreBluetooth
    ///   at manager creation and opens the startup restoration window.
    public init(configuration: Configuration = Configuration()) {
        let queue = DispatchSerialQueue(label: "com.bleswift.Central")
        self.queue = queue
        self.configuration = configuration

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

        // `self` is fully initialized, so it can now be captured. Sets `proxy.handler`
        // directly (see `proxy`'s doc comment) rather than `manager.eventHandler`.
        proxy.handler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated { $0.handle(event) }
        }

        // Opens the startup background-time window (a no-op runner off-iOS/without
        // restoration); deferred until after manager creation since `self` can't be
        // captured by an escaping closure until every stored property is initialized.
        if configuration.restoration != nil {
            startupBackgroundTask.begin { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.assumeIsolated { central in
                        central.handleStartupBackgroundTaskExpiration()
                    }
                }
            }
        }
    }

    /// Creates a `Central` adopting an existing `CBCentralManager` (and, optionally, an
    /// already-connected `CBPeripheral`) — the counterpart to ``stopAndExtractState()``.
    ///
    /// - Important: `callbackQueue` **must be the exact `DispatchSerialQueue` instance**
    ///   `manager` was created with. `CBCentralManager` has no public API to report which
    ///   queue it delivers callbacks on, so a mismatch is not detectable eagerly — it
    ///   surfaces only as an `assumeIsolated` trap on the first off-queue callback. If
    ///   `manager` was created with `queue: nil`, pass `DispatchQueue.main as! DispatchSerialQueue`.
    ///
    /// - Parameters:
    ///   - manager: The existing `CBCentralManager` to adopt, replacing its current delegate.
    ///   - connectedPeripherals: Every already-connected `CBPeripheral`, if any, adopted as a
    ///     live session with ``ReconnectPolicy/never`` (no `connect` call existed to specify
    ///     one). Defaults to `[]`.
    ///   - callbackQueue: The exact `DispatchSerialQueue` `manager` delivers callbacks on.
    ///     Required — see the invariant above.
    ///   - configuration: Start-time options. `showPowerAlert` has no effect here since
    ///     `manager` already exists. Defaults to `Configuration()`.
    public init(
        adopting manager: CBCentralManager,
        connectedPeripherals: [CBPeripheral] = [],
        callbackQueue: DispatchSerialQueue,
        configuration: Configuration = Configuration()
    ) {
        self.queue = callbackQueue
        self.configuration = configuration

        // Restoration can never apply: a restore identifier must be supplied when the
        // manager is *created*, and this manager already exists.
        self.startupBackgroundTask = NoOpStartupBackgroundTask()

        // `manager` already exists, so event delivery is wired via `eventHandler` instead
        // of a stored `proxy`.
        self.proxy = nil
        self.manager = manager

        // Seed the synchronous `state` snapshot from the adopted manager's current state —
        // it may already be past `centralManagerDidUpdateState(_:)` by adoption time, and
        // that callback won't fire again to correct a stale `.unknown`.
        let adoptedState = CentralState(manager.state)
        stateBox.withLock { $0 = adoptedState }
        stateBroadcaster.yield(adoptedState)

        // Adopt each `connectedPeripherals` entry as a live session (`.never` policy — no
        // `connect` call existed to specify one). Every direct stored-property write must
        // precede the `eventHandler` closures below — capturing `self` (even weakly) counts
        // as `self` escaping (SE-0327), after which direct mutation is no longer permitted.
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

        // `self` is fully initialized, so it can now be captured. Event delivery is wired
        // last, after every session already exists.
        manager.eventHandler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated { $0.handle(event) }
        }
        for (identifier, connectedPeripheral) in adopted {
            connectedPeripheral.eventHandler = { [weak self] event in
                guard let self else { return }
                self.assumeIsolated { $0.handle(event, from: identifier) }
            }
        }
    }

    /// Creates a `Central` driving a custom backend — the seam that lets a scriptable fake
    /// (`BLESwiftTestSupport`'s `FakeCentral`) or any other `CentralManaging` conformance
    /// stand in for a real `CBCentralManager`. Production code uses ``init(configuration:)``
    /// or ``init(adopting:connectedPeripherals:callbackQueue:configuration:)`` instead.
    ///
    /// - Important: `queue` **must be the exact `DispatchSerialQueue` instance** `backend`
    ///   confines its event deliveries to — a mismatch is not detectable eagerly and
    ///   surfaces only as an `assumeIsolated` trap on the first off-queue event.
    ///
    /// - Important: **Retention.** Unlike the production initializers, the closures this
    ///   installs on `backend.eventHandler` (and each adopted peripheral's) capture `self`
    ///   **strongly** — `backend` is itself strongly held by this `Central`, so
    ///   `Central` → `backend` → closure → `Central` is a deliberate cycle. `backend` alone
    ///   keeps this `Central` alive for as long as `backend` exists. ``stopAndExtractState()``
    ///   does not break this cycle (it only recognizes a real `CBCentralManager`-backed
    ///   `manager`). To release deterministically, clear it explicitly:
    ///   `backend.eventHandler = nil` (and each adopted peripheral's).
    ///
    /// - Parameters:
    ///   - backend: The `CentralManaging` conformance to drive.
    ///   - queue: The `DispatchSerialQueue` `backend`'s events are confined to — see the
    ///     invariant above.
    ///   - configuration: Start-time options. Defaults to `Configuration()`.
    ///   - startupBackgroundTask: An injected startup background-task seam; `nil` (the
    ///     default) uses a no-op.
    ///   - connectedPeripherals: `PeripheralRemote`s to adopt as live sessions, mirroring
    ///     ``init(adopting:connectedPeripherals:callbackQueue:configuration:)``'s adoption
    ///     structure. Defaults to `[]`.
    public init(
        backend: any CentralManaging,
        queue: DispatchSerialQueue,
        configuration: Configuration = Configuration(),
        startupBackgroundTask: (any StartupBackgroundTaskRunning)? = nil,
        connectedPeripherals: [any PeripheralRemote] = []
    ) {
        self.queue = queue
        self.configuration = configuration
        self.manager = backend
        self.proxy = nil

        let runner = startupBackgroundTask ?? NoOpStartupBackgroundTask()
        self.startupBackgroundTask = runner
        self.startupWindowOpen = configuration.restoration != nil

        // Every direct stored-property write must precede the `eventHandler` closures below
        // — see the matching comment in `init(adopting:...)`.
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

        // `self` is fully initialized, so it can now be captured. Wiring is hopped onto
        // `queue` via `queue.sync` (safe: nothing else can be running on `queue` yet)
        // because `backend`'s `eventHandler` setter may be queue-confined, as
        // `FakeCentral`/`FakePeripheral`'s are.
        //
        // Captures `self` strongly (unlike the production paths' `[weak self]`) — see the
        // Retention note on this initializer's doc comment.
        queue.sync {
            backend.eventHandler = { event in
                self.assumeIsolated { $0.handle(event) }
            }
            for (identifier, connectedPeripheral) in adopted {
                connectedPeripheral.eventHandler = { event in
                    self.assumeIsolated { $0.handle(event, from: identifier) }
                }
            }
        }

        if configuration.restoration != nil {
            runner.begin { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.assumeIsolated { central in
                        central.handleStartupBackgroundTaskExpiration()
                    }
                }
            }
        }
    }

    /// Cancels any in-flight auto-reconnect loop and restoration re-connect. Actors support
    /// ordinary `deinit`s that touch isolated storage directly, so no `Task` hop is needed.
    deinit {
        for loop in reconnectLoops.values {
            loop.task.cancel()
        }
        for task in restorationTasks.values {
            task.cancel()
        }
        startupBackgroundTask.end()
    }

    /// Stops this `Central`, detaching the underlying `CBCentralManager`'s delegate, and
    /// hands the manager back to the caller so it can be adopted by other code.
    ///
    /// - Returns: The underlying `CBCentralManager`, and every `CBPeripheral` this `Central`
    ///   was connected to, sorted by identifier for determinism.
    /// - Throws: ``BLESwiftError/stopped`` if already stopped, not backed by a real
    ///   `CBCentralManager`, or any tracked peripheral has a connection attempt or disconnect
    ///   in progress (extracting mid-attempt would strand its pending continuation forever).
    public func stopAndExtractState() throws -> (manager: CBCentralManager, peripherals: [CBPeripheral]) {
        guard let currentManager = manager else {
            throw BLESwiftError.stopped
        }
        guard let cbManager = currentManager as? CBCentralManager else {
            throw BLESwiftError.stopped
        }

        // Any entry that isn't `.connected` blocks extraction — see the throws docs above.
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
        closeAllSessionsL2CAPChannels(error: BLESwiftError.stopped)
        connections.removeAll()

        // Give up this actor's own reference before returning `cbManager` — required, not
        // just tidy; see ``manager``'s doc comment.
        manager = nil
        cbManager.delegate = nil
        // Detach every extracted peripheral's event delivery too — its new owner installs
        // its own delegate.
        for (_, peripheral) in connectedPeripherals {
            peripheral.eventHandler = nil
        }
        proxy?.handler = nil

        return (cbManager, connectedPeripherals.map(\.peripheral))
    }

    // MARK: - Public surface

    /// The current state of the Bluetooth radio. A synchronous snapshot, readable without
    /// `await` from any isolation domain.
    public nonisolated var state: CentralState {
        stateBox.withLock { $0 }
    }

    /// The app's current Bluetooth authorization status.
    ///
    /// - Note: Returns `.notDetermined` after ``stopAndExtractState()`` has been called —
    ///   this `Central` no longer owns a manager to ask at that point.
    public var authorization: BluetoothAuthorization {
        guard let manager else { return .notDetermined }
        return type(of: manager).bluetoothAuthorization
    }

    /// Whether a scan is currently active. A synchronous snapshot, readable without
    /// `await` from any isolation domain.
    public nonisolated var isScanning: Bool {
        isScanningBox.withLock { $0 }
    }

    /// Returns a multicast stream of every ``CentralState`` transition, replaying the most
    /// recent state to a late subscriber.
    public func stateEvents() -> AsyncStream<CentralState> {
        stateBroadcaster.stream()
    }

    // MARK: - Connection lifecycle

    /// A synchronous-to-read (but actor-isolated) snapshot of `id`'s connection lifecycle.
    /// `.disconnected` when `id` has no tracked entry. See ``ConnectionState``.
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

    /// A snapshot of every currently-connected peripheral's handle, sorted by
    /// `id.uuid.uuidString` for determinism.
    public var connectedPeripherals: [Peripheral] {
        connections.compactMap { identifier, phase -> Peripheral? in
            guard case .connected = phase else { return nil }
            return Peripheral(id: identifier, central: self)
        }.sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }
    }

    /// Returns a multicast stream of every ``ConnectionEvent``, across every peripheral.
    /// See ``ConnectionEvent`` for the full event vocabulary and replay semantics (none — a
    /// late subscriber only sees events from the point it subscribes; use
    /// ``connectionState(of:)``/``connectedPeripherals`` for the current snapshot).
    public func connectionEvents() -> AsyncStream<ConnectionEvent> {
        connectionBroadcaster.stream()
    }

    /// Connects to a known peripheral.
    ///
    /// BLESwift supports N concurrent peripheral connections — connecting to any peripheral
    /// other than `id` never conflicts. Fails immediately with
    /// ``BLESwiftError/duplicateConnect(_:)`` only if `id` itself already has a tracked
    /// entry. A new `connect` call to `id` cancels any in-flight auto-reconnect loop for
    /// `id` and resets its ``ReconnectPolicy`` to whatever `reconnect` specifies.
    ///
    /// - Parameters:
    ///   - id: The peripheral to connect to.
    ///   - timeout: How long to wait before throwing ``BLESwiftError/connectionTimedOut``.
    ///     Defaults to 15 seconds; `nil` waits indefinitely. On timeout, the pending
    ///     CoreBluetooth attempt is cancelled and its confirmation awaited before throwing.
    ///   - reconnect: What to do if this connection is later lost unexpectedly. Defaults to
    ///     ``ReconnectPolicy/never``.
    ///   - warningOptions: Per-connection override for iOS system alerts on suspended-app
    ///     connection events. Defaults to ``Configuration``'s `warningOptions`.
    /// - Returns: A ``Peripheral`` handle once connected.
    /// - Throws: ``BLESwiftError/duplicateConnect(_:)``, ``BLESwiftError/unexpectedPeripheral(_:)``
    ///   if `id` is not known to CoreBluetooth, ``BLESwiftError/connectionTimedOut``,
    ///   ``BLESwiftError/operationCancelled`` on task cancellation, or whatever error
    ///   CoreBluetooth reports.
    public func connect(
        _ id: PeripheralIdentifier,
        timeout: Duration? = .seconds(15),
        reconnect: ReconnectPolicy = .never,
        warningOptions: WarningOptions? = nil
    ) async throws -> Peripheral {
        guard manager != nil else { throw BLESwiftError.stopped }

        // Restoration owns the connection slot until its routing has run — BLESwift rejects
        // the racing call up front instead of cancelling it after the fact.
        if pendingRestoration != nil {
            throw BLESwiftError.backgroundRestorationInProgress
        }

        let resolvedWarningOptions = warningOptions ?? configuration.warningOptions

        // Claim the connection slot SYNCHRONOUSLY, before any suspension point — this closes
        // the concurrent-connect TOCTOU deadlock: a second racing `connect(id)` now sees the
        // reservation and throws `.duplicateConnect` instead of overwriting the pending
        // continuation (see `reserveConnectingSlot`/`awaitConnect`).
        try reserveConnectingSlot(
            identifier: id,
            policy: reconnect,
            timeout: timeout,
            warningOptions: resolvedWarningOptions
        )

        // Cancel an in-flight reconnect loop for THIS peripheral only. Safe after
        // reserving: a mid-flight reconnect *attempt* would already own the slot, so the
        // reservation above would have thrown first.
        reconnectLoops[id]?.task.cancel()
        reconnectLoops.removeValue(forKey: id)

        return try await establishConnection(
            identifier: id,
            policy: reconnect,
            timeout: timeout,
            warningOptions: resolvedWarningOptions
        )
    }

    /// Gracefully disconnects `id`: equivalent to `disconnect(id, immediate: false)`.
    ///
    /// - Throws: ``BLESwiftError/notConnected`` if `id` has no connection or connection
    ///   attempt in progress; ``BLESwiftError/multipleDisconnectNotSupported`` if `id` is
    ///   already disconnecting.
    public func disconnect(_ id: PeripheralIdentifier) async throws {
        try await disconnect(id, immediate: false)
    }

    /// Disconnects a connected peripheral, or cancels a connection attempt in progress, for
    /// `id`. Never triggers a ``ReconnectPolicy`` retry — an explicit `disconnect` is always
    /// treated as intentional. Other peripherals are unaffected.
    ///
    /// - Parameters:
    ///   - id: The peripheral to disconnect.
    ///   - immediate: If `true`, fails pending operations with
    ///     ``BLESwiftError/explicitDisconnect`` rather than waiting for them to finish.
    /// - Throws: ``BLESwiftError/notConnected`` if `id` has no connection, connection attempt,
    ///   or in-flight auto-reconnect loop; ``BLESwiftError/multipleDisconnectNotSupported`` if
    ///   `id` is already disconnecting.
    public func disconnect(_ id: PeripheralIdentifier, immediate: Bool) async throws {
        switch connections[id] {
        case .none:
            // No tracked entry doesn't mean nothing to stop: an auto-reconnect loop runs
            // entirely between connections (no `connections` entry during backoff), so a
            // `disconnect(id)` mid-backoff must still cancel it rather than throw `.notConnected`.
            if reconnectLoops[id] != nil {
                reconnectLoops[id]?.task.cancel()
                reconnectLoops.removeValue(forKey: id)
                reconnectGeneration += 1
                log("disconnect(\(id)) cancelled an in-flight auto-reconnect loop", level: .info, category: "connection")
                return
            }
            throw BLESwiftError.notConnected
        case .disconnecting:
            throw BLESwiftError.multipleDisconnectNotSupported
        case .connecting(let connecting):
            // Reserved-but-unattached slot: no CoreBluetooth attempt has been issued, so
            // there's nothing to cancel and no disconnect callback would ever complete a
            // `.disconnecting` transition. Record `.explicitDisconnect` so `awaitConnect`'s
            // attach resolves it.
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

    /// Best-effort teardown of every tracked peripheral: cancels every in-flight
    /// auto-reconnect loop, then disconnects every tracked entry.
    ///
    /// Never throws — individual outcomes are observable on ``connectionEvents()``.
    /// Idempotent, and a no-op with nothing tracked.
    public func disconnectAll() async {
        for id in Array(reconnectLoops.keys) {
            reconnectLoops[id]?.task.cancel()
        }
        if !reconnectLoops.isEmpty {
            reconnectLoops.removeAll()
            reconnectGeneration += 1
            log("disconnectAll() cancelled every in-flight auto-reconnect loop", level: .info, category: "connection")
        }

        for id in Array(connections.keys) {
            try? await disconnect(id, immediate: true)
        }
    }

    /// Cancels whatever connection attempt is currently in progress for every tracked
    /// peripheral, without disconnecting any already-established connection.
    ///
    /// A global operation across every peripheral. Like an explicit `disconnect`, never
    /// triggers a ``ReconnectPolicy`` retry. Does not touch an active scan.
    ///
    /// - Parameter error: The error pending operations fail with. Defaults to
    ///   ``BLESwiftError/cancelled``.
    public func cancelAllOperations(error: Error? = nil) {
        let resolvedError = error ?? BLESwiftError.cancelled

        // Cancel every in-flight auto-reconnect loop too — a reconnect-in-waiting is a
        // pending connection attempt. Bumping the generation counter stops a belated loop
        // iteration from clearing a newer loop's entry.
        if !reconnectLoops.isEmpty {
            for id in Array(reconnectLoops.keys) {
                reconnectLoops[id]?.task.cancel()
            }
            reconnectLoops.removeAll()
            reconnectGeneration += 1
            log("cancelAllOperations() cancelled every in-flight auto-reconnect loop", level: .info, category: "connection")
        }

        for identifier in Array(connections.keys) {
            switch connections[identifier] {
            case .connecting(let connecting):
                // Reserved-but-unattached slot — same handling as `failPendingConnect`.
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

    /// Resolves once `id` is connected, or throws. Wraps ``awaitConnect(id:policy:timeout:warningOptions:)``
    /// in ``withTimeout(_:throwing:operation:)``, which still awaits the real two-phase-cancel
    /// confirmation before returning rather than abandoning the underlying attempt.
    ///
    /// Takes only `identifier`, not the resolved peripheral — `any PeripheralRemote` isn't
    /// `Sendable`, so it can't cross into `withTimeout`'s `@Sendable` closure; the peripheral
    /// was already resolved by ``reserveConnectingSlot(identifier:policy:timeout:warningOptions:)``,
    /// which every caller must invoke first, synchronously, in the same actor turn.
    private func establishConnection(
        identifier: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions
    ) async throws -> Peripheral {
        try await withTimeout(timeout, throwing: BLESwiftError.connectionTimedOut) {
            try await self.awaitConnect(id: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions)
        }
    }

    /// Synchronously claims `identifier`'s ``connections`` slot for a new connection attempt,
    /// before any suspension point — the fix for the concurrent-connect TOCTOU deadlock.
    /// Resolves the target peripheral, wires its event delivery, and writes a
    /// continuation-less `.connecting` reservation so a racing call's `nil` guard fails and
    /// throws `.duplicateConnect` instead of overwriting a live attempt.
    ///
    /// Every path that starts a connection through
    /// ``establishConnection(identifier:policy:timeout:warningOptions:)`` — user `connect`,
    /// the auto-reconnect loop, and restoration's manual re-connect — must call this first,
    /// synchronously, in the same actor turn as its own occupied-slot check. (The adoption
    /// paths write a `.connected` entry directly and need no reservation.)
    ///
    /// - Throws: ``BLESwiftError/duplicateConnect(_:)`` if the slot is already occupied;
    ///   ``BLESwiftError/unexpectedPeripheral(_:)`` if CoreBluetooth no longer knows
    ///   `identifier`.
    private func reserveConnectingSlot(
        identifier: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions
    ) throws {
        guard connections[identifier] == nil else {
            throw BLESwiftError.duplicateConnect(identifier)
        }
        guard let target = manager?.retrievePeripherals(withIdentifiers: [identifier.uuid]).first else {
            throw BLESwiftError.unexpectedPeripheral(identifier)
        }

        // Wire event delivery before the attempt goes live — the shared mechanism for every
        // session-creating path. `awaitConnect` issues the actual `connect` only once it has
        // attached its continuation, so nothing can be delivered here first.
        target.eventHandler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated { $0.handle(event, from: identifier) }
        }

        connections[identifier] = .connecting(Connecting(
            identifier: identifier,
            peripheral: target,
            policy: policy,
            timeout: timeout,
            warningOptions: warningOptions,
            continuation: nil,
            stopping: nil
        ))
    }

    /// Attaches a pending connect continuation to the slot ``reserveConnectingSlot(identifier:policy:timeout:warningOptions:)``
    /// already reserved, starts the CoreBluetooth connection attempt, and suspends until
    /// ``handle(_:)`` resolves it — never directly from here. Does not create the
    /// ``connections`` entry itself; the reservation already did, synchronously.
    ///
    /// Wrapped in `withTaskCancellationHandler` so cancelling the surrounding `Task`
    /// triggers the same two-phase-cancel dance a real cancellation would (see
    /// ``failPendingConnect(for:error:)``). The handler hops onto ``queue`` via
    /// `assumeIsolated`, matching `CentralDelegateProxy`'s sanctioned pattern.
    private func awaitConnect(
        id: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions
    ) async throws -> Peripheral {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Peripheral, Error>) in
                // Attach to the slot the caller reserved synchronously via
                // `reserveConnectingSlot` — do NOT create it here. A reserved slot is
                // `.connecting` with a `nil` continuation (and no CoreBluetooth attempt
                // issued yet).
                guard case .connecting(var connecting) = connections[id], connecting.continuation == nil else {
                    // Attach to the slot reserved synchronously via `reserveConnectingSlot`
                    // — do NOT create it here. If the expected reservation is gone or
                    // already attached, resolve defensively rather than orphan the continuation.
                    continuation.resume(throwing: BLESwiftError.operationCancelled)
                    return
                }

                // A cancel/timeout/disconnect that raced in during the reservation window —
                // before any CoreBluetooth `connect` was issued — recorded its error in
                // `stopping`; resolve here directly since there's nothing to tear down.
                if let stopping = connecting.stopping {
                    connections.removeValue(forKey: id)
                    connecting.peripheral.eventHandler = nil
                    continuation.resume(throwing: stopping)
                    return
                }

                // Normal attach: wire the continuation, THEN issue the connect — never
                // before, so no callback can land while still reserved-but-unattached.
                connecting.continuation = continuation
                connections[id] = .connecting(connecting)
                connectionBroadcaster.yield(.connecting(id))
                log("Connecting to \(id)", level: .info, category: "connection")
                manager?.connect(connecting.peripheral, options: warningOptions)
            }
        } onCancel: {
            self.queue.async {
                self.assumeIsolated { central in
                    central.failPendingConnect(for: id, error: BLESwiftError.operationCancelled)
                }
            }
        }
    }

    /// Fails the pending connect for `id`: two-phase (mark `stopping`, let the
    /// `didFailToConnect`/`didDisconnect` path resolve) when the radio is on;
    /// resolved immediately when it isn't. Idempotent; no-op if nothing is pending.
    private func failPendingConnect(for id: PeripheralIdentifier, error: Error) {
        guard case .connecting(var connecting) = connections[id] else { return }
        guard connecting.stopping == nil else { return }

        // Reserved-but-unattached slot — nothing to cancel, no callback will arrive; just
        // record the error. `awaitConnect`'s attach resolves it.
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

    /// Transitions `identifier` to `.disconnecting` and either asks CoreBluetooth to cancel
    /// the connection (confirmed via ``handleTermination(identifier:error:)``), or resolves
    /// synchronously if the radio isn't powered on. Always cancels `identifier`'s in-flight
    /// reconnect loop first; other peripherals are untouched.
    private func beginDisconnecting(
        identifier: PeripheralIdentifier,
        peripheral: any PeripheralRemote,
        disconnectContinuation: CheckedContinuation<Void, Error>?,
        connectContinuation: CheckedContinuation<Peripheral, Error>?,
        connectFailureReason: Error
    ) async throws {
        reconnectLoops[identifier]?.task.cancel()
        reconnectLoops.removeValue(forKey: identifier)

        // Fail in-flight GATT operations on the outgoing session *before* the entry
        // transitions away from `.connected` — its registries live inside `Session`, which
        // is gone once the phase changes.
        failPendingGATTContinuations(for: identifier, error: .explicitDisconnect)

        // Same rationale for notification streams.
        finishNotificationStreams(for: identifier, error: BLESwiftError.explicitDisconnect)

        // Same rationale for open L2CAP channels.
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

    /// The single cleanup path for every way a tracked connection (or attempt) for
    /// `identifier` ends: a real `didFailToConnect`/`didDisconnect` callback, or a
    /// synchronous resolution when there's no radio to wait on.
    ///
    /// Cleanup order: (1) fail in-flight GATT continuations, (2) finish notification
    /// streams, (3) yield `.disconnected`, (4) resume the pending continuation(s), (5) start
    /// a reconnect loop if the ``ReconnectPolicy`` says so. Removes `identifier`'s
    /// ``connections`` entry once done.
    ///
    /// A no-op (beyond a debug log) if `identifier` has no ``connections`` entry.
    private func handleTermination(identifier: PeripheralIdentifier, error: Error?) {
        switch connections[identifier] {
        case .none:
            log("Ignoring a disconnect/fail event for untracked peripheral \(identifier)", level: .debug, category: "connection")

        case .connecting(var connecting):
            let resolvedError = connecting.stopping ?? error ?? BLESwiftError.unexpectedDisconnect
            let policy = connecting.policy
            let timeout = connecting.timeout
            let warningOptions = connecting.warningOptions
            let continuation = connecting.continuation
            connecting.continuation = nil
            connections.removeValue(forKey: identifier)

            // Detach event delivery — the counterpart of `awaitConnect`'s attach; a
            // reconnect re-attaches on its own.
            connecting.peripheral.eventHandler = nil

            failPendingGATTContinuations(for: identifier, error: .notConnected)
            finishNotificationStreams(for: identifier, error: resolvedError)
            closeL2CAPChannels(for: identifier, error: resolvedError)

            let willReconnect = !policy.isNever
            connectionBroadcaster.yield(.disconnected(identifier, error: resolvedError, willReconnect: willReconnect))

            continuation?.resume(throwing: resolvedError)

            // Don't spawn a second reconnect loop if one for `identifier` is already
            // running (its own catch block continues retrying) — only a fresh top-level
            // failure starts one here.
            if willReconnect, reconnectLoops[identifier] == nil {
                scheduleReconnect(identifier: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions)
            }

        case .connected(let session):
            let policy = session.policy
            let timeout = session.timeout
            let warningOptions = session.warningOptions

            // Fail GATT ops and finish notification streams before removing the entry —
            // see `beginDisconnecting`.
            let resolvedError = error ?? BLESwiftError.unexpectedDisconnect
            failPendingGATTContinuations(for: identifier, error: .unexpectedDisconnect)
            finishNotificationStreams(for: identifier, error: resolvedError)
            closeL2CAPChannels(for: identifier, error: resolvedError)
            connections.removeValue(forKey: identifier)

            // Detach event delivery; a reconnect attempt re-attaches on initiation.
            session.peripheral.eventHandler = nil

            let willReconnect = !policy.isNever
            connectionBroadcaster.yield(.disconnected(identifier, error: error, willReconnect: willReconnect))

            // Same don't-double-spawn guard as the `.connecting` branch above.
            if willReconnect, reconnectLoops[identifier] == nil {
                scheduleReconnect(identifier: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions)
            }

        case .disconnecting(var disconnecting):
            connections.removeValue(forKey: identifier)

            // Detach event delivery — an explicit disconnect never reconnects.
            disconnecting.peripheral.eventHandler = nil

            // Defensive no-op here in the common path (`beginDisconnecting` already did
            // this); kept for the `cancelAllOperations()`-cancels-a-pending-connect path.
            failPendingGATTContinuations(for: identifier, error: .explicitDisconnect)
            finishNotificationStreams(for: identifier, error: BLESwiftError.explicitDisconnect)
            closeL2CAPChannels(for: identifier, error: BLESwiftError.explicitDisconnect)

            connectionBroadcaster.yield(.disconnected(identifier, error: error, willReconnect: false))

            let disconnectContinuation = disconnecting.continuation
            disconnecting.continuation = nil
            disconnectContinuation?.resume(returning: ())

            let connectContinuation = disconnecting.connectContinuation
            disconnecting.connectContinuation = nil
            connectContinuation?.resume(throwing: disconnecting.connectFailureReason)
        }
    }

    /// Fails every pending connect attempt or established connection across every
    /// peripheral with ``BLESwiftError/bluetoothUnavailable`` proactively, rather than
    /// waiting on a disconnect callback that may not reliably arrive. Reconnect loops are
    /// deliberately not cancelled — their attempts fail on their own and policy decides
    /// whether to keep retrying.
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

    /// Fails every in-flight GATT operation on `identifier`'s connected session (if any)
    /// with `error`: every pending continuation is resumed throwing, and every
    /// per-characteristic FIFO tail (plus the RSSI tail) is cancelled. Cleanup step 1 of
    /// ``handleTermination(identifier:error:)``; also called directly by
    /// ``cancelAllOperations(error:)``, which leaves the connection itself intact.
    ///
    /// Distinct from ``failAllPendingOperations(error:)``, which only concerns the active
    /// scan. A no-op if `identifier` isn't currently `.connected`.
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
    /// Used by ``stopAndExtractState()`` and ``cancelAllOperations(error:)``.
    func failAllSessionsPendingGATTContinuations(error: BLESwiftError) {
        for identifier in Array(connections.keys) {
            failPendingGATTContinuations(for: identifier, error: error)
        }
    }

    /// Finishes every active notification stream on `identifier`'s session with `error` and
    /// clears its registry — cleanup step 2 of ``handleTermination(identifier:error:)``.
    /// Must run while the entry is still `.connected` (the registry lives inside `Session`).
    ///
    /// Pump tasks are deliberately NOT cancelled here — each ends on its own when its raw
    /// stream finishes, forwarding `error` to its subscriber; cancelling instead could race
    /// that delivery and hide the disconnect error.
    func finishNotificationStreams(for identifier: PeripheralIdentifier, error: Error) {
        guard case .connected(var session) = connections[identifier] else {
            log("No connected session for \(identifier) — no notification streams to finish", level: .debug, category: "gatt")
            return
        }
        guard !session.notificationSubscriptions.isEmpty else { return }

        log("Finishing \(session.notificationSubscriptions.count) notification stream(s) for \(identifier): \(error)", level: .debug, category: "gatt")

        let subscriptions = session.notificationSubscriptions
        session.notificationSubscriptions.removeAll()
        session.notificationPumps.removeAll()
        connections[identifier] = .connected(session)

        for subscription in subscriptions.values {
            for waiter in subscription.enableWaiters.values {
                waiter.resume(throwing: error)
            }
            subscription.broadcaster.finish(throwing: error)
        }
    }

    /// Calls ``finishNotificationStreams(for:error:)`` for every connected peripheral.
    /// Used by ``stopAndExtractState()``.
    func finishAllSessionsNotificationStreams(error: Error) {
        for identifier in Array(connections.keys) {
            finishNotificationStreams(for: identifier, error: error)
        }
    }

    // MARK: - Auto-reconnect

    /// Starts (or restarts) the auto-reconnect loop for `identifier`, per `policy`. Tags the
    /// spawned task with the current ``reconnectGeneration`` (incremented here) so
    /// ``runReconnectLoop(identifier:policy:timeout:warningOptions:generation:)`` clears
    /// `identifier`'s entry on exit only if it's still this generation's loop — otherwise a
    /// superseded loop's belated cleanup could race a newer loop already scheduled.
    private func scheduleReconnect(
        identifier: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions
    ) {
        reconnectGeneration += 1
        let generation = reconnectGeneration
        let task = Task<Void, Never> { [weak self] in
            await self?.runReconnectLoop(identifier: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions, generation: generation)
        }
        reconnectLoops[identifier] = ReconnectLoop(task: task, generation: generation)
    }

    /// Removes `identifier`'s ``reconnectLoops`` entry only if `generation` still matches —
    /// see ``scheduleReconnect(identifier:policy:timeout:warningOptions:)``.
    private func clearReconnectLoopIfCurrent(id identifier: PeripheralIdentifier, generation: UInt64) {
        if reconnectLoops[identifier]?.generation == generation {
            reconnectLoops.removeValue(forKey: identifier)
        }
    }

    /// Repeatedly attempts to reconnect to `identifier` per `policy`, emitting
    /// ``ConnectionEvent/reconnecting(_:attempt:)`` before each attempt, until an attempt
    /// succeeds, `policy` says to stop, or this task is cancelled. Independent of every
    /// other peripheral's loop.
    private func runReconnectLoop(
        identifier: PeripheralIdentifier,
        policy: ReconnectPolicy,
        timeout: Duration?,
        warningOptions: WarningOptions,
        generation: UInt64
    ) async {
        var attempt = 1
        var lastError: Error?

        while !Task.isCancelled {
            guard let delay = await policy.nextDelay(attempt: attempt, error: lastError) else {
                clearReconnectLoopIfCurrent(id: identifier, generation: generation)
                return
            }

            do {
                try await Task.sleep(for: delay)
            } catch {
                clearReconnectLoopIfCurrent(id: identifier, generation: generation)
                return
            }

            guard !Task.isCancelled, connections[identifier] == nil else {
                clearReconnectLoopIfCurrent(id: identifier, generation: generation)
                return
            }

            connectionBroadcaster.yield(.reconnecting(identifier, attempt: attempt))
            log("Reconnect attempt \(attempt) for \(identifier)", level: .info, category: "connection")

            do {
                // Reserve the slot synchronously (same discipline as user `connect(_:)`) so
                // a racing user `connect(id)` resolves cleanly via `.duplicateConnect`.
                try reserveConnectingSlot(
                    identifier: identifier,
                    policy: policy,
                    timeout: timeout,
                    warningOptions: warningOptions
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

        clearReconnectLoopIfCurrent(id: identifier, generation: generation)
    }

    // MARK: - Event handling

    /// Updates actor state and fans out the corresponding public event(s) for a
    /// `CentralEvent`, forwarded here by ``CentralDelegateProxy`` or a test's fake.
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

            // A `didConnect` always means success, even for an attempt marked `stopping` —
            // CoreBluetooth won the race, so declaring failure would contradict reality.
            let continuation = connecting.continuation
            connecting.continuation = nil
            let policy = connecting.policy
            let timeout = connecting.timeout
            let warningOptions = connecting.warningOptions
            let target = connecting.peripheral

            connections[identifier] = .connected(Session(identifier: identifier, peripheral: target, policy: policy, timeout: timeout, warningOptions: warningOptions))

            log("Connected to \(identifier)", level: .info, category: "connection")
            connectionBroadcaster.yield(.connected(identifier))
            continuation?.resume(returning: Peripheral(id: identifier, central: self))

        case .didFailToConnect(let identifier, let error):
            // Funnels into the same cleanup path as `didDisconnect`.
            handleTermination(identifier: identifier, error: error)

        case .didDisconnect(let identifier, let error):
            handleTermination(identifier: identifier, error: error)

        case .willRestoreState(let restored):
            // Wire each restored peripheral's event delivery now, before `.poweredOn`
            // routing adopts/reconnects it — closing the gap where a notification from a
            // surviving listen would otherwise have nowhere to go.
            for restoredPeripheral in restored.peripherals {
                let peripheralIdentifier = restoredPeripheral.identifier
                guard let target = manager?.retrievePeripherals(withIdentifiers: [peripheralIdentifier.uuid]).first else {
                    continue
                }
                target.eventHandler = { [weak self] event in
                    guard let self else { return }
                    self.assumeIsolated { $0.handle(event, from: peripheralIdentifier) }
                }
            }

            // Stage the restored state until the radio's first `.poweredOn` routes it;
            // `.willRestore` is buffered/replayed so a later subscriber still sees it.
            pendingRestoration = restored
            restorationBroadcaster.yield(.willRestore(restored))
            log("Will restore state: \(restored.peripherals.count) peripheral(s)", level: .info, category: "restore")
        }
    }

    /// Handles a `PeripheralEvent`, forwarded here by ``PeripheralDelegateProxy`` or a
    /// test's fake. Routes GATT completions to their pending continuations (take-then-resume)
    /// and `didModifyServices` to ``serviceChangesRegistry``, keyed by `peripheral`.
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
            // No actor-level discovery cache: `isDiscovered(_:)` is backed by CoreBluetooth's
            // own service graph, which it already prunes on `didModifyServices`.
            log("Services modified/invalidated: \(invalidatedServices)", level: .info, category: "gatt")
            // Reset the enumeration caches touched by the invalidation so a subsequent
            // enumeration re-discovers anything that appeared.
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

    /// Take-then-resumes every waiter in `session.pendingDiscoverServices`. Not matched to a
    /// specific service — `didDiscoverServices(error:)` carries no service identifier — so
    /// every waiter is resumed on any completion; each independently re-checks its own
    /// service afterward.
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

    /// Take-then-resumes a single service-discovery waiter by token — the reaction to that
    /// waiter's own cancellation, not a real completion.
    private func cancelDiscoverServicesWaiter(identifier: PeripheralIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDiscoverServices.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes every waiter for `service` in `pendingDiscoverCharacteristics` —
    /// keyed by service (unlike services above, since `didDiscoverCharacteristics` carries it).
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

    /// Take-then-resumes a single characteristic-discovery waiter by service + token — see
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

    /// Take-then-resumes every waiter for `characteristic` in `pendingDiscoverDescriptors` —
    /// keyed like ``resumeDiscoverCharacteristicsWaiters(service:for:error:)``.
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

    /// Take-then-resumes a single descriptor-discovery waiter by characteristic + token —
    /// see ``cancelDiscoverCharacteristicsWaiter(identifier:service:token:)``.
    private func cancelDiscoverDescriptorsWaiter(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDiscoverDescriptors[characteristic]?.removeValue(forKey: token) else { return }
        if session.pendingDiscoverDescriptors[characteristic]?.isEmpty == true {
            session.pendingDiscoverDescriptors.removeValue(forKey: characteristic)
        }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes the single pending write continuation for `characteristic`, if
    /// any (single-slot, guaranteed by the per-characteristic FIFO).
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

    /// Take-then-resumes the single pending write continuation for `characteristic`, if
    /// still pending — the reaction to cancellation (task cancellation or a `withTimeout`
    /// timeout) rather than a real `didWriteValue` completion.
    private func cancelPendingWrite(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingWrites.removeValue(forKey: characteristic) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes the single pending notify-state-change continuation for
    /// `characteristic`, if any.
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

    /// Take-then-resumes the single pending RSSI-read continuation, if any (single-slot,
    /// guaranteed by ``runRSSISerialized(identifier:operation:)``'s own tail-chain).
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

    /// Take-then-resumes the single pending RSSI-read continuation, if still pending — see
    /// ``cancelPendingWrite(identifier:characteristic:)``.
    private func cancelPendingRSSIRead(identifier: PeripheralIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingRSSIRead else { return }
        session.pendingRSSIRead = nil
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes every waiter in `pendingWriteWithoutResponseReady`. Not keyed by
    /// characteristic — CoreBluetooth's readiness signal is peripheral-wide.
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

    /// Take-then-resumes a single write-without-response-readiness waiter by token — see
    /// ``cancelDiscoverServicesWaiter(identifier:token:)``.
    private func cancelWriteWithoutResponseWaiter(identifier: PeripheralIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingWriteWithoutResponseReady.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Routes a `didUpdateValueFor` delivery: an active notification subscription consumes
    /// it first, else a pending read continuation, else — with restoration enabled — the
    /// restoration "unhandled listen" surface, else it's logged.
    ///
    /// A `didUpdateValue` error on a notifying characteristic finishes that subscription
    /// with the error.
    private func handleDidUpdateValue(characteristic: CharacteristicIdentifier, value: Data?, error: NSError?, from peripheralIdentifier: PeripheralIdentifier) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            // willRestoreState→poweredOn window: a restored-but-not-yet-routed peripheral
            // can already be notifying. Surface it on the restoration stream instead of
            // dropping it as "untracked".
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
                // `nil` value yields empty `Data`, matching the pending-read path below.
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
            // The restoration "unhandled listen" surface — only meaningful with restoration
            // enabled.
            restorationBroadcaster.yield(.unhandledNotification(peripheralIdentifier, characteristic, value))
            log("Unhandled value update for \(characteristic) surfaced on restorationEvents()", level: .info, category: "restore")
        } else {
            log("Unhandled value update for \(characteristic) with no active notification subscriber or pending read", level: .debug, category: "gatt")
        }
    }

    /// Take-then-resumes the single pending read continuation for `characteristic`, if
    /// still pending — the reaction to cancellation (task cancellation or a `withTimeout`
    /// timeout) rather than a real `didUpdateValue` completion.
    private func cancelPendingRead(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingReads.removeValue(forKey: characteristic) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes the single pending descriptor-read continuation for `descriptor`,
    /// if any (single-slot, guaranteed by the parent characteristic's FIFO).
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

    /// Take-then-resumes the single pending descriptor-read continuation for `descriptor`,
    /// if still pending — the reaction to cancellation (task cancellation or a `withTimeout`
    /// timeout) rather than a real `didUpdateValueForDescriptor` completion.
    private func cancelPendingDescriptorRead(identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDescriptorReads.removeValue(forKey: descriptor) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes the single pending descriptor-write continuation for `descriptor`,
    /// if any (single-slot, guaranteed by the parent characteristic's FIFO).
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

    /// Take-then-resumes the single pending descriptor-write continuation for `descriptor`,
    /// if still pending — see ``cancelPendingDescriptorRead(identifier:descriptor:)``.
    private func cancelPendingDescriptorWrite(identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDescriptorWrites.removeValue(forKey: descriptor) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    // MARK: - GATT operations

    /// Reads `characteristic`'s current value, routed here by `Peripheral.read(from:timeout:)`.
    /// Wraps the discovery-then-read sequence in `timeout` (``BLESwiftError/timedOut``) and
    /// serializes it against other operations on the same characteristic.
    func performRead(peripheral identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, timeout: Duration?) async throws -> Data {
        try await withTimeout(timeout, throwing: BLESwiftError.timedOut) {
            try await self.runOnFIFO(identifier: identifier, characteristic: characteristic) {
                try await self.performReadNow(identifier: identifier, characteristic: characteristic)
            }
        }
    }

    /// The actual discovery-then-read sequence for ``performRead(peripheral:characteristic:timeout:)``,
    /// run inside `characteristic`'s FIFO chain.
    private func performReadNow(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) async throws -> Data {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        // BLESwift throws rather than crashing on read-while-listening — CoreBluetooth
        // can't disambiguate a read completion from a notification on the same characteristic.
        if peripheral.isNotifying(characteristic) {
            throw BLESwiftError.readConflictsWithNotification
        }

        try await ensureDiscovered(characteristic, on: peripheral, identifier: identifier)

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
                    self.assumeIsolated { central in
                        central.cancelPendingRead(identifier: identifier, characteristic: characteristic)
                    }
                }
            }
        )
    }

    /// Reports the set of operations `characteristic` supports, routed here by
    /// `Peripheral.properties(of:)`. Triggers lazy discovery first, then reads the
    /// discovered characteristic's properties directly (no completion continuation needed).
    func properties(peripheral identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) async throws -> CharacteristicProperties {
        try await runOnFIFO(identifier: identifier, characteristic: characteristic) {
            try await self.propertiesNow(identifier: identifier, characteristic: characteristic)
        }
    }

    /// The actual discovery-then-introspect sequence for
    /// ``properties(peripheral:characteristic:)``, run inside `characteristic`'s FIFO chain.
    private func propertiesNow(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) async throws -> CharacteristicProperties {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        try await ensureDiscovered(characteristic, on: peripheral, identifier: identifier)

        return peripheral.properties(of: characteristic)
    }

    /// Writes `data` to `characteristic`, routed here by
    /// `Peripheral.write(_:to:type:timeout:)`. Mirrors ``performRead(peripheral:characteristic:timeout:)``'s
    /// timeout/FIFO wrapping.
    func performWrite(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        data: Data,
        type: WriteType,
        timeout: Duration?
    ) async throws {
        try await withTimeout(timeout, throwing: BLESwiftError.timedOut) {
            try await self.runOnFIFO(identifier: identifier, characteristic: characteristic) {
                try await self.performWriteNow(identifier: identifier, characteristic: characteristic, data: data, type: type)
            }
        }
    }

    /// The actual discovery-then-write sequence for ``performWrite(peripheral:characteristic:data:type:timeout:)``.
    ///
    /// `.withoutResponse` synthesizes completion immediately — CoreBluetooth delivers no
    /// `didWriteValueFor` for it. BLESwift awaits `canSendWriteWithoutResponse` back-pressure
    /// first rather than writing regardless and letting CoreBluetooth drop the payload.
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
                    self.assumeIsolated { central in
                        central.cancelPendingWrite(identifier: identifier, characteristic: characteristic)
                    }
                }
            }
        )
    }

    /// Awaits `peripheral.canSendWriteWithoutResponse` becoming `true` — CoreBluetooth's
    /// back-pressure signal for `.withoutResponse` writes. A no-op if already `true`.
    /// Peripheral-wide (not per-characteristic): every waiter is resumed on the next
    /// readiness signal.
    private func awaitWriteWithoutResponseReadiness(peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        if peripheral.canSendWriteWithoutResponse { return }

        // `Mutex`-boxed (not a plain `var`) so it's safely writable from `register`
        // (actor-isolated) and readable from `onCancelled` (a `@Sendable` closure) — Swift 6
        // rejects a mutable local captured across that boundary directly.
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
                // `assignedToken` is always set by the time this can fire — `register` runs
                // synchronously before cancellation can be observed.
                self.queue.async {
                    self.assumeIsolated { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelWriteWithoutResponseWaiter(identifier: identifier, token: token)
                    }
                }
            }
        )
    }

    /// Reads `descriptor`'s current value, routed here by
    /// `Peripheral.readDescriptor(_:timeout:)`. Serializes on the *parent characteristic's*
    /// FIFO lane so a descriptor op never races a characteristic op on the same characteristic.
    func performReadDescriptor(peripheral identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier, timeout: Duration?) async throws -> Data {
        try await withTimeout(timeout, throwing: BLESwiftError.timedOut) {
            try await self.runOnFIFO(identifier: identifier, characteristic: descriptor.characteristic) {
                try await self.performReadDescriptorNow(identifier: identifier, descriptor: descriptor)
            }
        }
    }

    /// The actual discovery-then-read sequence for ``performReadDescriptor(peripheral:descriptor:timeout:)``,
    /// run inside the parent characteristic's FIFO chain.
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
                    self.assumeIsolated { central in
                        central.cancelPendingDescriptorRead(identifier: identifier, descriptor: descriptor)
                    }
                }
            }
        )
    }

    /// Writes `data` to `descriptor`, routed here by
    /// `Peripheral.writeDescriptor(_:value:timeout:)`. Always with-response — CoreBluetooth
    /// exposes no write-type parameter for a `CBDescriptor`.
    func performWriteDescriptor(peripheral identifier: PeripheralIdentifier, descriptor: DescriptorIdentifier, data: Data, timeout: Duration?) async throws {
        try await withTimeout(timeout, throwing: BLESwiftError.timedOut) {
            try await self.runOnFIFO(identifier: identifier, characteristic: descriptor.characteristic) {
                try await self.performWriteDescriptorNow(identifier: identifier, descriptor: descriptor, data: data)
            }
        }
    }

    /// The actual discovery-then-write sequence for ``performWriteDescriptor(peripheral:descriptor:data:timeout:)``,
    /// run inside the parent characteristic's FIFO chain.
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
                    self.assumeIsolated { central in
                        central.cancelPendingDescriptorWrite(identifier: identifier, descriptor: descriptor)
                    }
                }
            }
        )
    }

    /// Reads the peripheral's current RSSI, routed here by `Peripheral.readRSSI(timeout:)`.
    /// RSSI has no owning characteristic, so it serializes via its own single tail rather
    /// than the per-characteristic FIFO map.
    func performReadRSSI(peripheral identifier: PeripheralIdentifier, timeout: Duration?) async throws -> Int {
        try await withTimeout(timeout, throwing: BLESwiftError.timedOut) {
            try await self.runRSSISerialized(identifier: identifier) {
                try await self.performReadRSSINow(identifier: identifier)
            }
        }
    }

    /// The actual RSSI-read for ``performReadRSSI(peripheral:timeout:)``, run inside the
    /// RSSI tail chain.
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
                    self.assumeIsolated { central in
                        central.cancelPendingRSSIRead(identifier: identifier)
                    }
                }
            }
        )
    }

    /// This peripheral's maximum payload length in bytes for a single write of `type`,
    /// routed here by `Peripheral.maximumWriteValueLength(for:)`. Never throws — returns
    /// ``Central/defaultMaximumWriteValueLength`` if `identifier` isn't connected.
    func maximumWriteValueLength(peripheral identifier: PeripheralIdentifier, for type: WriteType) -> Int {
        guard case .connected(let session) = connections[identifier] else {
            return Central.defaultMaximumWriteValueLength
        }
        return session.peripheral.maximumWriteValueLength(for: type)
    }

    /// The fallback value when there's no connected peripheral to ask — the classic BLE
    /// ATT_MTU-3 default (23-byte default ATT_MTU minus the 3-byte write-request header).
    static let defaultMaximumWriteValueLength = 20

    // MARK: - Lazy discovery

    /// Ensures `characteristic` (and its owning service) has been discovered on `peripheral`,
    /// short-circuiting via the shim's own `isDiscovered(_:)` — CoreBluetooth's own graph IS
    /// the cache.
    ///
    /// - Throws: ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``
    ///   if still not discovered once discovery completes, or whatever CoreBluetooth reports.
    private func ensureDiscovered(_ characteristic: CharacteristicIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        try await ensureServiceDiscovered(characteristic.service, on: peripheral, identifier: identifier)
        try await ensureCharacteristicDiscovered(characteristic, on: peripheral, identifier: identifier)
    }

    /// Ensures `service` has been discovered, calling `discoverServices(_:)` and awaiting
    /// its completion only if `peripheral.isDiscovered(service)` doesn't already report it
    /// discovered. See ``ensureDiscovered(_:on:identifier:)``.
    private func ensureServiceDiscovered(_ service: ServiceIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        guard !peripheral.isDiscovered(service) else { return }

        // See `awaitWriteWithoutResponseReadiness`'s matching declaration for why this is
        // `Mutex`-boxed rather than a plain `var`.
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
                    self.assumeIsolated { central in
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

    /// Ensures `characteristic` has been discovered, calling `discoverCharacteristics(_:for:)`
    /// and awaiting its completion only if it isn't already discovered. See
    /// ``ensureDiscovered(_:on:identifier:)``.
    private func ensureCharacteristicDiscovered(_ characteristic: CharacteristicIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        guard !peripheral.isDiscovered(characteristic) else { return }

        // See `awaitWriteWithoutResponseReadiness`'s matching declaration for why this is
        // `Mutex`-boxed rather than a plain `var`.
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
                    self.assumeIsolated { central in
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

    /// Ensures `descriptor` (and its owning characteristic/service) has been discovered on
    /// `peripheral`, extending the lazy discovery chain one level.
    ///
    /// - Throws: whatever ``ensureDiscovered(_:on:identifier:)`` throws, or
    ///   ``BLESwiftError/missingDescriptor(_:)`` if still not discovered.
    private func ensureDescriptorDiscovered(_ descriptor: DescriptorIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        try await ensureDiscovered(descriptor.characteristic, on: peripheral, identifier: identifier)
        try await ensureDescriptorsDiscovered(descriptor, on: peripheral, identifier: identifier)
    }

    /// Ensures `descriptor` has been discovered, calling `discoverDescriptors(for:)` on its
    /// owning characteristic if needed. Unlike characteristics, descriptors have no filter —
    /// they're always discovered as a group — so a still-undiscovered one triggers a full
    /// re-discovery.
    private func ensureDescriptorsDiscovered(_ descriptor: DescriptorIdentifier, on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        guard !peripheral.isDiscovered(descriptor) else { return }

        // See `awaitWriteWithoutResponseReadiness`'s matching declaration for why this is
        // `Mutex`-boxed rather than a plain `var`.
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
                    self.assumeIsolated { central in
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

    /// Lists `identifier`'s services, discovering them (`discoverServices(nil)`) first if
    /// not yet enumerated. Routed here by `Peripheral.discoverServices()`.
    ///
    /// Cached per connection (``Session/didEnumerateServices``) until a `didModifyServices`
    /// invalidation resets it.
    ///
    /// - Throws: ``BLESwiftError/notConnected``, ``BLESwiftError/operationCancelled`` on task
    ///   cancellation, or whatever CoreBluetooth reports.
    func enumerateServices(peripheral identifier: PeripheralIdentifier) async throws -> [ServiceIdentifier] {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        if !session.didEnumerateServices {
            try await awaitDiscoverAllServices(on: peripheral, identifier: identifier)
            // Re-read the entry: the await above suspended, so the session may have been
            // torn down/rebuilt — don't write back a stale copy.
            guard case .connected(var refreshed) = connections[identifier] else {
                throw BLESwiftError.notConnected
            }
            refreshed.didEnumerateServices = true
            connections[identifier] = .connected(refreshed)
        }

        return peripheral.discoveredServices
    }

    /// Lists `service`'s characteristics on `identifier`, discovering the service (if
    /// needed) and then all of its characteristics the first time this is asked. Routed here
    /// by `Peripheral.discoverCharacteristics(for:)`.
    ///
    /// Cached per service (``Session/enumeratedCharacteristicServices``) until invalidated.
    ///
    /// - Throws: ``BLESwiftError/notConnected``, ``BLESwiftError/missingService(_:)``,
    ///   ``BLESwiftError/operationCancelled``, or whatever CoreBluetooth reports.
    func enumerateCharacteristics(
        peripheral identifier: PeripheralIdentifier,
        service: ServiceIdentifier
    ) async throws -> [CharacteristicIdentifier] {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        // The owning service must be discovered first — a real `discoverCharacteristics(_:for:)`
        // is a silent no-op on an undiscovered service; this also surfaces `.missingService`.
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

    /// Lists `characteristic`'s descriptors on `identifier`, discovering the owning
    /// service/characteristic (if needed) and then the descriptors. Routed here by
    /// `Peripheral.discoverDescriptors(for:)`.
    ///
    /// Cached per characteristic (``Session/enumeratedDescriptorCharacteristics``).
    ///
    /// - Throws: ``BLESwiftError/notConnected``, whatever the owning-characteristic discovery
    ///   throws, ``BLESwiftError/operationCancelled``, or whatever CoreBluetooth reports.
    func enumerateDescriptors(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier
    ) async throws -> [DescriptorIdentifier] {
        guard case .connected(let session) = connections[identifier] else {
            throw BLESwiftError.notConnected
        }
        let peripheral = session.peripheral

        // Discover the owning service + characteristic first (a no-op if already discovered).
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
    /// resolves it — same take-then-resume + cancellation machinery as
    /// ``ensureServiceDiscovered(_:on:identifier:)``, differing only in the `nil` filter.
    private func awaitDiscoverAllServices(on peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        // See `awaitWriteWithoutResponseReadiness`'s matching declaration for why this is
        // `Mutex`-boxed rather than a plain `var`.
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
                    self.assumeIsolated { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverServicesWaiter(identifier: identifier, token: token)
                    }
                }
            }
        )
    }

    /// Issues `discoverCharacteristics(nil, for: service)` (discover *all* of the service's
    /// characteristics) and suspends until ``handle(_:from:)`` resolves it. Shares the
    /// machinery of ``ensureCharacteristicDiscovered(_:on:identifier:)``, differing only in
    /// the `nil` (all-characteristics) filter.
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
                    self.assumeIsolated { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverCharacteristicsWaiter(identifier: identifier, service: service, token: token)
                    }
                }
            }
        )
    }

    /// Issues `discoverDescriptors(for: characteristic)` and suspends until resolved — the
    /// enumeration-side twin of ``ensureDescriptorsDiscovered(_:on:identifier:)`` minus the
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
                    self.assumeIsolated { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelDiscoverDescriptorsWaiter(identifier: identifier, characteristic: characteristic, token: token)
                    }
                }
            }
        )
    }

    // MARK: - Notifications

    /// Registers one `Peripheral.notifications(for:policy:)` subscriber and spawns its pump
    /// task — the bridge between the shared raw-`Data` multicast and that subscriber's typed
    /// stream. Called synchronously before the stream is returned, so by queue FIFO ordering
    /// this always runs before ``handleNotificationStreamTermination(peripheral:characteristic:token:)``
    /// can be enqueued.
    ///
    /// The pump `Task` is a ledgered site: actor-spawned, stored in
    /// `Session.notificationPumps` keyed by `token`, cancelled by that method.
    ///
    /// - Parameters:
    ///   - deliver: Decodes and yields one raw value; returns `nil` on success or the decode
    ///     error, which finishes only that subscriber's stream.
    ///   - finish: Finishes the subscriber's typed stream, throwing if non-`nil`.
    func startNotificationPump(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID,
        deliver: @escaping @Sendable (Data) -> Error?,
        finish: @escaping @Sendable (Error?) -> Void
    ) {
        guard case .connected(var session) = connections[identifier] else {
            finish(BLESwiftError.notConnected)
            return
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
                deliver: deliver,
                finish: finish
            )
        }
        session.notificationPumps[token] = pump
        connections[identifier] = .connected(session)
    }

    /// The body of one subscriber's pump task: subscribes to the raw multicast (enabling
    /// notifications if first), forwards values through `deliver`, and finishes the typed
    /// stream when the raw stream ends.
    private func runNotificationPump(
        identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID,
        deliver: @Sendable (Data) -> Error?,
        finish: @Sendable (Error?) -> Void
    ) async {
        let raw: AsyncThrowingStream<Data, Error>
        do {
            raw = try await subscribeToNotifications(peripheral: identifier, characteristic: characteristic, token: token)
        } catch {
            finish(error)
            return
        }

        do {
            for try await data in raw {
                if let decodeError = deliver(data) {
                    throw decodeError
                }
            }
            finish(nil)
        } catch {
            finish(error)
        }

        // Belt-and-braces release (idempotent by token): the primary release path is the
        // typed stream's `onTermination`, but this covers a pump cancelled between that
        // (pre-registration) no-op and registration above.
        releaseNotificationSubscriber(peripheral: identifier, characteristic: characteristic, token: token)
    }

    /// Reacts to a subscriber's typed stream terminating: cancels and forgets its pump task,
    /// then releases its refcount.
    func handleNotificationStreamTermination(
        peripheral identifier: PeripheralIdentifier,
        characteristic: CharacteristicIdentifier,
        token: UUID
    ) {
        if case .connected(var session) = connections[identifier],
           let pump = session.notificationPumps.removeValue(forKey: token) {
            connections[identifier] = .connected(session)
            pump.cancel()
        }
        releaseNotificationSubscriber(peripheral: identifier, characteristic: characteristic, token: token)
    }

    /// Registers `token` as one subscriber of `characteristic`'s raw-`Data` notification
    /// multicast and returns a fresh stream of it — the entry point for typed subscribers
    /// (via their pump) and the composite helpers alike.
    ///
    /// First subscriber: the subscription is registered BEFORE enabling — closing the loss
    /// window — then discovery runs and `setNotifyValue(true)` is awaited. If that fails,
    /// every current subscriber's stream (and enablement waiter) finishes with the error.
    ///
    /// Joiners: added to the existing subscription; if the enable handshake is still in
    /// flight, the joiner awaits its confirmation first — load-bearing for the composite
    /// helpers' listen-before-write guarantee.
    ///
    /// Deliberately NOT serialized through the per-characteristic FIFO: a subscription must
    /// be installable even while a read on the same characteristic is pending, so
    /// notification routing can take precedence (see ``handleDidUpdateValue(characteristic:value:error:from:)``).
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

        // First subscriber: register BEFORE enabling (see doc comment — no loss window).
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
            // The confirmation's `isNotifying` payload is deliberately ignored — a stale
            // disable-confirmation from a released subscription must not fail a fresh enable
            // whose own confirmation is still in flight.
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
                        self.assumeIsolated { central in
                            central.cancelPendingNotifyStateChange(identifier: identifier, characteristic: characteristic)
                        }
                    }
                }
            )
            confirmNotificationEnablement(identifier: identifier, characteristic: characteristic)
        } catch {
            failNotificationSubscription(identifier: identifier, characteristic: characteristic, error: error)
            throw error
        }

        return stream
    }

    /// Suspends a joiner until `characteristic`'s in-flight enable handshake confirms or
    /// fails. Cancellation removes and resumes only this joiner's own waiter.
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
                        self.assumeIsolated { central in
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

    /// Marks `characteristic`'s subscription enable-confirmed and take-then-resumes every
    /// enablement waiter.
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

    /// Fails `characteristic`'s entire subscription: removes it, resumes every enablement
    /// waiter throwing `error`, and finishes the raw broadcaster with it.
    ///
    /// No `setNotifyValue(false)` is issued: on the enable-failure path it was never
    /// confirmed; on the value-error path delivery is already failing.
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

    /// Releases one subscriber's refcount on `characteristic`'s subscription. Idempotent
    /// per `token`.
    ///
    /// The **last** release removes the subscription, finishes its broadcaster, and issues
    /// `setNotifyValue(false)` — but only while still connected and the radio is
    /// `.poweredOn` (else CoreBluetooth logs "API MISUSE"). The disable's own confirmation
    /// is not awaited.
    func releaseNotificationSubscriber(peripheral identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, token: UUID) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard var subscription = session.notificationSubscriptions[characteristic] else { return }
        guard subscription.subscriberTokens.remove(token) != nil else { return }

        // Take-then-resume this token's own enablement waiter, if it still has one (a
        // release can arrive while the joiner is still suspended awaiting confirmation).
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

    /// The number of live subscriber tokens on `characteristic`'s subscription for `id` — a
    /// test-visibility hook (`@testable`): subscriber registration is asynchronous, so
    /// multi-subscriber tests await this count first. Not part of the public API.
    func notificationSubscriberCount(for characteristic: CharacteristicIdentifier, on id: PeripheralIdentifier) -> Int {
        guard case .connected(let session) = connections[id] else { return 0 }
        return session.notificationSubscriptions[characteristic]?.subscriberTokens.count ?? 0
    }

    /// Take-then-resumes the single pending notify-state-change continuation for
    /// `characteristic`, if still pending — see ``cancelPendingRead(identifier:characteristic:)``.
    private func cancelPendingNotifyStateChange(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingNotifyStateChanges.removeValue(forKey: characteristic) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes a single enablement waiter by token, removing only this waiter and
    /// leaving the subscription (and its siblings) intact.
    private func cancelNotificationEnablementWaiter(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, token: UUID) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard var subscription = session.notificationSubscriptions[characteristic],
              let continuation = subscription.enableWaiters.removeValue(forKey: token) else { return }
        session.notificationSubscriptions[characteristic] = subscription
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    // MARK: - Composite helpers

    /// Backs `Peripheral.writeAndAwaitNotification(write:to:awaitOn:timeout:)`: subscribes to
    /// `notifyCharacteristic` FIRST, then writes, then returns the first notification value —
    /// preserving a listen-before-write ordering guarantee. The timeout covers the whole
    /// sequence, throwing ``BLESwiftError/listenTimedOut``.
    func performWriteAndAwaitNotification(
        peripheral identifier: PeripheralIdentifier,
        writeCharacteristic: CharacteristicIdentifier,
        notifyCharacteristic: CharacteristicIdentifier,
        data: Data,
        timeout: Duration?
    ) async throws -> Data {
        try await withTimeout(timeout, throwing: BLESwiftError.listenTimedOut) {
            try await self.writeAndAwaitNotificationNow(
                identifier: identifier,
                writeCharacteristic: writeCharacteristic,
                notifyCharacteristic: notifyCharacteristic,
                data: data
            )
        }
    }

    /// The actual subscribe → write → await-first-value sequence for
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

    /// Backs `Peripheral.writeAndAssemble(write:to:assembleFrom:expectedLength:timeout:)`:
    /// like ``performWriteAndAwaitNotification(peripheral:writeCharacteristic:notifyCharacteristic:data:timeout:)``
    /// but accumulating packets until exactly `expectedLength` bytes arrive
    /// (`> expectedLength` throws ``BLESwiftError/tooMuchData(expected:received:)``). The
    /// timeout covers the whole assembly.
    func performWriteAndAssemble(
        peripheral identifier: PeripheralIdentifier,
        writeCharacteristic: CharacteristicIdentifier,
        notifyCharacteristic: CharacteristicIdentifier,
        data: Data,
        expectedLength: Int,
        timeout: Duration?
    ) async throws -> Data {
        try await withTimeout(timeout, throwing: BLESwiftError.listenTimedOut) {
            try await self.writeAndAssembleNow(
                identifier: identifier,
                writeCharacteristic: writeCharacteristic,
                notifyCharacteristic: notifyCharacteristic,
                data: data,
                expectedLength: expectedLength
            )
        }
    }

    /// The actual subscribe → write → assemble loop for
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

    /// Backs `Peripheral.flush(_:quietPeriod:)`: consumes and discards raw packets until a
    /// full `quietPeriod` elapses with none arriving — every packet restarts the window.
    ///
    /// - Throws: ``BLESwiftError/invalidArgument(_:)`` if `quietPeriod` isn't strictly
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
                packet = try await withTimeout(quietPeriod, throwing: BLESwiftError.timedOut) {
                    try await iterator.next()
                }
            } catch BLESwiftError.timedOut {
                // A full quiet period elapsed with no packet: flush complete.
                break
            }
            guard packet != nil else {
                // The raw stream ended cleanly underneath us — nothing left to flush.
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

    /// Suspends until `register` resumes the continuation — either normally (a real
    /// CoreBluetooth completion) or, on cancellation, via `onCancelled`, which hops onto
    /// ``queue`` via `assumeIsolated` and take-then-resumes whatever `register` populated.
    ///
    /// Every GATT continuation goes through this rather than a bare
    /// `withCheckedThrowingContinuation`: merely marking a `Task` cancelled never resumes a
    /// suspended continuation, so without this a `timeout:` would hang forever instead of
    /// throwing ``BLESwiftError/timedOut``.
    private func withCancellableGATTContinuation<T: Sendable>(
        register: (CheckedContinuation<T, Error>) -> Void,
        onCancelled: @escaping @Sendable () -> Void
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(register)
        } onCancel: {
            onCancelled()
        }
    }

    // MARK: - L2CAP

    /// Opens an L2CAP channel to `psm` on `identifier`, routed here by
    /// `Peripheral.openL2CAPChannel(psm:timeout:)`. Wraps the open in `timeout`, then
    /// registers the resulting transport and hands back an ``L2CAPChannel``.
    func performOpenL2CAPChannel(
        peripheral identifier: PeripheralIdentifier,
        psm: L2CAPPSM,
        timeout: Duration?
    ) async throws -> L2CAPChannel {
        try await withTimeout(timeout, throwing: BLESwiftError.timedOut) {
            let transport = try await self.awaitL2CAPOpen(identifier: identifier, psm: psm)
            return try await self.registerL2CAPChannel(identifier: identifier, transport: transport)
        }
    }

    /// Issues the CoreBluetooth L2CAP open and suspends until ``handle(_:from:)`` resolves it
    /// — same take-then-resume + cancellation discipline as every GATT continuation. The
    /// waiter is registered under a fresh token before the open is issued, so a `didOpen`
    /// that lands synchronously still finds it.
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
                    self.assumeIsolated { central in
                        central.cancelPendingL2CAPOpen(identifier: identifier, token: token)
                    }
                }
            }
        )
    }

    /// Take-then-resumes the oldest pending L2CAP-open waiter (FIFO by token) for
    /// `identifier`. On error resumes throwing; on success resumes with the transport; no
    /// waiter pending leaks the channel by closing it.
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

    /// Take-then-resumes a single pending L2CAP-open waiter by token — the reaction to
    /// cancellation rather than a real `didOpen`. Removing only this token leaves any other
    /// concurrently pending open untouched.
    private func cancelPendingL2CAPOpen(identifier: PeripheralIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingL2CAPOpens.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Registers a freshly-opened `transport` under a new token and returns the public
    /// ``L2CAPChannel`` handle. If disconnected between open completing and this running,
    /// the transport is closed immediately and ``BLESwiftError/notConnected`` is thrown.
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

    /// Closes and deregisters a single L2CAP channel — the reaction to an explicit
    /// `L2CAPChannel.close()`. A no-op if the session is gone or the token is unknown.
    func closeL2CAPChannel(peripheral identifier: PeripheralIdentifier, token: UUID) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let transport = session.l2capChannels.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        transport.close(error: nil)
    }

    /// Closes every open L2CAP channel on `identifier`'s session with `error` — the L2CAP
    /// counterpart of ``finishNotificationStreams(for:error:)``. Must run while still
    /// `.connected` (channels live inside `Session`).
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
    /// Used by ``stopAndExtractState()``.
    func closeAllSessionsL2CAPChannels(error: Error) {
        for identifier in Array(connections.keys) {
            closeL2CAPChannels(for: identifier, error: error)
        }
    }

    // MARK: - Per-characteristic FIFO

    /// Serializes GATT operations on the same characteristic: awaits `characteristic`'s
    /// previous tail `Task` before running `operation`, then replaces the tail with a fresh
    /// one. Different characteristics interleave freely.
    ///
    /// `operation` runs **inline**, in this call's own task — not a spawned `Task { }`, which
    /// would not inherit the caller's cancellation, breaking `withTimeout`'s ability to reach
    /// `operation`'s continuation-based waits.
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

    /// The RSSI-only counterpart to ``runOnFIFO(identifier:characteristic:operation:)``:
    /// serializes `readRSSI()` calls via ``Session/rssiTail`` (a single tail, not a
    /// per-characteristic map). See that function's doc comment for why `operation` runs inline.
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

    /// Fails every in-flight operation with `error`. Called whenever the radio leaves
    /// `.poweredOn`.
    ///
    /// Only fails the active scan directly — connection/GATT operations are handled via
    /// ``handleBluetoothUnavailable()`` → ``handleTermination(identifier:error:)`` instead,
    /// since a scan has no such connection-scoped home to route through.
    func failAllPendingOperations(error: BLESwiftError) {
        log("Failing all pending operations: \(error)", level: .warning, category: "state")
        failActiveScan(error)
    }

    // MARK: - Scanning

    /// Scans for nearby peripherals advertising `services`, yielding a ``ScanEvent`` for
    /// every sighting. Each call creates its own independent stream; BLESwift enforces
    /// CoreBluetooth's single-physical-scanner discipline — calling `scan` again while a scan
    /// is active immediately fails the *new* stream with ``BLESwiftError/alreadyScanning``.
    ///
    /// The scan stops when its stream's consumer stops it (`break`/task cancel), when
    /// `timeout` elapses, when the radio leaves ``CentralState/poweredOn`` (throwing
    /// ``BLESwiftError/bluetoothUnavailable``), or when an iOS backgrounding guard fires (see
    /// below). Connecting to a sighted peripheral does not stop or affect the scan.
    ///
    /// - Parameters:
    ///   - services: The services to scan for. `nil` scans for all peripherals — discouraged
    ///     by Apple outside short, time-boxed scans.
    ///   - allowDuplicates: Whether to keep reporting an already-discovered peripheral's
    ///     further sightings as ``ScanEvent/updated(_:)`` (and track its loss via
    ///     `lossTimeout`). Defaults to `false`. Mirrors
    ///     `CBCentralManagerScanOptionAllowDuplicatesKey`.
    ///   - rssiThreshold: The minimum absolute RSSI delta (in dBm) required for a repeat
    ///     sighting to be reported as ``ScanEvent/updated(_:)``. `nil` (the default) disables
    ///     throttling.
    ///   - lossTimeout: How long a sighted peripheral may go unseen before it's reported as
    ///     ``ScanEvent/lost(_:)``. Only meaningful when `allowDuplicates` is `true`. Defaults
    ///     to 15 seconds.
    ///   - timeout: The maximum duration of the scan. `nil` (the default) scans until the
    ///     consumer stops it; on elapsing, the stream finishes cleanly.
    /// - Returns: A single-consumer stream of ``ScanEvent``s.
    ///
    /// - Note: On iOS, `allowDuplicates: true` or omitting `services` while backgrounded
    ///   fails the scan automatically (``BLESwiftError/allowDuplicatesInBackgroundNotSupported``/
    ///   ``BLESwiftError/missingServiceIdentifiersInBackground``) — both increase
    ///   battery/CPU cost and `allowDuplicates` stops working in the background at all.
    public func scan(
        services: [ServiceIdentifier]?,
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
            lossTimeout: lossTimeout
        )
        activeScan = scan
        isScanningBox.withLock { $0 = true }

        manager?.scanForPeripherals(withServices: services, options: ScanOptions(allowDuplicates: allowDuplicates))

        #if os(iOS)
        installBackgroundGuardIfNeeded(scan: scan, allowDuplicates: allowDuplicates, missingServices: missingServices)
        #endif

        if let timeout {
            scan.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutActiveScan()
            }
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.assumeIsolated { central in
                    central.finishActiveScan()
                }
            }
        }

        log("Scan started (allowDuplicates: \(allowDuplicates))", level: .info, category: "scan")

        return stream
    }

    /// Routes a `CentralEvent/didDiscover` event to the active scan, if any — a discovery
    /// delivered after the scan ended is silently dropped. Emits exactly one ``ScanEvent``
    /// per call.
    private func handleDiscovery(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int) {
        guard let scan = activeScan else { return }

        let newDiscovery = Discovery(peripheral: peripheral, advertisement: advertisement, rssi: rssi)

        // Only allowDuplicates scans track loss — refreshed even if throttled below, since a
        // throttled sighting is still evidence the peripheral hasn't gone silent.
        if scan.allowDuplicates {
            scheduleLossTimer(for: peripheral, in: scan)
        }

        guard let existing = scan.discoveries[peripheral.uuid] else {
            scan.discoveries[peripheral.uuid] = newDiscovery
            scan.continuation.yield(.discovered(newDiscovery))
            return
        }

        // Throttled: don't update the stored discovery (so the next sighting's delta is
        // still computed against the last *reported* RSSI), and don't yield anything.
        if let threshold = scan.rssiThreshold, abs(existing.rssi - rssi) < threshold {
            return
        }

        scan.discoveries[peripheral.uuid] = newDiscovery

        if scan.allowDuplicates {
            scan.continuation.yield(.updated(newDiscovery))
        }
    }

    /// (Re)schedules `peripheral`'s loss-expiry deadline: cancels any existing timer and
    /// starts a fresh `lossTimeout`-long one. Only called for `allowDuplicates` scans.
    ///
    /// A sanctioned `Task { }` site: stored in `ActiveScan.lossTimers` so it's always cancellable.
    private func scheduleLossTimer(for peripheral: PeripheralIdentifier, in scan: ActiveScan) {
        scan.lossTimers[peripheral.uuid]?.cancel()

        let lossTimeout = scan.lossTimeout
        scan.lossTimers[peripheral.uuid] = Task { [weak self] in
            try? await Task.sleep(for: lossTimeout)
            guard !Task.isCancelled else { return }
            await self?.handleLoss(of: peripheral)
        }
    }

    /// Reports `peripheral` as ``ScanEvent/lost(_:)`` if still tracked by the active scan —
    /// it may have already been re-sighted or the scan may have already ended.
    private func handleLoss(of peripheral: PeripheralIdentifier) {
        guard let scan = activeScan else { return }
        guard let discovery = scan.discoveries.removeValue(forKey: peripheral.uuid) else { return }
        scan.lossTimers.removeValue(forKey: peripheral.uuid)
        scan.continuation.yield(.lost(discovery))
    }

    /// Finishes the active scan's stream cleanly (no error) after its `timeout:` elapses.
    /// Synchronously triggers ``finishActiveScan()`` via the stream's `onTermination`.
    private func timeoutActiveScan() {
        guard activeScan != nil else { return }
        log("Scan timed out", level: .info, category: "scan")
        activeScan?.continuation.finish()
    }

    /// Finishes the active scan's stream by throwing `error`, if a scan is active. Called
    /// when the radio leaves `.poweredOn` (wired into ``failAllPendingOperations(error:)``)
    /// and, on iOS, when a backgrounding guard fires.
    private func failActiveScan(_ error: BLESwiftError) {
        guard activeScan != nil else { return }
        log("Failing active scan: \(error)", level: .warning, category: "scan")
        activeScan?.continuation.finish(throwing: error)
    }

    /// The single cleanup path for an ended scan: cancels every loss timer and the timeout
    /// task, removes the backgrounding observer (iOS), stops the hardware scan (only if
    /// still `.poweredOn`), and clears ``activeScan``/``isScanning``.
    ///
    /// The only caller is the `onTermination` handler installed by
    /// ``scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``. Idempotent
    /// (guards on ``activeScan`` non-`nil`).
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

    #if os(iOS)
    /// Installs a `UIApplication.didEnterBackgroundNotification` observer that fails the
    /// scan per Apple's background-scanning restrictions, if needed. A no-op otherwise.
    ///
    /// Hops back into actor isolation via `queue.async` + `assumeIsolated` — not `Task { }`
    /// — since the notification handler can fire on an arbitrary thread.
    private func installBackgroundGuardIfNeeded(scan: ActiveScan, allowDuplicates: Bool, missingServices: Bool) {
        guard allowDuplicates || missingServices else { return }

        scan.backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.assumeIsolated { central in
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
    /// Returns a stream of every ``RestorationEvent``, replaying every event buffered since
    /// this `Central` was created to the first consumer, in order — restoration happens
    /// during app launch, typically before any consumer has subscribed.
    ///
    /// Events appear only when ``Configuration/restoration`` was set.
    public func restorationEvents() -> AsyncStream<RestorationEvent> {
        restorationBroadcaster.stream()
    }
    #else
    /// Internal mirror of the iOS-only public `restorationEvents()` — see the dual-access
    /// note in `RestorationConfiguration.swift`. Reachable off-iOS only via `@testable`.
    func restorationEvents() -> AsyncStream<RestorationEvent> {
        restorationBroadcaster.stream()
    }
    #endif

    /// Reacts to a radio state change on behalf of restoration: `.poweredOn` completes a
    /// staged restoration or closes the startup window if nothing is pending; any other
    /// state fails a staged restoration with ``BLESwiftError/bluetoothUnavailable`` and
    /// emits ``RestorationEvent/failedToRestoreConnection(_:error:)`` for each.
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
            // In-flight `restorationTasks` are not touched here: the radio loss fails each
            // one on its own; `closeStartupWindowIfIdle()` below closes the window only once
            // every entry has resolved.
            closeStartupWindowIfIdle()
        }
    }

    /// Routes `.poweredOn` restoration: restored-*connected* → adopted as a live session;
    /// restored-*connecting* → its own manual re-connect task; restored-*disconnecting*/
    /// *disconnected* → ``RestorationEvent/failedToRestoreConnection(_:error:)``. The startup
    /// window closes once every outcome has resolved.
    ///
    /// - Warning: The `disconnecting`/`disconnected` paths have no known way to recreate or
    ///   test on real hardware.
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

    /// Adopts a restored-*connected* peripheral as a live session — no CoreBluetooth
    /// connection work needed. GATT operations work immediately; `.connected` is emitted on
    /// ``connectionEvents()``.
    ///
    /// Policy is ``ReconnectPolicy/never`` — no `connect` call existed to specify one.
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

        // Wire event delivery before the session goes live. Idempotent with the early
        // wiring `handle(_: CentralEvent)`'s `.willRestoreState` case performs.
        target.eventHandler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated { $0.handle(event, from: identifier) }
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

    /// Issues the manual re-connect for a restored-*connecting* peripheral — CoreBluetooth
    /// restores the attempt's existence but never completes it, so BLESwift must connect
    /// explicitly, with a default 15 s timeout configurable via ``RestorationConfiguration``.
    private func startRestorationConnect(_ identifier: PeripheralIdentifier) {
        let timeout = configuration.restoration?.connectingTimeout ?? .seconds(15)
        log("Restored peripheral \(identifier) was connecting — issuing manual re-connect (timeout: \(timeout))", level: .info, category: "restore")
        restorationTasks[identifier] = Task { [weak self] in
            await self?.runRestorationConnect(identifier: identifier, timeout: timeout)
        }
    }

    /// The body of one ``restorationTasks`` entry: one manual connect attempt for
    /// `identifier`, always followed by removing its own entry and closing the startup
    /// window if idle.
    ///
    /// Calls ``establishConnection(identifier:policy:timeout:warningOptions:)`` directly
    /// rather than `connect(...)` — the public method's `pendingRestoration` guard exists to
    /// fence *user* calls out of this window.
    private func runRestorationConnect(identifier: PeripheralIdentifier, timeout: Duration) async {
        // Expiration-vs-routing race guard: this task's body runs a hop after being spawned
        // — if the startup background task expired in that gap, this is the one place that
        // still needs to fail the connect with its full timeout despite the window being closed.
        guard startupWindowOpen else {
            // Silent when cancelled: teardown, not an expiration to report.
            if !Task.isCancelled {
                log("Startup window closed before the restoration connect could start — failing restoration for \(identifier)", level: .warning, category: "restore")
                restorationBroadcaster.yield(.failedToRestoreConnection(identifier, error: BLESwiftError.startupBackgroundTaskExpired))
            }
            restorationTasks.removeValue(forKey: identifier)
            return
        }

        do {
            // Reserve the slot synchronously — throws `.duplicateConnect` if a user
            // `connect(id)` for this same restored id landed first.
            try reserveConnectingSlot(
                identifier: identifier,
                policy: .never,
                timeout: timeout,
                warningOptions: configuration.warningOptions
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

    /// Reacts to iOS expiring the startup background task before restoration finished:
    /// every pending restoration operation fails with
    /// ``BLESwiftError/startupBackgroundTaskExpired`` — a staged-but-unrouted
    /// ``pendingRestoration``, and every in-flight ``restorationTasks`` entry.
    private func handleStartupBackgroundTaskExpiration() {
        guard startupWindowOpen else { return }
        log("Startup background task expired during restoration", level: .warning, category: "restore")

        if let pending = pendingRestoration {
            pendingRestoration = nil
            for peripheral in pending.peripherals {
                restorationBroadcaster.yield(.failedToRestoreConnection(peripheral.identifier, error: BLESwiftError.startupBackgroundTaskExpired))
            }
        }

        // Snapshot keys first — never iterate a map while mutating it.
        for identifier in Array(restorationTasks.keys) {
            // Each task's own catch removes its own entry once cancelled; the window is
            // closed unconditionally below regardless.
            failPendingConnect(for: identifier, error: BLESwiftError.startupBackgroundTaskExpired)
        }

        endStartupBackgroundTask()
    }

    /// Closes the startup restoration window once every restoration outcome has resolved.
    /// Safe to call speculatively — a no-op while anything is pending.
    private func closeStartupWindowIfIdle() {
        guard pendingRestoration == nil, restorationTasks.isEmpty else { return }
        endStartupBackgroundTask()
    }

    /// Closes the startup restoration window: ends the platform background task (see
    /// `StartupBackgroundTaskRunning`) exactly once. Idempotent via ``startupWindowOpen``;
    /// a no-op whenever restoration was never enabled.
    private func endStartupBackgroundTask() {
        guard startupWindowOpen else { return }
        startupWindowOpen = false
        startupBackgroundTask.end()
        log("Startup restoration window closed", level: .debug, category: "restore")
    }

    // MARK: - Logging

    /// Writes `message` to ``configuration``'s `swift-log` `Logger` — BLESwift's single
    /// internal log call site.
    private func log(_ message: @autoclosure () -> Logger.Message, level: Logger.Level, category: String) {
        configuration.logger.log(level: level, message(), metadata: ["category": .string(category)])
    }
}

// MARK: - Connection state machine

/// `Central`'s internal per-peripheral connection state machine — file-private for the
/// associated structs' visibility. ``Central/connectionState(of:)`` projects it into the
/// public ``ConnectionState``. No `.idle` case: absence of a ``Central/connections`` entry
/// IS idle.
private enum PeripheralPhase {
    /// A connection attempt is in progress.
    case connecting(Connecting)
    /// Connected.
    case connected(Session)
    /// Disconnecting — either an explicit `disconnect(_:)`/`disconnect(_:immediate:)` is in
    /// flight, or `cancelAllOperations` cancelled a pending connection attempt.
    case disconnecting(Disconnecting)
}

/// One independent auto-reconnect loop, tracked per peripheral in
/// ``Central/reconnectLoops``. Pairs the loop's `Task` with the generation it was spawned
/// with — see ``Central/clearReconnectLoopIfCurrent(id:generation:)``.
private struct ReconnectLoop {
    var task: Task<Void, Never>
    var generation: UInt64
}

/// State for a connection attempt in progress. Holds the single pending connect
/// continuation for this peripheral and the two-phase cancel's `stopping` flag.
private struct Connecting {
    let identifier: PeripheralIdentifier
    let peripheral: any PeripheralRemote
    let policy: ReconnectPolicy
    let timeout: Duration?
    let warningOptions: WarningOptions
    /// The pending connect continuation. `nil` when reserved-but-unattached (between
    /// `reserveConnectingSlot` writing this entry and `awaitConnect` attaching its
    /// continuation) or once taken (resumed and cleared). Resumed exactly once, by
    /// `Central.handleTermination(identifier:error:)` — never directly by whatever requests
    /// cancellation.
    var continuation: CheckedContinuation<Peripheral, Error>?
    /// Non-`nil` once cancellation (task cancellation, timeout, `cancelAllOperations`) has
    /// been requested for this attempt — the error `continuation` will eventually resume
    /// with, once CoreBluetooth confirms.
    var stopping: Error?
}

/// State for one established connection. Also holds every piece of GATT bookkeeping — so
/// disconnect cleanup drops it structurally along with the rest of the connection, and
/// multi-peripheral isolation falls out for free.
private struct Session {
    let identifier: PeripheralIdentifier
    let peripheral: any PeripheralRemote
    let policy: ReconnectPolicy
    let timeout: Duration?
    let warningOptions: WarningOptions

    // MARK: - GATT

    /// Per-characteristic FIFO tail-chain — see `Central.runOnFIFO(identifier:characteristic:operation:)`.
    var fifoTails: [CharacteristicIdentifier: Task<Void, Never>] = [:]

    /// The RSSI-only counterpart to ``fifoTails``: `readRSSI()` has no owning
    /// characteristic, so it is serialized via a single tail instead of a per-characteristic
    /// map. See `Central.runRSSISerialized(identifier:operation:)`.
    var rssiTail: Task<Void, Never>?

    /// The single pending read continuation per characteristic. Single-slot, guaranteed by
    /// ``fifoTails``. Take-then-resume.
    var pendingReads: [CharacteristicIdentifier: CheckedContinuation<Data, Error>] = [:]

    /// The single pending write continuation for each characteristic currently being
    /// written (`.withResponse` only — `.withoutResponse` synthesizes completion
    /// immediately and never registers here). See ``pendingReads``.
    var pendingWrites: [CharacteristicIdentifier: CheckedContinuation<Void, Error>] = [:]

    /// The single pending notify-state-change continuation per characteristic. Resumes with
    /// the resulting `isNotifying` value.
    var pendingNotifyStateChanges: [CharacteristicIdentifier: CheckedContinuation<Bool, Error>] = [:]

    /// The single pending RSSI-read continuation, if any. Single-slot, guaranteed by
    /// ``rssiTail``.
    var pendingRSSIRead: CheckedContinuation<Int, Error>?

    /// Pending service-discovery waiters, keyed by a monotonic token — **not** by service:
    /// `didDiscoverServices(error:)` carries no service identifier, so every waiter is
    /// resumed on every completion and independently re-checks its own service afterward.
    /// Tokened so a single cancelled waiter can be removed without disturbing others.
    var pendingDiscoverServices: [UInt64: CheckedContinuation<Void, Error>] = [:]

    /// Pending characteristic-discovery waiters, keyed by service (which
    /// `didDiscoverCharacteristics(service:error:)` does carry) and then by per-waiter token.
    var pendingDiscoverCharacteristics: [ServiceIdentifier: [UInt64: CheckedContinuation<Void, Error>]] = [:]

    /// Pending waiters for `.isReadyToSendWriteWithoutResponse`. Not keyed by characteristic
    /// — CoreBluetooth's readiness signal is peripheral-wide.
    var pendingWriteWithoutResponseReady: [UInt64: CheckedContinuation<Void, Error>] = [:]

    /// The single pending descriptor-read continuation per descriptor. Single-slot,
    /// guaranteed by the parent characteristic's FIFO lane.
    var pendingDescriptorReads: [DescriptorIdentifier: CheckedContinuation<Data, Error>] = [:]

    /// The single pending descriptor-write continuation for each descriptor currently being
    /// written (descriptor writes are always with-response). See ``pendingDescriptorReads``.
    var pendingDescriptorWrites: [DescriptorIdentifier: CheckedContinuation<Void, Error>] = [:]

    /// Pending descriptor-discovery waiters, keyed by characteristic and then by per-waiter
    /// token.
    var pendingDiscoverDescriptors: [CharacteristicIdentifier: [UInt64: CheckedContinuation<Void, Error>]] = [:]

    // MARK: - GATT enumeration cache

    /// Whether a full-graph service enumeration has completed for this connection. Unlike
    /// targeted discovery, "list all services" has no single identifier to re-check, so this
    /// flag serves as the cache. Reset to `false` on `didModifyServices`.
    var didEnumerateServices = false

    /// Services whose characteristics have been fully enumerated for this connection.
    /// Invalidated entries removed on `didModifyServices`.
    var enumeratedCharacteristicServices: Set<ServiceIdentifier> = []

    /// Characteristics whose descriptors have been fully enumerated for this connection.
    var enumeratedDescriptorCharacteristics: Set<CharacteristicIdentifier> = []

    // MARK: - Notifications

    /// The active notification subscription for each characteristic currently being
    /// listened to. Lives inside `Session` so disconnect cleanup drops it structurally.
    var notificationSubscriptions: [CharacteristicIdentifier: NotificationSubscription] = [:]

    /// The per-subscriber pump task for each `Peripheral.notifications(for:policy:)`
    /// subscriber — a ledgered `Task { }` site (see `Central.startNotificationPump(peripheral:characteristic:token:deliver:finish:)`).
    var notificationPumps: [UUID: Task<Void, Never>] = [:]

    // MARK: - L2CAP

    /// Pending L2CAP channel-open waiters, keyed by the same monotonic token as the GATT
    /// discovery waiters. FIFO-matched: a `didOpenL2CAPChannel` resolves the oldest waiter.
    var pendingL2CAPOpens: [UInt64: CheckedContinuation<any L2CAPChannelRemote, Error>] = [:]

    /// Every open L2CAP channel's transport, keyed by its `L2CAPChannel` handle's
    /// registration token. Torn down by disconnect cleanup or an explicit `L2CAPChannel.close()`.
    var l2capChannels: [UUID: any L2CAPChannelRemote] = [:]

    /// The single `Session`-building shape for every **adoption** path — the peripheral is
    /// already connected, so no `connect` call exists to have specified a policy or timeout.
    /// Policy is ``ReconnectPolicy/never``.
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
            warningOptions: warningOptions
        )
    }

    /// Backs ``nextGATTWaiterToken()``.
    private var nextWaiterTokenValue: UInt64 = 0

    /// Hands out a fresh, monotonically increasing token identifying one GATT waiter —
    /// letting a single cancelled waiter be removed by key without disturbing others.
    mutating func nextGATTWaiterToken() -> UInt64 {
        defer { nextWaiterTokenValue += 1 }
        return nextWaiterTokenValue
    }
}

/// One characteristic's active notification subscription: the raw-`Data` multicast every
/// subscriber shares, plus the refcount driving `setNotifyValue`'s lifecycle.
private struct NotificationSubscription {
    /// The raw-`Data` multicast: decode happens per caller, in each subscriber's own decode
    /// layer, so one subscriber's decode failure can't affect the others.
    let broadcaster = ThrowingBroadcaster<Data>()

    /// One token per live subscriber. A token set (not a bare count) so release is
    /// idempotent — a stray double-release can't underflow the refcount.
    var subscriberTokens: Set<UUID> = []

    /// Whether the `setNotifyValue(true)` handshake has completed. Notifications received
    /// before confirmation are still multicast; late joiners await this instead of racing it.
    var enableConfirmed = false

    /// Joiners suspended waiting for ``enableConfirmed``, keyed by subscriber token.
    /// Take-then-resume.
    var enableWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
}

/// A single-consumer box around an `AsyncThrowingStream` iterator, letting
/// `Central.performFlush(peripheral:characteristic:quietPeriod:)` re-`await` `next()` inside
/// successive `withTimeout` races — whose `@Sendable` closures can't capture a mutable local
/// iterator directly.
///
/// `iterator` is `nonisolated(unsafe)` (not a type-wide `@unchecked Sendable`, which stays
/// grep-forbidden) because access is strictly sequential by construction: each
/// `withTimeout` window fully completes before the next begins.
private final class SequentialAccessIterator<Element: Sendable>: Sendable {
    nonisolated(unsafe) private var iterator: AsyncThrowingStream<Element, Error>.Iterator

    init(_ stream: AsyncThrowingStream<Element, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    /// Advances the boxed iterator. Callers must uphold the strictly-sequential access
    /// contract described on this type.
    func next() async throws -> Element? {
        try await iterator.next()
    }
}

/// State while disconnecting — either an explicit `disconnect` call (`continuation`
/// non-`nil`) or `cancelAllOperations` cancelling a pending connect attempt (`nil`).
private struct Disconnecting {
    let identifier: PeripheralIdentifier
    let peripheral: any PeripheralRemote
    /// The `disconnect()`/`disconnect(immediate:)` call's own continuation, if this
    /// `Disconnecting` was entered that way.
    var continuation: CheckedContinuation<Void, Error>?
    /// A connect attempt's continuation, carried over if `disconnect`/`cancelAllOperations`
    /// interrupted a `.connecting` phase — resolved (with `connectFailureReason`) alongside
    /// `continuation` once cleanup runs.
    var connectContinuation: CheckedContinuation<Peripheral, Error>?
    /// The error `connectContinuation` resolves with — `.explicitDisconnect` for
    /// `disconnect`, or `cancelAllOperations(error:)`'s caller-supplied error.
    let connectFailureReason: Error
}
