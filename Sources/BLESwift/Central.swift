//
//  Central.swift
//  BLESwift
//

// `@preconcurrency`: CoreBluetooth's types (`CBCentralManager`, `CBPeripheral`, …) predate
// Swift's Sendable audit and are not marked `Sendable` (never mark them
// unchecked-`Sendable`). `stopAndExtractState()` below hands a `CBCentralManager` back to
// a caller outside this actor's isolation domain — a legitimate one-time ownership
// transfer (this actor gives up its own reference in the same call) — which only
// type-checks against `CBCentralManager`'s *unaudited* Sendability under `@preconcurrency`;
// without it, returning any non-Sendable CoreBluetooth type from an actor-isolated method
// is rejected outright, with no `sending`-based escape hatch available for a type that
// originated in the actor's own isolated storage (verified: `sending` alone still fails
// with "'self'-isolated uses may race with caller uses" here).
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
/// `Central`'s isolation is tied directly to the `DispatchSerialQueue` its underlying
/// `CBCentralManager` delivers delegate callbacks on (see ``unownedExecutor``) — BLESwift's
/// core architectural move (no other actor-based CoreBluetooth wrapper does this
/// in the survey of prior art this project drew on). Every `CentralDelegateProxy` callback is therefore already running on
/// `Central`'s own executor, letting it forward into actor-isolated code via
/// `assumeIsolated` with no thread hop and no risk of the ordering hazards a `Task { }`
/// hop from a delegate callback would introduce.
public actor Central {

    /// The `DispatchSerialQueue` this actor's executor is tied to (see
    /// ``unownedExecutor``), and the same queue the underlying `CBCentralManager`/`CBPeripheral`
    /// deliver delegate callbacks on.
    nonisolated let queue: DispatchSerialQueue

    /// Ties this actor's isolation directly to `queue` (SE-0424 custom executors).
    /// `DispatchSerialQueue` conforms to `SerialExecutor` and is available unconditionally
    /// on BLESwift's deployment floor (iOS 18/macOS 15). Declared `public` because it
    /// satisfies a requirement of the public `Actor` protocol; it is not meant to be used
    /// directly by BLESwift clients.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// The CoreBluetooth shim this `Central` drives — a real `CBCentralManager` in
    /// production, a `FakeCentral` in tests.
    ///
    /// `Optional` and `var`, not `let`, specifically so ``stopAndExtractState()`` can
    /// `nil` this out as part of handing its underlying `CBCentralManager` to the caller.
    /// That's required, not just tidy: `CBCentralManager` is not `Sendable` (never mark
    /// it unchecked-`Sendable`), so returning one from this actor-isolated
    /// type across an isolation boundary is only sound if `Central` gives up its own
    /// reference in the same call — otherwise the compiler's region-isolation checker
    /// correctly rejects the aliasing (two live references to one non-Sendable class
    /// instance straddling actor isolation).
    private var manager: (any CentralManaging)?

    /// Read-only access to ``manager`` for extensions of `Central` declared in other files
    /// within this module (e.g. `Central+Retrieval.swift`) — `private` is file-scoped, so
    /// `manager` itself isn't visible there. Not for use outside `BLESwift`.
    internal var shim: (any CentralManaging)? { manager }

    /// This `Central`'s `CBCentralManagerDelegate`, strongly owned here so it outlives the
    /// gap between its creation and `CBCentralManager(delegate:queue:options:)` (required —
    /// `willRestoreState` can arrive during manager init, before this `Central` can wire
    /// its handler). Non-`nil` only for ``init(configuration:)``, which alone needs this
    /// construction-order bypass — see the doc comment on `CBCentralManager`'s
    /// `eventHandler` conformance for why every other init path wires event delivery via
    /// that computed property instead (and so never needs to store its own proxy here).
    private let proxy: CentralDelegateProxy?

    /// The configuration this `Central` was created with.
    private let configuration: Configuration

    /// Backs the nonisolated, synchronously-readable ``state`` snapshot. `Mutex` rather
    /// than actor-isolated storage specifically so ``state`` can be read without `await`
    /// from any isolation domain (`Mutex` is unconditionally usable for tiny
    /// non-actor state on our deployment floor). The actor-isolated ``handle(_:)`` is the
    /// only writer.
    private let stateBox = Mutex<CentralState>(.unknown)

    /// Multicasts every ``CentralState`` transition to every ``stateEvents()`` subscriber,
    /// replaying the latest value to late subscribers.
    private let stateBroadcaster = Broadcaster<CentralState>(replay: .latest)

    /// The in-progress scan, if any — `nil` when no
    /// ``scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)`` call is active.
    /// `Central` holds at most one at a time (BLESwift's single-scan discipline: CoreBluetooth
    /// exposes a single physical scanner).
    private var activeScan: ActiveScan?

    /// Backs the nonisolated, synchronously-readable ``isScanning`` snapshot, mirroring
    /// whether ``activeScan`` is non-`nil`. `Mutex` rather than actor-isolated storage for
    /// the same reason ``stateBox`` is: so `isScanning` remains readable without `await`
    /// from any isolation domain. The scan-handling methods below are the only writers.
    private let isScanningBox = Mutex<Bool>(false)

    /// This `Central`'s per-peripheral connection state machine, keyed by
    /// ``PeripheralIdentifier``. `private` — connection lifecycle is entirely internal
    /// bookkeeping; callers only ever see it through ``connectionState(of:)``,
    /// ``connectedPeripherals``, ``connectionEvents()``, and the `Peripheral` handles
    /// `connect` hands back.
    ///
    /// Absence of an entry for a given identifier IS that peripheral's idle state — there
    /// is no `.idle` case in ``PeripheralPhase``. An entry exists for exactly as long as
    /// that peripheral is connecting, connected, or disconnecting.
    private var connections: [PeripheralIdentifier: PeripheralPhase] = [:]

    /// One independent auto-reconnect loop per peripheral, running while that peripheral
    /// has no ``connections`` entry (mid-backoff) — the **one** sanctioned unstructured
    /// `Task` site for connection lifecycle in `Sources/` (scanning's loss/timeout timers,
    /// above, are a separately-tracked unstructured `Task` site of their own). Genuinely
    /// unstructured background work (a retry loop that outlives any single
    /// `connect`/`disconnect(_:)` call), not a delegate-callback hop. Each loop is
    /// cancelled by that peripheral's own explicit disconnect, a new `connect` to it,
    /// `cancelAllOperations(error:)`/`disconnectAll()`, and `deinit`.
    private var reconnectLoops: [PeripheralIdentifier: ReconnectLoop] = [:]

    /// A global, actor-wide monotonic generation allocator — incremented every time
    /// ``scheduleReconnect(identifier:policy:timeout:warningOptions:)`` starts a new loop,
    /// for any peripheral. Each ``ReconnectLoop`` stores the generation it was spawned
    /// with; ``clearReconnectLoopIfCurrent(id:generation:)`` compares against
    /// `reconnectLoops[id]?.generation` before clearing that peripheral's entry — see that
    /// method's doc comment.
    private var reconnectGeneration: UInt64 = 0

    /// Multicasts every ``ConnectionEvent`` to every ``connectionEvents()`` subscriber.
    /// Replay `.none`: a late subscriber only sees events from the point it subscribes —
    /// unlike ``stateBroadcaster``, there is no single "current value" snapshot that makes
    /// sense to replay (``connectionState(of:)``/``connectedPeripherals`` serve that
    /// purpose instead).
    private let connectionBroadcaster = Broadcaster<ConnectionEvent>(replay: .none)

    /// Per-peripheral `didModifyServices` broadcaster registry, for
    /// ``Peripheral/serviceChanges()``. Replaces a single, un-keyed `Broadcaster` (every
    /// peripheral's invalidations funneled into one shared stream — the one place, prior to
    /// this, where peripheral events did NOT carry identity all the way to the consumer):
    /// each ``PeripheralIdentifier`` now gets its own broadcaster, so peripheral A's
    /// invalidations never reach peripheral B's subscribers.
    ///
    /// Declared `nonisolated` (rather than actor-isolated, like ``stateBroadcaster``/
    /// ``connectionBroadcaster`` above) specifically so ``Peripheral/serviceChanges()`` can
    /// fetch its `AsyncStream` **synchronously**, matching that method's non-`async`
    /// signature: ``ServiceChangesRegistry`` is itself `Sendable` and internally
    /// `Mutex`-guarded (see its doc comment), so exposing it this way needs no actor hop to
    /// stay sound — the same justification already used for ``state``/``isScanning``
    /// above, just applied to a reference type instead of a `Mutex<T>` box directly.
    nonisolated let serviceChangesRegistry = ServiceChangesRegistry()

    // MARK: - Background restoration state

    /// Multicasts every ``RestorationEvent``. Replay `.allUntilFirstConsumer`: every event
    /// is buffered from init and replayed, in order, to the **first**
    /// ``restorationEvents()`` consumer — restoration happens during app launch, typically
    /// before any consumer task has started, and losing those events would defeat the
    /// feature.
    private let restorationBroadcaster = Broadcaster<RestorationEvent>(replay: .allUntilFirstConsumer)

    /// The restored state captured by `CentralEvent.willRestoreState`, held until the
    /// radio's first `.poweredOn` routes it (``routeRestoredPeripherals(_:)``) — staged
    /// between `willRestoreState` and `centralManagerDidUpdateState` delivery.
    private var pendingRestoration: RestoredState?

    /// One in-flight manual re-connect per restored-*connecting* peripheral —
    /// CoreBluetooth never completes a restored-connecting attempt on its own (ledger). A
    /// ledgered actor-owned `Task { }` site under the corrected policy (like
    /// ``reconnectLoops``): each entry is spawned from actor-isolated code
    /// (``startRestorationConnect(_:)``), stored here so it is always cancellable
    /// (explicit `disconnect`/`stopAndExtractState()`/`deinit`), never spawned from the
    /// proxy. Keyed by the peripheral being re-connected — every restored-connecting
    /// peripheral gets its own independent, concurrent manual-connect task;
    /// ``runRestorationConnect(identifier:timeout:)`` removes its own entry on completion.
    private var restorationTasks: [PeripheralIdentifier: Task<Void, Never>] = [:]

    /// The startup background-task seam protecting the restoration window — a real
    /// `UIApplication` background task on iOS with restoration enabled, a no-op otherwise.
    /// See `StartupBackgroundTaskRunning`.
    private let startupBackgroundTask: any StartupBackgroundTaskRunning

    /// Whether the startup restoration window — init (restoration enabled) until
    /// restoration completes or is ruled out — is still open. Guards
    /// ``endStartupBackgroundTask()``'s idempotence; always `false` when restoration is
    /// disabled.
    private var startupWindowOpen = false

    /// Creates a `Central`, synchronously creating its underlying `CBCentralManager` on a
    /// fresh, dedicated `DispatchSerialQueue`.
    ///
    /// Manager creation happens synchronously in `init` — not deferred behind an async
    /// `start()` — because background restoration (added in a later phase) requires
    /// `CBCentralManagerOptionRestoreIdentifierKey` to be supplied at creation time; an
    /// async two-step start would miss restoration events that can arrive before the async
    /// step ever runs.
    ///
    /// - Parameter configuration: Start-time options. Defaults to `Configuration()`. On
    ///   iOS, a non-`nil` `configuration.restoration` registers its identifier with
    ///   CoreBluetooth (`CBCentralManagerOptionRestoreIdentifierKey`) at manager creation
    ///   and opens the startup restoration window (see `StartupBackgroundTaskRunning`).
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

        // `self` is fully initialized (every stored property has a value) by this point,
        // so it can now be captured — see the doc comment on `proxy` for why this sets
        // `proxy.handler` directly instead of going through `manager.eventHandler`
        // (bypassing the associated-object mechanism, which would create a second, wrong
        // proxy instance disconnected from the one already passed to the manager above).
        proxy.handler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated { $0.handle(event) }
        }

        // Open the startup background-time window (a no-op runner off-iOS/without
        // restoration). Begun *after* manager creation only because an escaping closure
        // cannot capture `self` until every stored property is initialized — the platform
        // begin is itself an asynchronous main-queue hop either way (see
        // `UIKitStartupBackgroundTask`), and the app cannot be suspended mid-launch, so
        // the window's protection holds regardless of whether the begin call precedes
        // manager creation.
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
    /// already-connected `CBPeripheral`) created by other code — the counterpart to
    /// ``stopAndExtractState()``.
    ///
    /// - Important: `callbackQueue` **must be the exact `DispatchSerialQueue` instance**
    ///   `manager` was created with (i.e. the `queue:` argument originally passed to
    ///   `CBCentralManager(delegate:queue:options:)`). `CBCentralManager` has no public API
    ///   to report which queue it delivers delegate callbacks on, so `Central` cannot
    ///   verify this itself — passing the wrong queue is **not detectable eagerly**: this
    ///   initializer will succeed, and the mismatch only surfaces as an `assumeIsolated`
    ///   trap the first time a real CoreBluetooth delegate callback arrives on a thread
    ///   that isn't actually `callbackQueue` (see `CentralDelegateProxy`). If `manager`
    ///   was created with `queue: nil` (CoreBluetooth's default, which delivers on the main
    ///   queue), pass `DispatchQueue.main as! DispatchSerialQueue` — this downcast is
    ///   runtime-verified to succeed (the main queue is always serial).
    ///
    /// - Parameters:
    ///   - manager: The existing `CBCentralManager` to adopt. `Central` installs its own
    ///     event delivery (via `manager.eventHandler`, backed by a fresh
    ///     `CentralDelegateProxy`) as its delegate, replacing whatever delegate it had.
    ///   - connectedPeripherals: Every already-connected `CBPeripheral`, if any. Each is
    ///     adopted as a live session: its event delivery is re-pointed at this `Central`
    ///     (so its GATT callbacks route here), ``connectionState(of:)`` reports
    ///     `.connected` with its `Peripheral` handle immediately, GATT operations work
    ///     through the normal machinery, and `.connected` is emitted on
    ///     ``connectionEvents()`` per peripheral (note that stream has no replay and no
    ///     subscriber can exist before this initializer returns — use
    ///     ``connectionState(of:)``/``connectedPeripherals`` for the adoption snapshot).
    ///     Every adopted session's ``ReconnectPolicy`` is ``ReconnectPolicy/never`` — no
    ///     `connect` call existed to specify one; observe the eventual disconnect and
    ///     reconnect with your preferred policy if desired. Defaults to `[]`.
    ///   - callbackQueue: The exact `DispatchSerialQueue` `manager` delivers delegate
    ///     callbacks on. Required, with no default — see the invariant above.
    ///   - configuration: Start-time options. Note that `showPowerAlert` has no effect
    ///     here: `manager` already exists, so `CBCentralManagerOptionShowPowerAlertKey`
    ///     cannot be applied retroactively. Defaults to `Configuration()`.
    public init(
        adopting manager: CBCentralManager,
        connectedPeripherals: [CBPeripheral] = [],
        callbackQueue: DispatchSerialQueue,
        configuration: Configuration = Configuration()
    ) {
        self.queue = callbackQueue
        self.configuration = configuration

        // Restoration can never apply here: a restore identifier must be supplied when
        // the manager is *created*, and this manager already exists — any
        // `configuration.restoration` is inert (documented on `Configuration.restoration`),
        // so no startup restoration window opens.
        self.startupBackgroundTask = NoOpStartupBackgroundTask()

        // `manager` already exists (unlike `init(configuration:)`, which must create its
        // manager against a pre-existing proxy) — so event delivery is wired uniformly via
        // `eventHandler`, letting `CBCentralManager`'s conformance manage its own proxy
        // creation/retention. No `self.proxy` needed for this path.
        self.proxy = nil
        self.manager = manager

        // Seed the synchronous `state` snapshot (and the `stateEvents()` replay buffer)
        // from the adopted manager's current state rather than leaving it at `.unknown` —
        // unlike `init(configuration:)`, this manager may already be past
        // `centralManagerDidUpdateState(_:)` by the time it's adopted, and that first
        // callback won't fire again to correct a stale `.unknown`.
        let adoptedState = CentralState(manager.state)
        stateBox.withLock { $0 = adoptedState }
        stateBroadcaster.yield(adoptedState)

        // Adopt every `connectedPeripherals` entry as a live session (Session.adopted — the
        // single Session-building shape shared with restoration adoption; policy `.never`,
        // since no `connect` call existed to specify one). `.connected` is also yielded on
        // ``connectionEvents()`` per peripheral; note that stream has no replay, and no
        // subscriber can exist before this initializer returns — `connectionState(of:)`/
        // `connectedPeripherals` are the reliable adoption snapshot (documented on the
        // parameter). Every direct stored-property write (here and above) must precede the
        // `eventHandler` closures below: capturing `self` — even weakly — counts as `self`
        // escaping (SE-0327), after which direct property mutation is no longer permitted
        // in this synchronous init.
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

        // `self` is fully initialized (every stored property has a value) by this point,
        // so it can now be captured. Event delivery is wired last — after every session (if
        // any) already exists — matching every other session-creating path's intent (wire
        // before the session is *usable* by external callers; nothing external can observe
        // this `Central` before this initializer returns).
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

    /// Creates a `Central` driving a custom backend — the seam that lets a scriptable
    /// fake (`BLESwiftTestSupport`'s `FakeCentral`) or any other `CentralManaging`
    /// conformance stand in for a real `CBCentralManager`. Production apps use
    /// ``init(configuration:)`` (or ``init(adopting:connectedPeripherals:callbackQueue:configuration:)``
    /// to adopt an existing manager) instead of this initializer.
    ///
    /// - Important: `queue` **must be the exact `DispatchSerialQueue` instance** `backend`
    ///   confines its event deliveries to — the same queue-confined contract
    ///   `CentralManaging`/`PeripheralRemote` document: every event `backend` (and every
    ///   `connectedPeripherals` entry, if given) produces must arrive asynchronously, on
    ///   this exact queue. A mismatched queue is not detectable eagerly and surfaces only
    ///   as an `assumeIsolated` trap the first time an event arrives off-queue (see
    ///   ``init(adopting:connectedPeripherals:callbackQueue:configuration:)`` for the same
    ///   invariant on the production adoption path).
    ///
    /// This initializer wires `backend.eventHandler` (and each adopted peripheral's
    /// `eventHandler`) to this `Central`'s internal `handle(_:)`/`handle(_:from:)`
    /// methods, which stay `internal` — callers never invoke them directly.
    ///
    /// - Important: **Retention.** Unlike ``init(configuration:)``/``init(adopting:connectedPeripherals:callbackQueue:configuration:)``,
    ///   the closures this initializer installs on `backend.eventHandler` (and each
    ///   adopted peripheral's `eventHandler`) capture `self` **strongly**, not weakly —
    ///   `backend` is itself strongly held by this `Central` (`self.manager = backend`), so
    ///   `Central` → `backend` → closure → `Central` is a deliberate cycle, not an
    ///   oversight. This means `backend` alone keeps this `Central` alive for as long as
    ///   `backend` exists, independent of whether anything else still holds a reference to
    ///   the `Central` instance itself — a consumer that does
    ///   `_ = Central(backend: fake, queue: queue)` and discards the result still has a
    ///   live `Central` for as long as `fake` (or whatever holds `fake`) is alive.
    ///   ``stopAndExtractState()`` does **not** break this cycle for a backend-init
    ///   `Central`: it only recognizes a real `CBCentralManager`-backed `manager` and
    ///   throws ``BLESwiftError/stopped`` immediately otherwise, without touching
    ///   `backend.eventHandler`. To release a `Central` created this way deterministically
    ///   — rather than letting it (and `backend`) live until `backend` itself is
    ///   deallocated, or the process exits — clear the cycle explicitly:
    ///   `backend.eventHandler = nil` (and each adopted peripheral's `eventHandler = nil`,
    ///   if any were adopted). If you never connect and don't need deterministic teardown, this is
    ///   harmless and expected for the short-lived test rigs this initializer exists for.
    ///
    /// - Parameters:
    ///   - backend: The `CentralManaging` conformance to drive.
    ///   - queue: The `DispatchSerialQueue` `backend`'s events are confined to. Must be the
    ///     same queue instance `backend` was created with — see the invariant above.
    ///   - configuration: Start-time options. Defaults to `Configuration()`.
    ///   - startupBackgroundTask: An injected startup background-task seam (see
    ///     `StartupBackgroundTaskRunning`); `nil` (the default) uses a no-op. When
    ///     `configuration.restoration` is non-`nil`, this mirrors the production
    ///     restoration window: it begins the (injected or no-op) task with the same
    ///     expiration wiring.
    ///   - connectedPeripherals: `PeripheralRemote`s to adopt as live sessions, mirroring
    ///     ``init(adopting:connectedPeripherals:callbackQueue:configuration:)``'s adoption
    ///     structure (same `Session.adopted` shape, same eventHandler-before-
    ///     session-goes-live ordering, same `.connected` emission per peripheral) — that
    ///     initializer itself requires real CoreBluetooth objects, so this is how its
    ///     adoption structure is exercised without hardware. Defaults to `[]`.
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

        // Every direct stored-property write (here and above) must precede the
        // `eventHandler` closures below: capturing `self` — even weakly — counts as
        // `self` escaping (SE-0327), after which direct property mutation is no longer
        // permitted in this synchronous init. Mirrors `init(adopting:connectedPeripherals:...)`'s
        // adoption structure.
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

        // `self` is fully initialized (every stored property has a value) by this point,
        // so it can now be captured. Wiring is hopped onto `queue` via `queue.sync` (safe:
        // nothing else can be running on `queue` during init) because `backend`'s (and, if
        // adopting, each connected peripheral's) `eventHandler` setter may be
        // queue-confined, as `FakeCentral`/`FakePeripheral`'s are — precedented by the old
        // test init's equivalent off-queue attach.
        //
        // Captures `self` strongly (unlike the production paths' `[weak self]`, which
        // exist to avoid a real `Central` ↔ `CBCentralManager`/`CBPeripheral` retain cycle
        // in a long-lived app): `self.manager = backend` above already means `Central`
        // strongly owns `backend`, so a strong capture here forms a `Central` → `backend`
        // → closure → `Central` cycle deliberately, matching the old internal test init's
        // behavior exactly (also uncaptured-weak). This is what keeps a `Central` alive in
        // tests that discard their direct reference (`let (_, fakeCentral, ...) = ...`) —
        // a real, if incidental, dependency of this package's own test suite. Production
        // callers own `backend`/`connectedPeripherals` themselves (a real `CBCentralManager`/
        // `CBPeripheral`s), not `Central`, so this initializer is not the production path
        // that cycle-avoidance protects; those paths use `init(configuration:)`/
        // `init(adopting:)` instead.
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

    /// Cancels any in-flight auto-reconnect loop and restoration re-connect. Actors
    /// support ordinary (non-`isolated`) `deinit`s that touch their own isolated storage
    /// directly — no concurrent access is possible once deinitialization has started — so
    /// this needs no `Task` hop and no `isolated deinit` (unstable, forbidden).
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
    /// hands the manager back to the caller so it can be adopted by other code (e.g.
    /// another CoreBluetooth wrapper, or raw `CoreBluetooth` calls).
    ///
    /// Where a naive implementation might use `precondition`s (manager exists; not still
    /// connecting) that crash the caller on failure, BLESwift never crashes: both become
    /// thrown ``BLESwiftError/stopped`` cases below.
    ///
    /// - Returns: The underlying `CBCentralManager`, and every `CBPeripheral` this `Central`
    ///   was connected to at the time, sorted by identifier for determinism.
    /// - Throws: ``BLESwiftError/stopped`` if this `Central` has already been stopped, was not
    ///   created against a real `CBCentralManager` (only reachable via the internal
    ///   test-only initializer — never through the public API), or ANY tracked peripheral
    ///   currently has a connection attempt or disconnect in progress (extracting mid-attempt
    ///   would strand its pending continuation forever, since detaching the delegate means no
    ///   further CoreBluetooth callback will ever resolve it).
    public func stopAndExtractState() throws -> (manager: CBCentralManager, peripherals: [CBPeripheral]) {
        guard let currentManager = manager else {
            throw BLESwiftError.stopped
        }
        guard let cbManager = currentManager as? CBCentralManager else {
            throw BLESwiftError.stopped
        }

        // Any entry that isn't `.connected` (i.e. `.connecting` or `.disconnecting`, for
        // ANY peripheral) blocks extraction entirely — see the throws documentation above.
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
        connections.removeAll()

        // Give up this actor's own reference before returning `cbManager` — see the
        // ``manager`` property's doc comment for why that's required, not just tidy.
        manager = nil
        cbManager.delegate = nil
        // Detach every extracted peripheral's event delivery too — its new owner installs
        // its own delegate; leaving ours would route callbacks into a stopped Central.
        for (_, peripheral) in connectedPeripherals {
            peripheral.eventHandler = nil
        }
        proxy?.handler = nil

        return (cbManager, connectedPeripherals.map(\.peripheral))
    }

    // MARK: - Public surface

    /// The current state of the Bluetooth radio.
    ///
    /// A synchronous snapshot — readable without `await` from any isolation domain — kept
    /// current by `handle(_:)` on every `CentralEvent/didUpdateState(_:)`.
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

    /// Whether a scan is currently active.
    ///
    /// A synchronous snapshot — readable without `await` from any isolation domain — kept
    /// current by ``scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)`` and
    /// its internal cleanup path.
    public nonisolated var isScanning: Bool {
        isScanningBox.withLock { $0 }
    }

    /// Returns a multicast stream of every ``CentralState`` transition.
    ///
    /// Replays the most recently observed state to a subscriber that starts consuming
    /// after that state was reached, so a late subscriber always learns the current state
    /// even if it missed the event that produced it.
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
    /// BLESwift supports N concurrent peripheral connections: connecting to a peripheral
    /// other than `id` while `id` connects (or while anything else is connected) never
    /// conflicts. Fails immediately with ``BLESwiftError/duplicateConnect(_:)`` only if `id`
    /// itself already has a tracked entry — connecting, connected, or disconnecting.
    ///
    /// A new `connect` call to `id` cancels any in-flight auto-reconnect loop for `id` from
    /// a previous `connect`, and resets the ``ReconnectPolicy`` in effect for `id` to
    /// whatever `reconnect` specifies here — every peripheral's reconnect loop, and the
    /// policy governing it, is independent of every other peripheral's.
    ///
    /// - Parameters:
    ///   - id: The peripheral to connect to — typically obtained from a prior scan, or a
    ///     previously-seen peripheral looked up by identifier.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/connectionTimedOut``.
    ///     Defaults to 15 seconds; `nil` waits indefinitely. On timeout, `Central` cancels
    ///     the pending CoreBluetooth connection attempt and awaits its confirmation before
    ///     throwing — the underlying attempt is genuinely torn down, not just abandoned
    ///     client-side.
    ///   - reconnect: What to do if this connection is later lost unexpectedly (or this
    ///     very attempt fails, times out, or is cancelled some way other than an explicit
    ///     ``disconnect(_:)``/``disconnect(_:immediate:)``/``cancelAllOperations(error:)``
    ///     call). Defaults to ``ReconnectPolicy/never``.
    ///   - warningOptions: Per-connection override for whether iOS shows system alerts on
    ///     suspended-app connection events. Defaults to ``Configuration``'s
    ///     `warningOptions`.
    /// - Returns: A ``Peripheral`` handle once connected.
    /// - Throws: ``BLESwiftError/duplicateConnect(_:)``,
    ///   ``BLESwiftError/unexpectedPeripheral(_:)`` if `id` is not known to CoreBluetooth,
    ///   ``BLESwiftError/connectionTimedOut``, ``BLESwiftError/operationCancelled`` if the calling
    ///   `Task` is cancelled, or whatever error CoreBluetooth reports for the failed
    ///   attempt.
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

        // Claim the connection slot SYNCHRONOUSLY, before any suspension point — this is
        // what closes the concurrent-connect TOCTOU deadlock: a second racing `connect(id)`
        // now sees the reservation and throws `.duplicateConnect` instead of passing its
        // guard during this call's suspension and overwriting the pending continuation (see
        // `reserveConnectingSlot` and `awaitConnect`). Throws `.duplicateConnect(id)` if `id`
        // is already tracked — including by an in-flight reconnect/restoration attempt that
        // has already reserved its own slot — or `.unexpectedPeripheral(id)` if CoreBluetooth
        // no longer knows `id`.
        try reserveConnectingSlot(
            identifier: id,
            policy: reconnect,
            timeout: timeout,
            warningOptions: resolvedWarningOptions
        )

        // Cancel an in-flight reconnect loop for THIS peripheral only — every other
        // peripheral's independent reconnect loop is untouched. Safe to do after reserving:
        // had a reconnect *attempt* been mid-flight it would already own the slot, so the
        // reservation above would have thrown `.duplicateConnect` before reaching here; any
        // loop still present is therefore in its backoff sleep, holding no slot.
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
    /// With no in-flight GATT operations to wait for yet (added in a later phase), this
    /// currently behaves identically to `disconnect(id, immediate: true)` — the distinction
    /// will matter once GATT operations exist to drain first.
    ///
    /// - Throws: ``BLESwiftError/notConnected`` if `id` has no connection or connection
    ///   attempt in progress; ``BLESwiftError/multipleDisconnectNotSupported`` if `id` is
    ///   already disconnecting.
    public func disconnect(_ id: PeripheralIdentifier) async throws {
        try await disconnect(id, immediate: false)
    }

    /// Disconnects a connected peripheral, or cancels a connection attempt in progress, for
    /// `id`.
    ///
    /// Never triggers a ``ReconnectPolicy`` retry for `id`, regardless of the policy the
    /// connection (or connection attempt) was established with — an explicit `disconnect`
    /// is always treated as an intentional, expected termination. Other peripherals'
    /// connections and reconnect loops are entirely unaffected.
    ///
    /// - Parameters:
    ///   - id: The peripheral to disconnect. Every other peripheral's connection and reconnect
    ///     loop is entirely unaffected.
    ///   - immediate: If `true`, fails pending operations with
    ///     ``BLESwiftError/explicitDisconnect`` rather than waiting for them to finish. With no
    ///     in-flight GATT operations to wait for yet (added in a later phase), `immediate`
    ///     currently has no observable effect — both values behave the same.
    /// - Throws: ``BLESwiftError/notConnected`` if `id` has no connection, connection attempt,
    ///   or in-flight auto-reconnect loop; ``BLESwiftError/multipleDisconnectNotSupported`` if
    ///   `id` is already disconnecting.
    public func disconnect(_ id: PeripheralIdentifier, immediate: Bool) async throws {
        switch connections[id] {
        case .none:
            // No tracked entry for `id` doesn't necessarily mean there's nothing to stop:
            // an auto-reconnect loop for `id` runs entirely between connections — during
            // its `Task.sleep` backoff, `id` has no `connections` entry — so a
            // `disconnect(id)` arriving mid-backoff must still be honored as the "stop
            // trying to reconnect" verb, not rejected with `.notConnected`. This does not
            // throw: unlike every other case here, the caller's intent (stop reconnecting
            // to `id`) is fully satisfied.
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
            // Reserved-but-unattached slot (see `reserveConnectingSlot`): no CoreBluetooth
            // attempt has been issued yet, so there is nothing to cancel and no disconnect
            // callback would ever arrive to complete a `.disconnecting` transition (which
            // would hang this `disconnect` call). Instead record `.explicitDisconnect` so
            // `awaitConnect`'s attach fails the pending connect with it, and return — the
            // caller's intent (don't connect to `id`) is satisfied, with nothing to await.
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
    /// auto-reconnect loop, then disconnects every tracked entry — a connecting attempt is
    /// two-phase-cancelled with ``BLESwiftError/explicitDisconnect``; a connected session
    /// gets the same full internal cleanup ordering every other disconnect path uses (fail
    /// pending GATT ops, finish notification streams, yield `.disconnected`).
    ///
    /// Never throws: individual outcomes are observable on ``connectionEvents()``.
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
    /// peripheral, without disconnecting any already-established connection — every
    /// connection "stays connected". This and ``disconnect(_:)``/``disconnect(_:immediate:)``/
    /// ``disconnectAll()`` are deliberately separate, clearly-named methods rather than one
    /// method parameterized by whether to disconnect.
    ///
    /// A global operation across every peripheral (not per-peripheral — task cancellation
    /// already covers per-operation cancel). A no-op if nothing is tracked and no reconnect
    /// loop is in flight.
    ///
    /// Like an explicit `disconnect`, cancelling a pending connection attempt this way
    /// never triggers a ``ReconnectPolicy`` retry. Does not touch an active scan.
    ///
    /// - Parameter error: The error pending operations fail with. Defaults to
    ///   ``BLESwiftError/cancelled``.
    public func cancelAllOperations(error: Error? = nil) {
        let resolvedError = error ?? BLESwiftError.cancelled

        // Cancel every in-flight auto-reconnect loop across every peripheral — a
        // reconnect-in-waiting is a pending connection attempt too, and
        // `cancelAllOperations` is documented to cancel those. Bumping the shared
        // generation counter stops a belated loop iteration from clearing a newer loop's
        // entry — see ``clearReconnectLoopIfCurrent(id:generation:)``.
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
                // Reserved-but-unattached slot (see `reserveConnectingSlot`): no
                // CoreBluetooth attempt has been issued yet, so it can't be two-phase
                // cancelled (no callback would ever arrive to complete a `.disconnecting`
                // transition). Record the error so `awaitConnect`'s attach fails the pending
                // connect with it — the same handling as `failPendingConnect`'s reserved slot.
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
    /// in ``withTimeout(_:throwing:operation:)`` — see that function's doc comment for why
    /// racing it this way still waits for the real two-phase-cancel confirmation before
    /// returning, rather than abandoning the underlying attempt the instant the timer
    /// fires.
    ///
    /// Takes only `identifier`, not the resolved `any PeripheralRemote` — that existential
    /// is not `Sendable` (`PeripheralRemote` conformances like `CBPeripheral` aren't), so it
    /// cannot be captured into `withTimeout`'s `@Sendable` closure. The peripheral was
    /// already resolved and stored in the reserved ``connections`` entry by
    /// ``reserveConnectingSlot(identifier:policy:timeout:warningOptions:)`` (which every
    /// caller of this method invokes first, synchronously); ``awaitConnect(id:policy:timeout:warningOptions:)``
    /// reads it back from that entry once actually running, already back on the actor.
    ///
    /// - Important: The caller MUST have reserved `identifier`'s slot via
    ///   ``reserveConnectingSlot(identifier:policy:timeout:warningOptions:)`` in the same
    ///   actor turn, before reaching this suspension — that reservation is what makes the
    ///   whole flow race-free (see that method).
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

    /// Synchronously claims `identifier`'s ``connections`` slot for a brand-new connection
    /// attempt, *before* any suspension point — the fix for the concurrent-connect TOCTOU
    /// deadlock. Resolves the target peripheral, wires its event delivery, and writes a
    /// **continuation-less** `.connecting` reservation. From the moment this returns,
    /// `connections[identifier]` is occupied, so any racing initiator's
    /// `connections[identifier] == nil` guard fails and it throws `.duplicateConnect` rather
    /// than overwriting a live attempt (and orphaning its continuation).
    ///
    /// Every path that starts a connection through
    /// ``establishConnection(identifier:policy:timeout:warningOptions:)`` — user
    /// ``connect(_:timeout:reconnect:warningOptions:)``, the auto-reconnect loop
    /// (``runReconnectLoop(identifier:policy:timeout:warningOptions:generation:)``), and the
    /// restoration manual re-connect (``runRestorationConnect(identifier:timeout:)``) — MUST
    /// call this first, synchronously within the same actor turn as its own
    /// `connections[identifier] == nil` decision, so none of them can race another into the
    /// same slot. (The adoption paths — ``adoptRestoredConnection(_:)`` and `init(adopting:…)`
    /// — do not go through here: they write a `.connected` entry directly and synchronously,
    /// with no suspension between their occupied-slot guard and that write, so they are
    /// already atomic and need no separate reservation.)
    ///
    /// The paired ``awaitConnect(id:policy:timeout:warningOptions:)`` later *attaches* its
    /// continuation to this reservation and only then issues the CoreBluetooth `connect` — so
    /// no CoreBluetooth callback can arrive for `identifier` while the slot is still
    /// reserved-but-unattached (`continuation == nil`). That invariant is what lets the
    /// cancel paths (``failPendingConnect(for:error:)``, ``cancelAllOperations(error:)``,
    /// ``disconnect(_:immediate:)``) treat a reserved slot specially: there is no in-flight
    /// CoreBluetooth attempt to two-phase-cancel, so they record the failure into `stopping`
    /// and `awaitConnect`'s attach resolves it directly.
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

        // Wire the peripheral's event delivery BEFORE the attempt goes live — the one shared
        // mechanism for every session-creating path (see `awaitConnect`/`adoptRestoredConnection`).
        // `awaitConnect` issues the actual `manager.connect` only once it has attached its
        // continuation, so nothing can be delivered here before that.
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
    /// already reserved for `id` (reading back the peripheral that reservation resolved),
    /// starts the CoreBluetooth connection attempt, and suspends until ``handle(_:)``
    /// resolves it from the `didConnect`/`didFailToConnect`/`didDisconnect` path — never
    /// directly from here. Does **not** create the ``connections`` entry itself; the
    /// reservation did, synchronously, before this suspension (that is what closes the
    /// concurrent-connect TOCTOU window). If a cancel/timeout raced in during the reservation
    /// window it is resolved here directly, since no CoreBluetooth attempt was issued yet.
    ///
    /// Wrapped in `withTaskCancellationHandler` so that cancelling the surrounding `Task`
    /// (whether genuine caller cancellation, or ``establishConnection(identifier:policy:timeout:warningOptions:)``'s
    /// timeout race cancelling the loser) triggers the same two-phase-cancel dance a real
    /// cancellation would — see ``failPendingConnect(for:error:)``. The cancellation handler
    /// itself is **not** actor-isolated (cancellation can be delivered from any thread), so
    /// it hops onto ``queue`` and uses `assumeIsolated` — the same sanctioned pattern
    /// `CentralDelegateProxy` uses, and *not* a `Task {}` spawn (grep-forbidden outside the
    /// ledgered `Task` sites — see ``reconnectLoops``/``ActiveScan``).
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
                    // The expected reservation is gone or already attached. Under the
                    // reserve-then-attach discipline only this method ever attaches to or
                    // clears a reserved entry, and the reservation is written synchronously
                    // just before this suspension, so this is unreachable in practice —
                    // resolve defensively rather than orphan the continuation.
                    continuation.resume(throwing: BLESwiftError.operationCancelled)
                    return
                }

                // A cancel/timeout/disconnect that raced in during the reservation window —
                // before any CoreBluetooth `connect` was issued — recorded its error in
                // `stopping`. There is no in-flight CoreBluetooth attempt to tear down, so
                // resolve here directly (the same immediate-resolution rationale as
                // `failPendingConnect`'s no-radio branch, NOT a two-phase deferral).
                if let stopping = connecting.stopping {
                    connections.removeValue(forKey: id)
                    connecting.peripheral.eventHandler = nil
                    continuation.resume(throwing: stopping)
                    return
                }

                // Normal attach: wire the continuation into the reserved slot, THEN issue the
                // CoreBluetooth connect — never before, so no `didConnect`/`didFailToConnect`
                // can land while the slot is still reserved-but-unattached. The peripheral was
                // resolved and its event delivery wired at reservation time.
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

    /// Two-phase-cancels (or immediately fails) whatever connect attempt is pending for
    /// `id`: if the radio is powered on, marks the pending attempt as `stopping` and asks
    /// CoreBluetooth to cancel it, deferring resolution of its continuation to the
    /// `didFailToConnect`/`didDisconnect` path (``handleTermination(identifier:error:)``)
    /// so callback ordering matches CoreBluetooth's own event delivery; otherwise (no radio
    /// to cancel against) there is nothing to wait for, so resolution happens here,
    /// immediately.
    ///
    /// Idempotent: a second call while already `stopping` is a no-op, so whichever trigger
    /// asked first (e.g. a timeout that fires moments before an unrelated task
    /// cancellation) wins and its error is what the caller ultimately sees.
    ///
    /// A no-op if there is no pending connect attempt for `id` at all (`connections[id]` is
    /// not `.connecting`).
    private func failPendingConnect(for id: PeripheralIdentifier, error: Error) {
        guard case .connecting(var connecting) = connections[id] else { return }
        guard connecting.stopping == nil else { return }

        // Reserved-but-unattached slot (see `reserveConnectingSlot`): no CoreBluetooth
        // attempt has been issued yet, so there is nothing to cancel and no
        // `didFailToConnect`/`didDisconnect` will ever arrive. Just record the error;
        // `awaitConnect`'s attach resolves the pending continuation with it. Uniform across
        // radio states — there is genuinely nothing to tear down either way.
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
    /// the connection (awaiting its confirmation via ``handleTermination(identifier:error:)``),
    /// or — if the radio isn't powered on, so no such confirmation will ever arrive —
    /// resolves the cleanup synchronously instead.
    ///
    /// Always cancels `identifier`'s in-flight auto-reconnect loop first, if any: an
    /// explicit disconnect of a peripheral is never followed by a reconnect attempt to it.
    /// Every other peripheral's connection/reconnect loop is untouched.
    private func beginDisconnecting(
        identifier: PeripheralIdentifier,
        peripheral: any PeripheralRemote,
        disconnectContinuation: CheckedContinuation<Void, Error>?,
        connectContinuation: CheckedContinuation<Peripheral, Error>?,
        connectFailureReason: Error
    ) async throws {
        reconnectLoops[identifier]?.task.cancel()
        reconnectLoops.removeValue(forKey: identifier)

        // Fail any in-flight GATT operations on the outgoing session's registries *before*
        // `connections[identifier]` transitions away from `.connected` below — those
        // registries live inside `Session` (GATT state is per-connection, not actor-level),
        // so once the entry becomes `.disconnecting` the old `Session` value (and
        // everything it holds) is gone; failing here first is what keeps their
        // continuations from being silently dropped. A no-op if `identifier` isn't
        // currently `.connected` (e.g. this call came from cancelling a `.connecting`
        // attempt, which never has a `Session`/GATT state to begin with).
        failPendingGATTContinuations(for: identifier, error: .explicitDisconnect)

        // Same reasoning for notification streams (cleanup step 2): their registry also
        // lives inside `Session`, and `Disconnecting` (below) carries no `Session` — finish
        // them now, while the entry is still `.connected`, or their subscribers' streams
        // would silently hang instead of ending with `.explicitDisconnect`. The later
        // `handleTermination` `.disconnecting`-branch call is then a defensive no-op.
        finishNotificationStreams(for: identifier, error: BLESwiftError.explicitDisconnect)

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

    /// The single cleanup path for every way a tracked connection (or connection attempt)
    /// for `identifier` ends — a real `didFailToConnect`/`didDisconnect` CoreBluetooth
    /// callback (``handle(_:)`` routes both here, funneling `didFailToConnect` into the same
    /// disconnect handling), or a synchronous resolution when there's no radio to wait on
    /// (``failPendingConnect(for:error:)``/``beginDisconnecting(identifier:peripheral:disconnectContinuation:connectContinuation:connectFailureReason:)``'s
    /// not-powered-on branches).
    ///
    /// The cleanup ordering: (1) fail in-flight GATT continuations, (2) finish notification
    /// streams, (3) yield `.disconnected` on ``connectionEvents()``, (4) resume the
    /// disconnect/connect continuation(s), (5) start a reconnect loop for `identifier` if
    /// the ``ReconnectPolicy`` in effect for it says so. Removes `identifier`'s
    /// ``connections`` entry once cleanup completes — no map lookup can ever cross into a
    /// *different* peripheral's entry, so unlike the old single-`Phase` design there is no
    /// "wrong identifier currently tracked" case to guard against.
    ///
    /// A no-op (beyond a debug log) if `identifier` has no ``connections`` entry at all
    /// (stale or unexpected event).
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

            // Final teardown of this attempt's peripheral reference: detach its event
            // delivery (delegate) — the counterpart of `awaitConnect`'s attach. A
            // follow-up reconnect attempt re-attaches on its own initiation.
            connecting.peripheral.eventHandler = nil

            failPendingGATTContinuations(for: identifier, error: .notConnected)
            finishNotificationStreams(for: identifier, error: resolvedError)

            let willReconnect = !policy.isNever
            connectionBroadcaster.yield(.disconnected(identifier, error: resolvedError, willReconnect: willReconnect))

            continuation?.resume(throwing: resolvedError)

            // If this failed attempt was itself one iteration of an *already-running*
            // reconnect loop for `identifier` (`reconnectLoops[identifier]` still non-`nil`
            // — that very loop is what's currently suspended awaiting this
            // `establishConnection` call), don't spawn a second, concurrent loop for the
            // same peripheral: the running loop's own `catch` block will continue retrying
            // on its own. Only a fresh top-level `connect()` failure (no reconnect loop
            // active for `identifier` yet) starts one here.
            if willReconnect, reconnectLoops[identifier] == nil {
                scheduleReconnect(identifier: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions)
            }

        case .connected(let session):
            let policy = session.policy
            let timeout = session.timeout
            let warningOptions = session.warningOptions

            // Fail pending GATT ops and finish notification streams *before* removing
            // `identifier`'s `.connected` entry below — see the matching comment in
            // `beginDisconnecting`: their registries live inside `Session` itself, so once
            // the entry is gone there is no session left to read them from. The ordering
            // between the two is cleanup steps (1) then (2).
            let resolvedError = error ?? BLESwiftError.unexpectedDisconnect
            failPendingGATTContinuations(for: identifier, error: .unexpectedDisconnect)
            finishNotificationStreams(for: identifier, error: resolvedError)
            connections.removeValue(forKey: identifier)

            // Final teardown of the session's peripheral reference: detach its event
            // delivery (delegate). A reconnect attempt re-attaches on initiation.
            session.peripheral.eventHandler = nil

            let willReconnect = !policy.isNever
            connectionBroadcaster.yield(.disconnected(identifier, error: error, willReconnect: willReconnect))

            // See the matching comment in the `.connecting` branch above: don't spawn a
            // second reconnect loop for `identifier` on top of one that's already running.
            if willReconnect, reconnectLoops[identifier] == nil {
                scheduleReconnect(identifier: identifier, policy: policy, timeout: timeout, warningOptions: warningOptions)
            }

        case .disconnecting(var disconnecting):
            connections.removeValue(forKey: identifier)

            // Final teardown of the outgoing peripheral reference: detach its event
            // delivery (delegate) — an explicit disconnect never reconnects, so nothing
            // re-attaches until a future `connect` to `identifier` does.
            disconnecting.peripheral.eventHandler = nil

            // Already a no-op by this point for the common path: `beginDisconnecting`
            // fails the outgoing session's GATT ops itself, before transitioning here (see
            // its doc comment) — `identifier`'s entry is `.disconnecting` now, not
            // `.connected`, so there's no session left for this call to find. Kept as a
            // defensive no-op for the `cancelAllOperations()`-cancels-a-pending-connect
            // path, which never had a `Session`/GATT state to begin with.
            failPendingGATTContinuations(for: identifier, error: .explicitDisconnect)
            finishNotificationStreams(for: identifier, error: BLESwiftError.explicitDisconnect)

            connectionBroadcaster.yield(.disconnected(identifier, error: error, willReconnect: false))

            let disconnectContinuation = disconnecting.continuation
            disconnecting.continuation = nil
            disconnectContinuation?.resume(returning: ())

            let connectContinuation = disconnecting.connectContinuation
            disconnecting.connectContinuation = nil
            connectContinuation?.resume(throwing: disconnecting.connectFailureReason)
        }
    }

    /// Fails every pending connect attempt or established connection this `Central` is
    /// tracking, across every peripheral, with ``BLESwiftError/bluetoothUnavailable``
    /// proactively whenever the radio leaves `.poweredOn`, rather than waiting on a
    /// CoreBluetooth disconnect callback that may not reliably arrive once the radio itself
    /// is unavailable. Reconnect loops are deliberately NOT cancelled here (parity with
    /// today, generalized per peripheral): their attempts fail on their own and the policy
    /// in effect decides whether to keep retrying.
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

    /// Fails every in-flight GATT operation tracked by `identifier`'s connected session (if
    /// any) with `error`: every pending read/write/RSSI-read/discovery/notify-state-change
    /// continuation is resumed throwing `error`, and every per-characteristic FIFO tail
    /// `Task` (plus the RSSI tail) is cancelled. Cleanup step 1 of
    /// ``handleTermination(identifier:error:)`` — called there, by ``beginDisconnecting(identifier:peripheral:disconnectContinuation:connectContinuation:connectFailureReason:)``
    /// (both *before* the entry stops being `.connected`, since these registries live
    /// inside `Session` itself — GATT state is per-connection, not actor-level), and
    /// directly by ``cancelAllOperations(error:)`` (which does **not** tear down the
    /// connection itself — only pending GATT operations — so this leaves `identifier`'s
    /// entry `.connected`, just with freshly emptied registries).
    ///
    /// Distinct from ``failAllPendingOperations(error:)``, which only concerns the active
    /// *scan* and must not be triggered by connection cleanup — a disconnect has no bearing
    /// on an unrelated, independently-running scan, and one peripheral's GATT cleanup has
    /// no bearing on any other peripheral's.
    ///
    /// A no-op if `identifier`'s entry is not currently `.connected` (nothing to fail).
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

        connections[identifier] = .connected(session)
    }

    /// Calls ``failPendingGATTContinuations(for:error:)`` for every currently-connected
    /// peripheral (a snapshot of ``connections``' keys, never iterated live — see the
    /// anti-pattern guard on mutating ``connections`` while iterating it). Used by
    /// ``stopAndExtractState()`` and ``cancelAllOperations(error:)`` — both need every
    /// connected session's pending GATT operations failed, not just one peripheral's.
    func failAllSessionsPendingGATTContinuations(error: BLESwiftError) {
        for identifier in Array(connections.keys) {
            failPendingGATTContinuations(for: identifier, error: error)
        }
    }

    /// Finishes every active notification stream on `identifier`'s session with `error` and
    /// clears its registry — cleanup step 2 of ``handleTermination(identifier:error:)``,
    /// also invoked by ``beginDisconnecting(identifier:peripheral:disconnectContinuation:connectContinuation:connectFailureReason:)``.
    ///
    /// Must run while `identifier`'s entry is still `.connected` — the registry lives
    /// inside `Session` (notification state is per-connection, like the GATT registries),
    /// so once the entry moves on the subscriptions (and their subscribers' streams) would
    /// be silently dropped instead of finished. A no-op otherwise, which also makes the
    /// defensive calls on the `.connecting`/`.disconnecting` cleanup paths (no session ever
    /// existed there, or it was already cleaned) harmless.
    ///
    /// Pump tasks (`Session.notificationPumps`) are deliberately **not** cancelled here:
    /// each pump ends on its own when its raw stream finishes below, and forwards `error`
    /// to its subscriber's typed stream — cancelling it instead would race that delivery
    /// and could end the typed stream cleanly, hiding the disconnect error.
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

    /// Calls ``finishNotificationStreams(for:error:)`` for every currently-connected
    /// peripheral (a key snapshot, same anti-pattern guard as
    /// ``failAllSessionsPendingGATTContinuations(error:)``). Used by
    /// ``stopAndExtractState()``.
    func finishAllSessionsNotificationStreams(error: Error) {
        for identifier in Array(connections.keys) {
            finishNotificationStreams(for: identifier, error: error)
        }
    }

    // MARK: - Auto-reconnect

    /// Starts (or restarts) the auto-reconnect loop for `identifier`, per `policy`. See
    /// ``reconnectLoops``.
    ///
    /// Tags the spawned task with the current ``reconnectGeneration`` (incremented here,
    /// shared across every peripheral) so
    /// ``runReconnectLoop(identifier:policy:timeout:warningOptions:generation:)`` can safely
    /// clear `identifier`'s ``reconnectLoops`` entry on exit only if it's still *this*
    /// generation's loop — otherwise a superseded loop's belated cleanup (it was cancelled,
    /// but hasn't actually finished running yet — cancellation is cooperative) could race
    /// with, and incorrectly clear, a newer loop already scheduled for `identifier` (e.g.
    /// `disconnect(identifier)` cancelling this loop followed by an immediate, successful
    /// `connect(identifier)` that starts a fresh one of its own).
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

    /// Removes `identifier`'s ``reconnectLoops`` entry only if `generation` still matches
    /// its stored generation — see
    /// ``scheduleReconnect(identifier:policy:timeout:warningOptions:)`` for why this guard
    /// is needed instead of an unconditional `reconnectLoops.removeValue(forKey: identifier)`.
    private func clearReconnectLoopIfCurrent(id identifier: PeripheralIdentifier, generation: UInt64) {
        if reconnectLoops[identifier]?.generation == generation {
            reconnectLoops.removeValue(forKey: identifier)
        }
    }

    /// Repeatedly attempts to reconnect to `identifier` per `policy`, emitting
    /// ``ConnectionEvent/reconnecting(_:attempt:)`` before each attempt, until either an
    /// attempt succeeds, `policy` says to stop (``ReconnectPolicy/nextDelay(attempt:error:)``
    /// returns `nil`), or this task is cancelled (an explicit disconnect of `identifier`, a
    /// new `connect` to it, `cancelAllOperations`/`disconnectAll()`, or `deinit` — see
    /// ``reconnectLoops``). Independent of every other peripheral's reconnect loop.
    ///
    /// `establishConnection(identifier:policy:timeout:warningOptions:)` (via
    /// `awaitConnect(id:policy:timeout:warningOptions:)`) re-resolves the target peripheral
    /// fresh on every attempt, so this loop never itself holds a `PeripheralRemote`
    /// reference across a suspension point.
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
                // Reserve the slot synchronously (same discipline as user `connect(_:)`) so a
                // user `connect(id)` racing this reconnect attempt resolves cleanly: whichever
                // reserves first wins, and the other throws/observes `.duplicateConnect`
                // instead of overwriting a live attempt. The `connections[identifier] == nil`
                // guard above and this reservation run in the same actor turn (nothing
                // suspends between them), so the reservation cannot spuriously fail.
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
    /// `CentralEvent` — forwarded here through the wired `eventHandler`: by
    /// ``CentralDelegateProxy`` for a real `CBCentralManager`, or by a test's wired
    /// `FakeCentral.eventHandler` for a test-backed `Central`.
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

            // A `didConnect` always means success, even for an attempt already marked
            // `stopping` (cancelled/timed out) — CoreBluetooth won the race, and BLESwift is
            // now genuinely connected, so declaring failure here would contradict physical
            // reality.
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
            // Wire each restored peripheral's event delivery now, *before* `.poweredOn`
            // routing (`routeRestoredPeripherals(_:)`) actually adopts/reconnects it —
            // closing (for this path onward) the gap where a notification from a listen
            // that survived the relaunch would otherwise have nowhere to go. This is the
            // replacement for the pre-split `CentralDelegateProxy`'s eager
            // `attachEventTarget(self)` during the raw `willRestoreState` callback: this
            // handler only runs once `Central` itself is guaranteed wired (see
            // `CentralDelegateProxy.centralManagerDidUpdateState(_:)`'s buffered-drain
            // timing), so it cannot cover the narrower window between CoreBluetooth's own
            // `willRestoreState` delivery and this drain — a disclosed, narrow limitation
            // of the delegate-proxy split (see that method's doc comment) — but it does
            // cover the willRestoreState→poweredOn-routing window this fan-out targets,
            // uniformly for both the real CoreBluetooth path and fakes.
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

            // Stage the restored state until the radio's first `.poweredOn` routes it, and
            // emit `.willRestore` immediately (buffered/replayed by `restorationBroadcaster`,
            // so a consumer subscribing later still sees it first).
            pendingRestoration = restored
            restorationBroadcaster.yield(.willRestore(restored))
            log("Will restore state: \(restored.peripherals.count) peripheral(s)", level: .info, category: "restore")
        }
    }

    /// Handles a `PeripheralEvent` — forwarded here through the wired `eventHandler`: by
    /// ``PeripheralDelegateProxy`` for a real `CBPeripheral`, or by a test's wired
    /// `FakePeripheral.eventHandler` for a test-backed `Central`.
    ///
    /// Routes GATT completions to their pending continuations (take-then-resume, per
    /// characteristic/service where the event carries one) and `didModifyServices` to
    /// ``serviceChangesRegistry``, keyed by the emitting `peripheral`. A later phase (notifications) extends
    /// ``hasActiveNotificationSubscriber(_:session:)`` and the restoration
    /// "unhandled listen" surface referenced in ``handleDidUpdateValue(characteristic:value:error:from:)``.
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

        case .didReadRSSI(let rssi, let error):
            resumePendingRSSIRead(rssi: rssi, for: peripheral, error: error)

        case .didModifyServices(let invalidatedServices):
            // No actor-level discovery cache exists to invalidate: the shim's own
            // `isDiscovered(_:)` — backed by CoreBluetooth's own service graph,
            // which CoreBluetooth itself prunes on `didModifyServices` — already reflects
            // the invalidation structurally. This is purely the observer fan-out — routed
            // to only `peripheral`'s own broadcaster, never any other peripheral's.
            log("Services modified/invalidated: \(invalidatedServices)", level: .info, category: "gatt")
            serviceChangesRegistry.broadcaster(for: peripheral).yield(invalidatedServices)

        case .isReadyToSendWriteWithoutResponse:
            resumeWriteWithoutResponseWaiters(for: peripheral)
        }
    }

    // MARK: - GATT event routing

    /// Take-then-resumes every waiter registered in `session.pendingDiscoverServices`.
    ///
    /// Not matched to a specific service: CoreBluetooth's `didDiscoverServices(error:)`
    /// carries no service identifier, so a single completion can't be attributed to the
    /// specific `discoverServices(_:)` call(s) that triggered it — every waiter is instead
    /// resumed on *any* such event rather than trying to disambiguate. Every waiter is
    /// resumed on every completion (not just one), because two different characteristics' independent
    /// per-characteristic FIFO chains can each trigger their own concurrent
    /// `discoverServices(_:)` call for a still-undiscovered service — a single-slot
    /// continuation would silently drop one of them.
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
    /// specific waiter's own `withTaskCancellationHandler` firing (task cancellation or a
    /// `withTimeout` timeout), rather than a real `didDiscoverServices` completion. Removing
    /// only this one token leaves any other concurrently pending waiter untouched.
    private func cancelDiscoverServicesWaiter(identifier: PeripheralIdentifier, token: UInt64) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingDiscoverServices.removeValue(forKey: token) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes every waiter registered for `service` in
    /// `session.pendingDiscoverCharacteristics`. `didDiscoverCharacteristics(service:error:)`
    /// does carry the service, so waiters are keyed (unlike the services case above) — but
    /// still resumed as a group per key, for the same cross-characteristic-concurrency
    /// reason.
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
    /// `characteristic`, if any. Unused until notifications (a later phase) call
    /// `setNotifyValue(_:for:)` — this routing already exists so that phase only needs to
    /// populate the registry.
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

    /// Take-then-resumes every waiter registered in
    /// `session.pendingWriteWithoutResponseReady`. Not keyed by characteristic:
    /// `canSendWriteWithoutResponse`/`peripheralIsReady(toSendWriteWithoutResponse:)` are
    /// peripheral-wide in CoreBluetooth's own API, not per-characteristic.
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

    /// Routes a `didUpdateValueFor` delivery in this order: an active notification
    /// subscription consumes the value FIRST (yielded into its
    /// raw-`Data` broadcaster — decode happens per subscriber, in each one's own decode
    /// layer); else a pending read continuation for `characteristic`; else, when
    /// restoration is enabled, the restoration "unhandled listen" surface
    /// (``RestorationEvent/unhandledNotification(_:_:_:)`` on ``restorationEvents()`` —
    /// the peripheral is still notifying from a subscription that belonged to the
    /// previous app life); else it's just logged.
    ///
    /// A `didUpdateValue` **error** on a notifying characteristic finishes that
    /// characteristic's subscription with the error (every subscriber's stream ends
    /// throwing it) — streams always finish with the error, per the redesign map's
    /// deliberate-drop note.
    private func handleDidUpdateValue(characteristic: CharacteristicIdentifier, value: Data?, error: NSError?, from peripheralIdentifier: PeripheralIdentifier) {
        guard case .connected(var session) = connections[peripheralIdentifier] else {
            // willRestoreState→poweredOn window (verifier finding): a restored-but-not-
            // yet-routed peripheral can already be notifying (its delegate is attached by
            // the proxy during willRestoreState precisely so these arrive). Dropping the
            // value as "untracked" would lose it; surface it on the restoration stream
            // instead — restoration is enabled by definition whenever state was staged.
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
            // The restoration "unhandled listen" surface: only meaningful with restoration
            // enabled, where a restored peripheral can still be notifying from a
            // subscription set up in a previous app life.
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

    // MARK: - GATT operations

    /// Reads `characteristic`'s current value, routed here by
    /// `Peripheral.read(from:timeout:)`.
    ///
    /// Wraps the whole discovery-then-read sequence in `timeout` via ``withTimeout(_:throwing:operation:)``
    /// (error ``BLESwiftError/timedOut``, distinct from
    /// ``BLESwiftError/connectionTimedOut``, which is `connect`'s own timeout case) and serializes
    /// it against any other pending operation on the same characteristic via
    /// ``runOnFIFO(identifier:characteristic:operation:)``.
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

        // BLESwift throws rather than crashing on read-while-listening — CoreBluetooth's
        // `didUpdateValueFor` can't disambiguate a read completion from a notification on
        // the same characteristic, so the two are mutually exclusive.
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

    /// Writes `data` to `characteristic`, routed here by
    /// `Peripheral.write(_:to:type:timeout:)`. See ``performRead(peripheral:characteristic:timeout:)``
    /// for the timeout/FIFO wrapping, which this mirrors.
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

    /// The actual discovery-then-write sequence for ``performWrite(peripheral:characteristic:data:type:timeout:)``,
    /// run inside `characteristic`'s FIFO chain.
    ///
    /// `.withoutResponse` synthesizes completion immediately after the shim call —
    /// CoreBluetooth delivers no `didWriteValueFor` callback for a `.withoutResponse`
    /// write. BLESwift first awaits `canSendWriteWithoutResponse` back-pressure
    /// (``awaitWriteWithoutResponseReadiness(peripheral:identifier:)``) rather than writing
    /// regardless and letting CoreBluetooth silently drop the payload — a deliberate
    /// improvement.
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

    /// Awaits `peripheral.canSendWriteWithoutResponse` becoming `true`, if it isn't already
    /// — CoreBluetooth's back-pressure signal for `.withoutResponse` writes. A no-op
    /// (returns immediately) if it's already `true`.
    ///
    /// Registers a tokened waiter (not per-characteristic), mirroring
    /// `canSendWriteWithoutResponse`/`isReadyToSendWriteWithoutResponse` themselves being
    /// peripheral-wide rather than per-characteristic. Every waiter is resumed on the next
    /// `isReadyToSendWriteWithoutResponse` signal (see
    /// ``resumeWriteWithoutResponseWaiters(for:)``); a signal that arrives while several
    /// characteristics are separately blocked wakes all of them, matching the fact that the
    /// underlying capacity is genuinely peripheral-wide, not reserved per waiter.
    private func awaitWriteWithoutResponseReadiness(peripheral: any PeripheralRemote, identifier: PeripheralIdentifier) async throws {
        if peripheral.canSendWriteWithoutResponse { return }

        // `Mutex`-boxed (not a plain `var`) so it can be safely written from `register`
        // (running synchronously, actor-isolated) and read from `onCancelled` (a
        // `@Sendable` closure, per `withCancellableGATTContinuation`'s signature) — Swift 6
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
                // `assignedToken` is always set by the time this can fire: `register`
                // above runs synchronously as part of setting up the continuation, and
                // cancellation can only be observed once that continuation has actually
                // started suspending.
                self.queue.async {
                    self.assumeIsolated { central in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        central.cancelWriteWithoutResponseWaiter(identifier: identifier, token: token)
                    }
                }
            }
        )
    }

    /// Reads the peripheral's current RSSI, routed here by `Peripheral.readRSSI(timeout:)`.
    ///
    /// RSSI has no owning characteristic, so it is serialized via its own single tail
    /// (``runRSSISerialized(identifier:operation:)``) rather than the per-characteristic
    /// FIFO map — a second concurrent `readRSSI()` call waits for the first to finish
    /// instead of stomping on the same single-slot ``Session/pendingRSSIRead`` continuation.
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
    /// routed here by `Peripheral.maximumWriteValueLength(for:)`.
    ///
    /// Never throws (matches that method's non-`throws` signature): if `identifier` isn't
    /// the currently connected peripheral, returns ``Central/defaultMaximumWriteValueLength``
    /// rather than failing — this is a best-effort sizing hint, not an operation with a
    /// meaningful failure mode.
    func maximumWriteValueLength(peripheral identifier: PeripheralIdentifier, for type: WriteType) -> Int {
        guard case .connected(let session) = connections[identifier] else {
            return Central.defaultMaximumWriteValueLength
        }
        return session.peripheral.maximumWriteValueLength(for: type)
    }

    /// The fallback value ``maximumWriteValueLength(peripheral:for:)``/
    /// `Peripheral.maximumWriteValueLength(for:)` report when there is no connected
    /// peripheral to ask — the classic BLE ATT_MTU-3 default (23-byte default ATT_MTU minus
    /// the 3-byte write-request header), matching `FakePeripheral`'s own default.
    static let defaultMaximumWriteValueLength = 20

    // MARK: - Lazy discovery

    /// Ensures `characteristic` (and its owning service) has been discovered on
    /// `peripheral`, short-circuiting via the shim's own `isDiscovered(_:)` — BLESwift keeps no
    /// separate discovery cache of its own (CoreBluetooth's own service/characteristic
    /// graph, mirrored by `isDiscovered(_:)`, IS the cache). Discovers
    /// the owning service, then the characteristic, before every read/write/listen.
    ///
    /// - Throws: ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)`` if
    ///   still not discovered once the corresponding discovery call completes, or whatever
    ///   error CoreBluetooth reported for that discovery call.
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

    // MARK: - Notifications

    /// Registers one `Peripheral.notifications(for:policy:)` subscriber and spawns its
    /// pump task — the bridge between the shared raw-`Data` multicast and that one
    /// subscriber's typed stream (raw-`Data` multicast + per-caller decode layers).
    /// Called synchronously via `queue.async` + `assumeIsolated` by
    /// `Peripheral.notifications(for:policy:)`, which enqueues this *before* returning its
    /// stream — so, by serial-queue FIFO ordering, this always runs before the stream's
    /// `onTermination` can enqueue ``handleNotificationStreamTermination(peripheral:characteristic:token:)``.
    ///
    /// The pump `Task` here is a ledgered `Task { }` site under the corrected policy:
    /// spawned from actor-isolated code (never the proxy), stored in
    /// `Session.notificationPumps` keyed by `token`, and cancelled by
    /// ``handleNotificationStreamTermination(peripheral:characteristic:token:)``.
    ///
    /// - Parameters:
    ///   - identifier: The peripheral the subscriber belongs to.
    ///   - characteristic: The characteristic to receive notifications from.
    ///   - token: The subscriber's unique token (allocated by the caller so its
    ///     `onTermination` handler can name it without waiting on this registration).
    ///   - deliver: Decodes and yields one raw value into the subscriber's typed stream.
    ///     Returns `nil` on success, or the decode error — which finishes only *that*
    ///     subscriber's stream (the sibling-isolating decode-failure policy).
    ///   - finish: Finishes the subscriber's typed stream, throwing the given error if
    ///     non-`nil`.
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

    /// The body of one subscriber's pump task (see
    /// ``startNotificationPump(peripheral:characteristic:token:deliver:finish:)``):
    /// subscribes to the raw multicast (enabling notifications if this is the first
    /// subscriber), forwards every raw value through `deliver`, and finishes the typed
    /// stream when the raw stream ends — with the raw stream's own terminal error, the
    /// subscriber's decode error, or cleanly.
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

        // Belt-and-braces release (idempotent by token): the typed stream's `onTermination`
        // → `handleNotificationStreamTermination` is the primary release path, but if this
        // pump was cancelled *between* `onTermination`'s (no-op, pre-registration) release
        // and `subscribeToNotifications` registering the token above, this is the release
        // that prevents a leaked refcount.
        releaseNotificationSubscriber(peripheral: identifier, characteristic: characteristic, token: token)
    }

    /// Reacts to a `Peripheral.notifications(for:policy:)` subscriber's typed stream
    /// terminating (consumer `break`/task-cancel, decode-failure finish, or any other
    /// finish): cancels and forgets its pump task, then releases its refcount — the
    /// release path (`onTermination` → `queue.async` + `assumeIsolated` → here).
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
    /// multicast and returns a fresh stream of it. The shared entry point for typed
    /// subscribers (via their pump) and the composite helpers/`flush` alike.
    ///
    /// **Refcount 0 → 1** (no subscription yet): the subscription is registered FIRST —
    /// so `didUpdateValue` routing multicasts from this very instant, closing the loss
    /// window — then the owning service/characteristic is lazily discovered,
    /// `setNotifyValue(true)` is issued, and its `didUpdateNotificationState` confirmation
    /// awaited (single-slot continuation in `Session.pendingNotifyStateChanges`, reused
    /// from the GATT registry, cancellable like every GATT continuation). If any of
    /// that fails, the whole subscription fails: every current subscriber's stream (and
    /// enablement waiter) finishes with the error — deterministic, and the next subscribe
    /// simply starts a fresh subscription.
    ///
    /// **Joiners** (subscription already exists): the token is added and a fresh stream of
    /// the same broadcaster returned; if the enable handshake is still in flight, the
    /// joiner awaits its confirmation first (`NotificationSubscription.enableWaiters`) —
    /// load-bearing for the composite helpers, whose listen-before-write guarantee requires
    /// the listen to be *installed*, not merely requested, before the write goes out.
    ///
    /// Deliberately NOT serialized through the per-characteristic FIFO: a subscription
    /// must be installable while a (held-up) read on the same characteristic is pending so
    /// that notification routing can take precedence over that pending read — the
    /// fallback-chain order `handleDidUpdateValue(characteristic:value:error:from:)` ports.
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
            // The confirmation's `isNotifying` payload is deliberately ignored (any
            // `didUpdateNotificationState` completes the handshake) — a stale
            // disable-confirmation from a just-released previous subscription must not fail
            // a fresh enable whose own confirmation is still in flight.
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

    /// Suspends a joiner until `characteristic`'s in-flight enable handshake confirms
    /// (resumed by ``confirmNotificationEnablement(identifier:characteristic:)``) or fails
    /// (resumed throwing by ``failNotificationSubscription(identifier:characteristic:error:)``
    /// / ``finishNotificationStreams(error:)``). Cancellation removes and resumes only this
    /// joiner's waiter, and undoes only this joiner's own registration — siblings are
    /// unaffected.
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

    /// Fails `characteristic`'s entire subscription: removes it from the registry, resumes
    /// every enablement waiter throwing `error`, and finishes the raw broadcaster with
    /// `error` — so every subscriber's stream ends with it. Triggered by an enable-handshake
    /// failure and by a `didUpdateValue` error on a notifying characteristic.
    ///
    /// No `setNotifyValue(false)` is issued: on the enable-failure path the enable was never
    /// confirmed; on the value-error path the characteristic's own delivery is already
    /// failing.
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
    /// per `token` (a token not currently registered is a no-op — safe against the
    /// primary and belt-and-braces release paths both firing).
    ///
    /// The **last** release removes the subscription, finishes its (by now
    /// subscriber-less) broadcaster, and issues `setNotifyValue(false)` — but only while
    /// still connected (guaranteed by the phase guard) AND the radio is `.poweredOn`
    /// (the ledger guard: CoreBluetooth logs "API MISUSE" otherwise). The disable's own
    /// confirmation is deliberately not awaited — there is no subscriber left to report a
    /// failure to.
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

    /// The number of live subscriber tokens on `characteristic`'s notification
    /// subscription for peripheral `id` — `0` if there is none (or `id` has no connected
    /// session). A test-visibility hook (`@testable`): subscriber registration is
    /// asynchronous by design (enqueued behind `Peripheral.notifications(for:policy:)`
    /// returning its stream), so multi-subscriber tests await this count before emitting
    /// values that every subscriber is expected to observe. Not part of the public API.
    func notificationSubscriberCount(for characteristic: CharacteristicIdentifier, on id: PeripheralIdentifier) -> Int {
        guard case .connected(let session) = connections[id] else { return 0 }
        return session.notificationSubscriptions[characteristic]?.subscriberTokens.count ?? 0
    }

    /// Take-then-resumes the single pending notify-state-change continuation for
    /// `characteristic`, if still pending — the reaction to cancellation (task
    /// cancellation or a `withTimeout` timeout) rather than a real
    /// `didUpdateNotificationState` completion. See ``cancelPendingRead(identifier:characteristic:)``.
    private func cancelPendingNotifyStateChange(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard let continuation = session.pendingNotifyStateChanges.removeValue(forKey: characteristic) else { return }
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Take-then-resumes a single enablement waiter by token — the cancellation
    /// counterpart to ``confirmNotificationEnablement(identifier:characteristic:)``,
    /// removing only this waiter and leaving the subscription (and its siblings) intact.
    private func cancelNotificationEnablementWaiter(identifier: PeripheralIdentifier, characteristic: CharacteristicIdentifier, token: UUID) {
        guard case .connected(var session) = connections[identifier] else { return }
        guard var subscription = session.notificationSubscriptions[characteristic],
              let continuation = subscription.enableWaiters.removeValue(forKey: token) else { return }
        session.notificationSubscriptions[characteristic] = subscription
        connections[identifier] = .connected(session)
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    // MARK: - Composite helpers

    /// Backs `Peripheral.writeAndAwaitNotification(write:to:awaitOn:timeout:)`: subscribes
    /// to `notifyCharacteristic` (raw) FIRST, then writes, then returns the first
    /// notification value — all inside this one actor's isolation, preserving a
    /// listen-before-write ordering guarantee: the listen is set up before the write is
    /// issued, so there is no risk of data loss due to missed notifications. The timeout
    /// covers the whole sequence (subscribe + write + wait), throwing
    /// ``BLESwiftError/listenTimedOut``.
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
    /// but accumulating raw packets until exactly `expectedLength` bytes have arrived
    /// (`> expectedLength` throws ``BLESwiftError/tooMuchData(expected:received:)``).
    /// The timeout covers the **whole assembly** — partially received data does not
    /// defeat it, encoded as a test.
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

    /// Backs `Peripheral.flush(_:quietPeriod:)`: keeps consuming (and discarding) raw
    /// packets for as long as any data keeps arriving; completes only once a full
    /// `quietPeriod` elapses with zero packets — every received packet restarts the window.
    /// Implemented by racing each `next()` against ``withTimeout(_:throwing:operation:)``
    /// (catching the timeout marks the flush complete); no semaphores.
    ///
    /// - Throws: ``BLESwiftError/invalidArgument(_:)`` if `quietPeriod` isn't strictly
    ///   positive, rather than crashing.
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

    /// Suspends until `register` resumes the continuation it's given — either normally (a
    /// real CoreBluetooth completion event routed through `handle(_:from:)`) or, on
    /// cancellation, via `onCancelled`, which is expected to hop onto ``queue`` via
    /// `assumeIsolated` (the same sanctioned pattern `awaitConnect`'s own `onCancel` uses)
    /// and take-then-resume whatever registry entry `register` populated.
    ///
    /// Every raw continuation that awaits a CoreBluetooth completion event goes through
    /// this rather than a bare `withCheckedThrowingContinuation`. This is not optional
    /// decoration: ``withTimeout(_:throwing:operation:)``'s own doc comment documents why —
    /// merely marking a `Task` cancelled never by itself resumes a suspended continuation,
    /// and `withThrowingTaskGroup` cannot return until every child task (including one
    /// stuck suspended on a continuation nobody will ever resume) has actually finished. A
    /// GATT operation that doesn't react to cancellation this way would make its own
    /// `timeout:` hang forever instead of throwing ``BLESwiftError/timedOut`` once the timer
    /// wins the race.
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

    // MARK: - Per-characteristic FIFO

    /// Serializes GATT operations on the same characteristic: awaits `characteristic`'s
    /// previous tail `Task` (if any) before running `operation`, then replaces the tail with
    /// a fresh one representing *this* call, so whatever queues up behind it waits in turn
    /// — the per-characteristic FIFO tail-chain. Different characteristics have different
    /// keys, so their operations interleave freely instead
    /// of blocking on each other.
    ///
    /// `operation` runs **inline**, in this same call's own task — deliberately not inside a
    /// separately spawned `Task { }` (an earlier version of this function did that, and it
    /// was a genuine bug: an unstructured `Task { }` does not inherit the cancellation of
    /// the context that spawned it, so `withTimeout`'s cancellation of the caller could never
    /// reach `operation`'s own continuation-based waits, and a `timeout:` would hang forever
    /// instead of throwing — exactly the contract ``withCancellableGATTContinuation(register:onCancelled:)``
    /// exists to satisfy). Running inline means this call's own task *is* the one
    /// `withTimeout`/task cancellation actually marks, so `operation`'s cancellation
    /// handlers fire correctly.
    ///
    /// The tail itself is a plain completion signal (`AsyncStream<Void>` finished exactly
    /// once, wrapped in a `Task<Void, Never>` that only ever awaits it) — not a proxy for
    /// `operation`'s result, which this function returns/throws directly to its own caller.
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
    /// serializes `readRSSI()` calls against each other via ``Session/rssiTail`` (a single
    /// tail, not a per-characteristic map — RSSI has no owning characteristic). See that
    /// function's doc comment for why `operation` runs inline rather than in a spawned
    /// `Task`.
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
    /// `.poweredOn` — an operation can't proceed without a powered-on radio.
    ///
    /// Fails the active scan, if any (``failActiveScan(_:)``). Connection-lifecycle and
    /// GATT operations are *not* separately failed here: both live inside `phase`
    /// (`Connecting`'s continuation, `Session`'s GATT registries), and `handle(_:)`'s
    /// caller already follows this call with
    /// ``handleBluetoothUnavailable()``, which routes through
    /// ``handleTermination(identifier:error:)`` → ``failPendingGATTContinuations(error:)``
    /// for exactly that state. A scan has no such connection-scoped home to route through
    /// (it is independent of, and unaffected by, connection state), which is why it's
    /// handled directly here instead.
    func failAllPendingOperations(error: BLESwiftError) {
        log("Failing all pending operations: \(error)", level: .warning, category: "state")
        failActiveScan(error)
    }

    // MARK: - Scanning

    /// Scans for nearby peripherals advertising `services`, yielding a ``ScanEvent`` for
    /// every sighting.
    ///
    /// Each call creates its own independent, single-consumer `AsyncThrowingStream`. BLESwift
    /// enforces CoreBluetooth's single-physical-scanner discipline: calling `scan` again
    /// while a scan is already active immediately finishes the *new* stream by throwing
    /// ``BLESwiftError/alreadyScanning`` — the original scan is unaffected and keeps running.
    ///
    /// ### Stopping the scan
    /// The scan stops when its stream is stopped by the consumer — `break`ing out of a
    /// `for try await` loop, or cancelling the `Task` iterating it — or when this method's
    /// own `timeout:` elapses, or when the radio leaves ``CentralState/poweredOn`` while
    /// scanning (which finishes the stream by throwing ``BLESwiftError/bluetoothUnavailable``),
    /// or when a backgrounding guard fires (see below).
    /// `CBCentralManager.stopScan()` is only ever called while the radio reports
    /// `.poweredOn` — calling it otherwise is a CoreBluetooth "API MISUSE" no-op that also
    /// logs a warning.
    ///
    /// ### Filtering and connecting during a scan
    /// To exclude a peripheral, `filter` it out of the stream yourself; to connect to a
    /// sighted peripheral, call `connect(_:)` with its identifier. Connecting does **not**
    /// stop or otherwise affect a live scan — the scan keeps running until its own consumer
    /// stops it.
    ///
    /// ### Duplicate sightings, loss tracking, and RSSI throttling
    /// A peripheral is reported once as ``ScanEvent/discovered(_:)`` the first time it's
    /// seen. If `allowDuplicates` is `true`, every later CoreBluetooth `didDiscover` for the
    /// same peripheral is reported as ``ScanEvent/updated(_:)`` (unless suppressed by
    /// `rssiThreshold` — see below), and a per-peripheral loss-expiry deadline of
    /// `lossTimeout` is refreshed on every sighting; if that deadline elapses without a
    /// re-sighting, the peripheral is reported as ``ScanEvent/lost(_:)`` and forgotten (a
    /// later re-sighting is reported as a fresh ``ScanEvent/discovered(_:)``, not
    /// ``ScanEvent/updated(_:)``). If `allowDuplicates` is `false` (the default),
    /// CoreBluetooth itself never redelivers a discovery for an already-discovered
    /// peripheral, so ``ScanEvent/updated(_:)`` and ``ScanEvent/lost(_:)`` are never
    /// emitted. `rssiThreshold`, if non-`nil`, suppresses an ``ScanEvent/updated(_:)`` (but
    /// not the loss-timer refresh) whenever the absolute change in RSSI since the
    /// peripheral's last-*reported* sighting is smaller than the threshold.
    ///
    /// ### Background guards (iOS only)
    /// Apple discourages `allowDuplicates: true` and omitting `services` while the app is
    /// backgrounded (both increase battery/CPU cost, and `allowDuplicates` scanning stops
    /// working in the background entirely). On iOS, if either applies, this scan is
    /// automatically failed — finishing the stream by throwing
    /// ``BLESwiftError/allowDuplicatesInBackgroundNotSupported`` or
    /// ``BLESwiftError/missingServiceIdentifiersInBackground`` respectively — the moment the
    /// app enters the background (`UIApplication.didEnterBackgroundNotification`). Passing
    /// `nil` (or empty) `services` also logs a warning at scan start regardless of
    /// platform, per Apple's general guidance against unscoped scanning.
    ///
    /// - Parameters:
    ///   - services: The services to scan for. Passing `nil` scans for all peripherals
    ///     regardless of advertised services — discouraged by Apple (see above) outside of
    ///     short, deliberately time-boxed scans.
    ///   - allowDuplicates: Whether to keep reporting an already-discovered peripheral's
    ///     further sightings as ``ScanEvent/updated(_:)`` (and track its loss). Defaults to
    ///     `false`. Mirrors `CBCentralManagerScanOptionAllowDuplicatesKey`.
    ///   - rssiThreshold: The minimum absolute RSSI delta (in dBm) required for a repeat
    ///     sighting to be reported as ``ScanEvent/updated(_:)``. `nil` (the default)
    ///     disables throttling.
    ///   - lossTimeout: How long a sighted peripheral may go unseen before it's reported as
    ///     ``ScanEvent/lost(_:)``. Only meaningful when `allowDuplicates` is `true`.
    ///     Defaults to 15 seconds.
    ///   - timeout: The maximum duration of the scan. `nil` (the default) scans until the
    ///     consumer stops it. On elapsing, the stream finishes cleanly (no error).
    /// - Returns: A single-consumer stream of ``ScanEvent``s.
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

    /// Routes a `CentralEvent/didDiscover` event to the active scan, if any (a discovery
    /// delivered after the scan has ended — e.g. raced against `stopScan()` — is silently
    /// dropped, matching CoreBluetooth's own best-effort delivery guarantees).
    ///
    /// Emits exactly one ``ScanEvent`` per call, for a single CoreBluetooth `didDiscover`
    /// callback.
    private func handleDiscovery(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int) {
        guard let scan = activeScan else { return }

        let newDiscovery = Discovery(peripheral: peripheral, advertisement: advertisement, rssi: rssi)

        // Only allowDuplicates scans track loss — refreshed even if the sighting below
        // turns out to be throttled (ahead of the throttle check): a throttled sighting is
        // still evidence the peripheral hasn't gone silent.
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

    /// (Re)schedules `peripheral`'s loss-expiry deadline: cancels any existing timer for it
    /// and starts a fresh `lossTimeout`-long one. Only called for `allowDuplicates` scans.
    ///
    /// This (along with the scan-timeout `Task` in ``scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``)
    /// is one of the package's sanctioned `Task { }` usages: actor-method-spawned scheduling
    /// work, not a hop out of a delegate callback. It is stored (`ActiveScan.lossTimers`) so it can
    /// always be cancelled, and its closure never touches actor or `ActiveScan` state
    /// synchronously — it only re-enters actor isolation via `await self?.handleLoss(of:)`.
    private func scheduleLossTimer(for peripheral: PeripheralIdentifier, in scan: ActiveScan) {
        scan.lossTimers[peripheral.uuid]?.cancel()

        let lossTimeout = scan.lossTimeout
        scan.lossTimers[peripheral.uuid] = Task { [weak self] in
            try? await Task.sleep(for: lossTimeout)
            guard !Task.isCancelled else { return }
            await self?.handleLoss(of: peripheral)
        }
    }

    /// Reports `peripheral` as ``ScanEvent/lost(_:)`` if it's still tracked by the active
    /// scan — it may have already been re-sighted (cancelling and replacing its loss timer)
    /// or the scan may have already ended by the time this fires.
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

    /// The single cleanup path for an ended scan — cancels every loss timer and the
    /// timeout task, removes the backgrounding observer (iOS), stops the hardware scan
    /// (only if the radio is still `.poweredOn` — calling `stopScan()` otherwise is a
    /// CoreBluetooth "API MISUSE" no-op that also logs a warning), and clears
    /// ``activeScan``/``isScanning``.
    ///
    /// The **only** caller is the `onTermination` handler installed by
    /// ``scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``: every way a
    /// scan ends (consumer `break`/task-cancel, ``timeoutActiveScan()``,
    /// ``failActiveScan(_:)``) does so by finishing the stream's continuation, which
    /// `AsyncThrowingStream` guarantees synchronously triggers `onTermination` exactly
    /// once. Idempotent (guards on ``activeScan`` being non-`nil`) since `onTermination`'s
    /// queue-hopped delivery means a second termination signal could plausibly still be in
    /// flight when this runs.
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
    /// scan per Apple's background-scanning restrictions, if `allowDuplicates` or
    /// `missingServices` applies. A no-op if neither applies (no guard is needed).
    ///
    /// The observer's handler hops back into actor isolation via `queue.async` +
    /// `assumeIsolated` — **not** `Task { }` — because `NotificationCenter`'s handler, like
    /// a CoreBluetooth delegate callback, can fire on an arbitrary thread and must not
    /// touch actor-isolated state synchronously.
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
    /// Returns a stream of every ``RestorationEvent`` — **replaying every event buffered
    /// since this `Central` was created** to the first consumer, in order.
    ///
    /// Restoration happens during app launch, usually before any consumer task has had a
    /// chance to start; the replay guarantees nothing is lost as long as the consumer
    /// subscribes *eventually* (still: subscribe as early in launch as practical — the
    /// startup background-time window is finite). Consumers subscribing after the first
    /// see only events from their subscription onward.
    ///
    /// Events appear here only when ``Configuration/restoration`` was set; without it the
    /// stream stays silent forever.
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
    /// staged restoration (``routeRestoredPeripherals(_:)``) or — nothing staged, nothing
    /// in flight — closes the startup window (a normal launch with restoration enabled but
    /// no state to restore); any other state fails a staged restoration with
    /// ``BLESwiftError/bluetoothUnavailable``.
    ///
    /// When the non-powered-on branch clears staged restoration peripherals, BLESwift
    /// emits ``RestorationEvent/failedToRestoreConnection(_:error:)`` so the consumer always
    /// learns the outcome of a ``RestorationEvent/willRestore(_:)`` it observed.
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
            // Any in-flight restored-connecting re-connects (`restorationTasks`) are not
            // touched here: the radio loss fails each one's `connect` on its own
            // (`handleBluetoothUnavailable`), and each task's own catch emits the failure
            // event and removes its own entry — `closeStartupWindowIfIdle()` below closes
            // the window only once every such entry (and `pendingRestoration`, cleared
            // above) has resolved.
            closeStartupWindowIfIdle()
        }
    }

    /// Routes `.poweredOn` restoration: EVERY restored peripheral is routed — restored-
    /// *connected* → adopted as a live session; restored-*connecting* → its own concurrent
    /// manual re-connect task; restored-*disconnecting*/*disconnected* →
    /// ``RestorationEvent/failedToRestoreConnection(_:error:)`` with
    /// ``BLESwiftError/notConnected``. The startup window closes only once every outcome
    /// here has resolved (``closeStartupWindowIfIdle()``, called once at the end — every
    /// per-peripheral routing step below is synchronous within this same actor turn, except
    /// spawning a restoration task, which registers itself in ``restorationTasks`` before
    /// this function returns).
    ///
    /// - Warning: The `disconnecting`/`disconnected` paths have no known way to recreate or
    ///   test on real hardware; that caveat carries over here as well.
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
    /// connection work is needed (it *is* connected); GATT operations work immediately
    /// through the ``connectionState(of:)`` `Peripheral` handle, with a `.connected` event
    /// emitted on ``connectionEvents()``.
    ///
    /// The adopted session's ``ReconnectPolicy`` is ``ReconnectPolicy/never`` — no
    /// `connect(_:timeout:reconnect:warningOptions:)` call exists to have specified one; a
    /// consumer wanting auto-reconnect can observe the eventual disconnect and reconnect
    /// with its preferred policy.
    ///
    /// Does not itself close the startup window — called only from
    /// ``routeRestoredPeripherals(_:)``, which closes it (if idle) once for the whole batch.
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

        // Wire event delivery before the session goes live — the one shared mechanism for
        // every session-creating path (see `awaitConnect`). Idempotent with the early
        // wiring `handle(_: CentralEvent)`'s `.willRestoreState` case performs (so
        // notifications arriving before this routing still reach `Central`).
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
    /// restores the attempt's existence but never completes (nor re-issues) it, so BLESwift
    /// must connect explicitly, with a default 15 s timeout configurable via
    /// ``RestorationConfiguration``. Spawns and stores a ``restorationTasks`` entry keyed by
    /// `identifier` (ledgered `Task { }` site — see that property); multiple restored-
    /// connecting peripherals each get their own entry and run concurrently.
    private func startRestorationConnect(_ identifier: PeripheralIdentifier) {
        let timeout = configuration.restoration?.connectingTimeout ?? .seconds(15)
        log("Restored peripheral \(identifier) was connecting — issuing manual re-connect (timeout: \(timeout))", level: .info, category: "restore")
        restorationTasks[identifier] = Task { [weak self] in
            await self?.runRestorationConnect(identifier: identifier, timeout: timeout)
        }
    }

    /// The body of one ``restorationTasks`` entry: one manual connect attempt for
    /// `identifier`, resolved into a ``RestorationEvent/restoredConnection(_:)`` or
    /// ``RestorationEvent/failedToRestoreConnection(_:error:)``, always followed by removing
    /// its own `restorationTasks` entry and closing the startup window if every outcome has
    /// now resolved.
    ///
    /// Calls ``establishConnection(identifier:policy:timeout:warningOptions:)`` directly
    /// rather than `connect(...)`: the public method's `pendingRestoration` guard exists
    /// to fence *user* calls out of the restoration window — the restoration connect is
    /// the one connect that window belongs to.
    private func runRestorationConnect(identifier: PeripheralIdentifier, timeout: Duration) async {
        // Expiration-vs-routing race guard (verifier finding): `.poweredOn` routing spawns
        // this task, but the task body runs a hop later — if the startup background task
        // expired in that gap, `handleStartupBackgroundTaskExpiration` found nothing to
        // fail (`pendingRestoration` was already consumed by routing, and `identifier` had
        // no `connections` entry yet, so `failPendingConnect` was a no-op). Without this
        // guard the manual connect would proceed with its full timeout despite the window
        // being closed. `startRestorationConnect` is the only spawn site, and routing runs
        // synchronously within the state-change's actor turn, so this is the one gap — it
        // applies independently to every restored-connecting peripheral.
        guard startupWindowOpen else {
            // Silent when cancelled: `stopAndExtractState()`/`deinit` cancel this task
            // after closing the window — that is teardown, not an expiration to report.
            if !Task.isCancelled {
                log("Startup window closed before the restoration connect could start — failing restoration for \(identifier)", level: .warning, category: "restore")
                restorationBroadcaster.yield(.failedToRestoreConnection(identifier, error: BLESwiftError.startupBackgroundTaskExpired))
            }
            restorationTasks.removeValue(forKey: identifier)
            return
        }

        do {
            // Reserve the slot synchronously (same discipline as user `connect(_:)`) — throws
            // `.duplicateConnect(identifier)` if the slot is already occupied (e.g. a user
            // `connect(id)` for this same restored id landed first, once routing had consumed
            // `pendingRestoration`), so the two never overwrite each other's attempt.
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

    /// Reacts to iOS expiring the startup background task before restoration finished
    /// (wired in `init` via the `StartupBackgroundTaskRunning` seam): every pending
    /// restoration operation fails with ``BLESwiftError/startupBackgroundTaskExpired`` —
    /// covering BLESwift's two restoration-pending states: a staged-but-unrouted
    /// ``pendingRestoration``, and every in-flight restored-connecting re-connect in
    /// ``restorationTasks`` (each failed through the standard two-phase connect
    /// cancellation, so its continuation resolves with this error once CoreBluetooth
    /// confirms).
    private func handleStartupBackgroundTaskExpiration() {
        guard startupWindowOpen else { return }
        log("Startup background task expired during restoration", level: .warning, category: "restore")

        if let pending = pendingRestoration {
            pendingRestoration = nil
            for peripheral in pending.peripherals {
                restorationBroadcaster.yield(.failedToRestoreConnection(peripheral.identifier, error: BLESwiftError.startupBackgroundTaskExpired))
            }
        }

        // Snapshot keys first — `failPendingConnect(for:)` can synchronously mutate
        // `connections` (and, via `handleTermination`, other actor-owned state), so never
        // iterate a map while mutating it.
        for identifier in Array(restorationTasks.keys) {
            // Each task's own catch emits its failure event and removes its own entry once
            // its two-phase cancel resolves; the window is also closed unconditionally
            // below so the platform task is released *now*, not when CoreBluetooth gets
            // around to confirming every one of them.
            failPendingConnect(for: identifier, error: BLESwiftError.startupBackgroundTaskExpired)
        }

        endStartupBackgroundTask()
    }

    /// Closes the startup restoration window (via ``endStartupBackgroundTask()``) once
    /// every restoration outcome has resolved: no staged-but-unrouted ``pendingRestoration``
    /// and no in-flight ``restorationTasks`` entries. Safe to call speculatively from every
    /// restoration exit point — a no-op while anything is still pending, and idempotent
    /// (via ``endStartupBackgroundTask()``'s own guard) once everything has resolved.
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

    /// Writes `message` to ``configuration``'s `swift-log` `Logger`, tagged with
    /// `"category"` metadata — BLESwift's single internal log call site signature, used
    /// throughout instead of ad hoc `print`/`os.Logger` calls. A custom `LogHandler`
    /// installed on that logger is the observer seam.
    private func log(_ message: @autoclosure () -> Logger.Message, level: Logger.Level, category: String) {
        configuration.logger.log(level: level, message(), metadata: ["category": .string(category)])
    }
}

// MARK: - Connection state machine

/// `Central`'s internal per-peripheral connection state machine. Declared file-private (not
/// nested in `Central`) purely for the associated structs' own visibility; nothing outside
/// this file inspects `PeripheralPhase` directly — ``Central/connectionState(of:)``
/// projects it into the public ``ConnectionState``.
///
/// Identical cases to the pre-multi-peripheral single `Phase` type, minus `.idle` —
/// absence of an entry from ``Central/connections`` IS that peripheral's idle state;
/// `Central` never stores a `.idle` case.
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
/// continuation for this one peripheral (each peripheral gets its own `Connecting` value
/// inside ``Central/connections``, so this remains one optional value, not a registry) and
/// the two-phase cancel's `stopping` flag.
private struct Connecting {
    let identifier: PeripheralIdentifier
    let peripheral: any PeripheralRemote
    let policy: ReconnectPolicy
    let timeout: Duration?
    let warningOptions: WarningOptions
    /// The pending connect continuation. `nil` in two distinct situations:
    /// 1. **Reserved-but-unattached** — between `Central.reserveConnectingSlot(...)` writing
    ///    this entry synchronously and `Central.awaitConnect(...)` attaching its continuation
    ///    (and only then issuing the CoreBluetooth `connect`). While `nil` here, no
    ///    CoreBluetooth attempt has been issued, so the cancel paths treat the slot specially
    ///    (record into `stopping`, resolved by `awaitConnect`'s attach) rather than
    ///    two-phase-cancelling a nonexistent attempt. This is the slot-reservation that
    ///    closes the concurrent-connect TOCTOU deadlock.
    /// 2. **Taken** — once resumed, `Central` sets it back to `nil` before/while transitioning
    ///    the entry away from `.connecting`.
    ///
    /// When non-`nil` and a CoreBluetooth attempt is in flight, it is resumed exactly once,
    /// by `Central.handleTermination(identifier:error:)` (success or failure) — never resumed
    /// directly by whatever *requests* cancellation (`Central.failPendingConnect(for:error:)`),
    /// matching the two-phase-cancel ground truth.
    var continuation: CheckedContinuation<Peripheral, Error>?
    /// Non-`nil` once cancellation (task cancellation, timeout, `cancelAllOperations`) has
    /// been requested for this attempt — the error `continuation` will eventually resume
    /// with, once CoreBluetooth confirms.
    var stopping: Error?
}

/// State for one established connection.
///
/// Also holds every piece of GATT bookkeeping — a deliberate design: GATT
/// pending-operation state lives *inside* the connection `Session`, not at actor level,
/// so disconnect cleanup (``Central/failPendingGATTContinuations(for:error:)``)
/// drops it structurally along with the rest of that connection, and multi-peripheral
/// isolation falls out for free: each ``Central/connections`` entry owns its own `Session`
/// (and so its own registries), and teardown of one entry can never touch another's.
private struct Session {
    let identifier: PeripheralIdentifier
    let peripheral: any PeripheralRemote
    let policy: ReconnectPolicy
    let timeout: Duration?
    let warningOptions: WarningOptions

    // MARK: - GATT

    /// Per-characteristic FIFO tail-chain: each new read/write on a characteristic awaits
    /// the previous tail `Task` for that characteristic (if any) before running, then
    /// replaces it with its own. Different characteristics have different keys and so
    /// interleave freely. See `Central.runOnFIFO(identifier:characteristic:operation:)`.
    var fifoTails: [CharacteristicIdentifier: Task<Void, Never>] = [:]

    /// The RSSI-only counterpart to ``fifoTails``: `readRSSI()` has no owning
    /// characteristic, so it is serialized via a single tail instead of a per-characteristic
    /// map. See `Central.runRSSISerialized(identifier:operation:)`.
    var rssiTail: Task<Void, Never>?

    /// The single pending read continuation for each characteristic currently being read.
    /// Single-slot per characteristic, guaranteed by ``fifoTails``: the FIFO ensures only
    /// one read can be in flight per characteristic at a time. Take-then-resume.
    var pendingReads: [CharacteristicIdentifier: CheckedContinuation<Data, Error>] = [:]

    /// The single pending write continuation for each characteristic currently being
    /// written (`.withResponse` only — `.withoutResponse` synthesizes completion
    /// immediately and never registers here). See ``pendingReads``.
    var pendingWrites: [CharacteristicIdentifier: CheckedContinuation<Void, Error>] = [:]

    /// The single pending notify-state-change continuation for each characteristic
    /// currently toggling notifications. Unused until notifications (a later phase) call
    /// `setNotifyValue(_:for:)` — the registry and `Central`'s resume-routing for it already
    /// exist so that phase only needs to populate this dictionary. Resumes with the
    /// resulting `isNotifying` value.
    var pendingNotifyStateChanges: [CharacteristicIdentifier: CheckedContinuation<Bool, Error>] = [:]

    /// The single pending RSSI-read continuation, if any. Single-slot, guaranteed by
    /// ``rssiTail``.
    var pendingRSSIRead: CheckedContinuation<Int, Error>?

    /// Pending service-discovery waiters, keyed by a monotonic token from
    /// ``nextGATTWaiterToken()`` — **not** keyed by service: CoreBluetooth's
    /// `didDiscoverServices(error:)` carries no service identifier, so a single
    /// `discoverServices(_:)` completion can't be matched to the specific call(s) that
    /// triggered it — every waiter is resumed on every completion, and each independently
    /// re-checks its own service's discovery via `isDiscovered(_:)` afterward. Multiple
    /// waiters can be pending at once (not a single slot): two different characteristics'
    /// independent FIFO chains can each trigger their own concurrent `discoverServices(_:)`
    /// call for a still-undiscovered service, and every such waiter must be resumed, not
    /// just the most recent one. Tokened (rather than a plain array) so a single cancelled
    /// waiter can be individually removed without disturbing the others.
    var pendingDiscoverServices: [UInt64: CheckedContinuation<Void, Error>] = [:]

    /// Pending characteristic-discovery waiters, keyed by service (`didDiscoverCharacteristics(service:error:)`
    /// does carry the service) and then, within each service, by the same per-waiter token
    /// as ``pendingDiscoverServices`` — for the same cross-characteristic-concurrency and
    /// individual-cancellation reasons.
    var pendingDiscoverCharacteristics: [ServiceIdentifier: [UInt64: CheckedContinuation<Void, Error>]] = [:]

    /// Pending waiters for `.isReadyToSendWriteWithoutResponse`, keyed by the same per-waiter
    /// token. Not keyed by characteristic: `canSendWriteWithoutResponse`/
    /// `peripheralIsReady(toSendWriteWithoutResponse:)` are peripheral-wide in
    /// CoreBluetooth's own API, not per-characteristic.
    var pendingWriteWithoutResponseReady: [UInt64: CheckedContinuation<Void, Error>] = [:]

    // MARK: - Notifications

    /// The active notification subscription for each characteristic BLESwift is currently
    /// listening to, keyed by characteristic. Lives inside `Session` like every other
    /// piece of GATT bookkeeping, so disconnect cleanup drops it structurally —
    /// `Central.finishNotificationStreams(error:)` finishes every
    /// subscription's broadcaster first, while the session still exists.
    var notificationSubscriptions: [CharacteristicIdentifier: NotificationSubscription] = [:]

    /// The per-subscriber pump task for each `Peripheral.notifications(for:policy:)`
    /// subscriber, keyed by its subscriber token — a ledgered `Task { }` site
    /// (actor-spawned by `Central.startNotificationPump(peripheral:characteristic:token:deliver:finish:)`,
    /// stored here, cancelled by `Central.handleNotificationStreamTermination(peripheral:characteristic:token:)`).
    /// Each pump bridges the raw `Data` multicast into one subscriber's typed stream and
    /// ends on its own when that raw stream finishes; entries removed on termination.
    var notificationPumps: [UUID: Task<Void, Never>] = [:]

    /// The single `Session`-building shape for every **adoption** path — restoration
    /// adoption (`Central.adoptRestoredConnection(_:)`) and
    /// `Central.init(adopting:connectedPeripheral:...)` / the test init's staged
    /// equivalent: the peripheral is already connected, so no
    /// `connect(_:timeout:reconnect:warningOptions:)` call exists to have specified a
    /// policy or timeout. Policy is ``ReconnectPolicy/never`` (documented on each caller):
    /// a consumer wanting auto-reconnect can observe the eventual disconnect and reconnect
    /// with its preferred policy.
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

    /// Hands out a fresh, monotonically increasing token identifying one waiter in
    /// ``pendingDiscoverServices``, ``pendingDiscoverCharacteristics``, or
    /// ``pendingWriteWithoutResponseReady`` — letting a single cancelled waiter be removed
    /// by key without disturbing any other concurrently pending waiter in the same
    /// dictionary.
    mutating func nextGATTWaiterToken() -> UInt64 {
        defer { nextWaiterTokenValue += 1 }
        return nextWaiterTokenValue
    }
}

/// One characteristic's active notification subscription: the raw-`Data` multicast every
/// subscriber shares, plus the refcount (as a token set) driving the underlying
/// `setNotifyValue` lifecycle — `0 → 1` enables notifications (awaiting
/// `didUpdateNotificationState` confirmation), the last release disables them (only if
/// still connected and powered on).
private struct NotificationSubscription {
    /// The raw-`Data` multicast: every `didUpdateValue` for this characteristic is
    /// `yield`ed here (decode happens per caller, in each subscriber's own decode layer,
    /// so one subscriber's decode failure can't affect the others).
    let broadcaster = ThrowingBroadcaster<Data>()

    /// One token per live subscriber (typed `notifications(for:policy:)` streams and
    /// composite helpers alike). A token set rather than a bare count so release is
    /// idempotent per subscriber — a stray double-release can't underflow the refcount.
    var subscriberTokens: Set<UUID> = []

    /// Whether the `setNotifyValue(true)` handshake has completed (the confirming
    /// `didUpdateNotificationState` arrived). Notifications received before confirmation
    /// are still multicast (the subscription registers *before* enabling, closing the
    /// loss window); this flag exists so late joiners — composite helpers especially,
    /// whose listen-before-write ordering guarantee requires an *installed* listen — can
    /// await the in-flight handshake instead of racing it.
    var enableConfirmed = false

    /// Joiners suspended waiting for ``enableConfirmed``, keyed by their subscriber
    /// token. Take-then-resume: resumed (returning) by
    /// `Central.confirmNotificationEnablement(identifier:characteristic:)`, or (throwing)
    /// by `Central.failNotificationSubscription(identifier:characteristic:error:)`/
    /// `Central.finishNotificationStreams(error:)`/individual cancellation.
    var enableWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
}

/// A single-consumer box around an `AsyncThrowingStream` iterator, letting
/// `Central.performFlush(peripheral:characteristic:quietPeriod:)` re-`await` `next()`
/// inside successive `withTimeout` races — whose operation closures are `@Sendable` and so
/// cannot capture a mutable local iterator directly.
///
/// `iterator` is `nonisolated(unsafe)` for the same narrowly-justified reason as
/// `WeakCentralBox.central` (and NOT a type-wide `@unchecked Sendable`, which stays
/// grep-forbidden): accesses are strictly sequential by construction — each `withTimeout`
/// window's operation child task is the only code that touches it, and every window is
/// fully awaited before the next begins (`withThrowingTaskGroup` does not return until all
/// of its children, including a cancelled `next()`, have actually finished); the timer
/// child never touches it.
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
/// non-`nil`) or a `cancelAllOperations` cancelling a pending connect attempt
/// (`continuation` `nil`, since that call is synchronous and hands out no continuation of
/// its own).
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
