//
//  PeripheralHost.swift
//  BLESwift
//

// `@preconcurrency`: `CBPeripheralManager` predates Sendable and is not `Sendable`.
// `stopAndExtractState()` hands it back to a caller outside this actor's isolation domain —
// a legitimate one-time ownership transfer — which only type-checks under `@preconcurrency`.
// Same rationale as `Central`'s.
import BLESwiftCore
@preconcurrency import CoreBluetooth
import Dispatch
import Foundation
import Logging
import Synchronization

/// BLESwift's peripheral-role entry point: an actor wrapping a single `CBPeripheralManager`.
///
/// Where ``Central`` is the *central* role, `PeripheralHost` is the *peripheral* role — it
/// hosts a GATT database, advertises it, and answers reads / writes / subscriptions from
/// remote centrals. Its architecture mirrors ``Central`` exactly: the actor's isolation is
/// tied directly to the `DispatchSerialQueue` its `CBPeripheralManager` delivers delegate
/// callbacks on (see ``unownedExecutor``), so every proxy callback already runs on the
/// actor's own executor with no thread hop.
///
/// - Important: The peripheral role is not usable at runtime on every Apple platform — tvOS
///   and watchOS restrict or disallow BLE advertising, surfaced through ``state`` and
///   ``startAdvertising(_:)``'s completion rather than a compile-time restriction.
///
/// - Note: Subscribe to ``readRequests()`` / ``writeRequests()`` / ``subscriptionEvents()``
///   **before** you ``startAdvertising(_:)``. Those streams do not replay.
public actor PeripheralHost {

    /// The `DispatchSerialQueue` this actor's executor is tied to (see ``unownedExecutor``),
    /// and the same queue the underlying `CBPeripheralManager` delivers delegate callbacks on.
    nonisolated let queue: DispatchSerialQueue

    /// Ties this actor's isolation directly to ``queue`` (SE-0424 custom executors), exactly
    /// as ``Central/unownedExecutor`` does. Declared `public` because it satisfies a
    /// requirement of the public `Actor` protocol; not meant for direct use by clients.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// The CoreBluetooth shim this host drives. `Optional`/`var` so ``stopAndExtractState()``
    /// can `nil` it out as part of handing the `CBPeripheralManager` back to the caller
    /// (required for a sound non-`Sendable` ownership transfer — see ``Central``'s `manager`).
    private var manager: (any PeripheralManaging)?

    /// This host's `CBPeripheralManagerDelegate`, strongly owned here so it outlives the gap
    /// before `CBPeripheralManager(delegate:queue:options:)`. Non-`nil` only for
    /// ``init(configuration:)``.
    private let proxy: PeripheralManagerDelegateProxy?

    /// The configuration this host was created with (for its logger and power-alert option).
    private let configuration: Configuration

    /// Backs the nonisolated, synchronously-readable ``state`` snapshot. `Mutex` (not
    /// actor-isolated storage) so ``state`` reads without `await` from any isolation domain,
    /// mirroring ``Central/state``. ``handle(_:)`` is the only writer.
    private let stateBox = Mutex<CentralState>(.unknown)

    /// Multicasts every ``CentralState`` transition to ``stateEvents()`` subscribers,
    /// replaying the latest value to late subscribers.
    private let stateBroadcaster = Broadcaster<CentralState>(replay: .latest)

    /// Backs the nonisolated, synchronously-readable ``isAdvertising`` snapshot.
    private let isAdvertisingBox = Mutex<Bool>(false)

    /// The single in-flight ``startAdvertising(_:)`` continuation, resolved by
    /// `.didStartAdvertising`. At most one advertise start is awaited at a time.
    private var pendingStartAdvertising: CheckedContinuation<Void, Error>?

    /// In-flight ``add(_:)`` continuations, keyed by the service being added and resolved by
    /// `.didAddService` for that identifier.
    private var pendingAddService: [ServiceIdentifier: CheckedContinuation<Void, Error>] = [:]

    /// Multicasts every remote-central read request to ``readRequests()`` subscribers.
    private let readRequestBroadcaster = Broadcaster<ReadRequest>(replay: .none)

    /// Multicasts every remote-central write-request batch to ``writeRequests()`` subscribers.
    private let writeRequestBroadcaster = Broadcaster<WriteRequest>(replay: .none)

    /// Multicasts every subscribe/unsubscribe to ``subscriptionEvents()`` subscribers.
    private let subscriptionBroadcaster = Broadcaster<SubscriptionEvent>(replay: .none)

    /// The centrals currently subscribed to each hosted characteristic, keyed by
    /// characteristic then by `Subscriber.id` — maintained from `.didSubscribe`/
    /// `.didUnsubscribe`, and surfaced through ``subscribers(for:)``.
    private var subscribersByCharacteristic: [CharacteristicIdentifier: [UUID: Subscriber]] = [:]

    /// Back-pressure readiness waiters (see ``updateValue(_:for:onSubscribed:)``), resumed
    /// together on `.readyToUpdateSubscribers`. Tokened so a cancelled waiter removes exactly
    /// itself — the same shape as ``Central``'s `pendingWriteWithoutResponseReady`.
    private var readyWaiters: [UInt64: CheckedContinuation<Void, Error>] = [:]

    /// Monotonic allocator for ``readyWaiters`` tokens.
    private var nextReadyWaiterToken: UInt64 = 0

    // MARK: - Background restoration state

    /// Multicasts every ``PeripheralRestorationEvent``. Replay `.allUntilFirstConsumer`:
    /// restoration happens during app launch, typically before any consumer task has
    /// started, so events are buffered and replayed to the first ``restorationEvents()``
    /// consumer. Mirrors ``Central``'s `restorationBroadcaster`.
    private let restorationBroadcaster = Broadcaster<PeripheralRestorationEvent>(replay: .allUntilFirstConsumer)

    /// Creates a `PeripheralHost`, synchronously creating its underlying `CBPeripheralManager`
    /// on a fresh, dedicated `DispatchSerialQueue`. Creation is synchronous (not deferred
    /// behind an async `start()`) so restoration can register its restore identifier before
    /// `willRestoreState` can arrive — same reason as ``Central/init(configuration:)``.
    ///
    /// - Parameter configuration: Start-time options. Defaults to `Configuration()`.
    public init(configuration: Configuration = Configuration()) {
        let queue = DispatchSerialQueue(label: "com.bleswift.PeripheralHost")
        self.queue = queue
        self.configuration = configuration

        let proxy = PeripheralManagerDelegateProxy()
        self.proxy = proxy

        #if os(iOS)
        var options: [String: Any] = [
            CBPeripheralManagerOptionShowPowerAlertKey: configuration.showPowerAlert
        ]
        // Must differ from any `Central`'s restore identifier — a CoreBluetooth requirement.
        if let peripheralRestoration = configuration.peripheralRestoration {
            options[CBPeripheralManagerOptionRestoreIdentifierKey] = peripheralRestoration.identifier
        }
        #else
        let options: [String: Any] = [
            CBPeripheralManagerOptionShowPowerAlertKey: configuration.showPowerAlert
        ]
        #endif

        let manager = CBPeripheralManager(delegate: proxy, queue: queue, options: options)
        self.manager = manager

        // Make the same proxy reachable via the associated object, so the conformance's
        // `respond`/`updateValue`/`add` can recover the CoreBluetooth objects it registers.
        manager.bleSwiftRegisterProxy(proxy)

        // Sets the proxy's handler directly, bypassing the `eventHandler` associated-object
        // mechanism (which would create a second, wrong proxy) — same as `Central.init`.
        proxy.handler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated { $0.handle(event) }
        }
    }

    /// Creates a `PeripheralHost` driving a custom backend — the seam that lets a scriptable
    /// fake stand in for a real `CBPeripheralManager`. Production apps use
    /// ``init(configuration:)``.
    ///
    /// - Important: `queue` **must be the exact `DispatchSerialQueue` instance** `backend`
    ///   confines its event deliveries to. A mismatch surfaces only as an `assumeIsolated`
    ///   trap the first time an event arrives off-queue.
    ///
    /// - Important: **Retention.** The closure installed on `backend.eventHandler` captures
    ///   `self` strongly, and `backend` is held by this host — a deliberate reference cycle
    ///   that keeps a host alive for as long as `backend` lives. Clear it explicitly
    ///   (`backend.eventHandler = nil`) for deterministic teardown.
    ///
    /// - Parameters:
    ///   - backend: The ``PeripheralManaging`` conformance to drive.
    ///   - queue: The `DispatchSerialQueue` `backend`'s events are confined to.
    ///   - configuration: Start-time options. Defaults to `Configuration()`.
    public init(
        backend: any PeripheralManaging,
        queue: DispatchSerialQueue,
        configuration: Configuration = Configuration()
    ) {
        self.queue = queue
        self.configuration = configuration
        self.manager = backend
        self.proxy = nil

        // `queue.sync` is safe here: nothing else runs on `queue` during init. Strong
        // self-capture forms the deliberate cycle documented above.
        queue.sync {
            backend.eventHandler = { event in
                self.assumeIsolated { $0.handle(event) }
            }
        }
    }

    /// Stops this host, detaching the underlying `CBPeripheralManager`'s delegate, and hands
    /// the manager back to the caller so it can be adopted by other code.
    ///
    /// Fails every pending advertise/add-service/readiness continuation with
    /// ``BLESwiftError/stopped`` and finishes the request streams before returning. BLESwift
    /// never crashes here: a naive `precondition` becomes a thrown ``BLESwiftError/stopped``.
    ///
    /// - Returns: The underlying `CBPeripheralManager`.
    /// - Throws: ``BLESwiftError/stopped`` if this host has already been stopped, or was not
    ///   created against a real `CBPeripheralManager` (only reachable via the backend
    ///   initializer — never through the public production API).
    public func stopAndExtractState() throws -> CBPeripheralManager {
        guard let currentManager = manager else {
            throw BLESwiftError.stopped
        }
        guard let cbManager = currentManager as? CBPeripheralManager else {
            throw BLESwiftError.stopped
        }

        failPendingOperations(error: BLESwiftError.stopped)
        readRequestBroadcaster.finish()
        writeRequestBroadcaster.finish()
        subscriptionBroadcaster.finish()
        subscribersByCharacteristic.removeAll()

        // Give up this actor's own reference before returning `cbManager` — see ``manager``.
        manager = nil
        cbManager.stopAdvertising()
        cbManager.delegate = nil
        proxy?.handler = nil

        return cbManager
    }

    // MARK: - Public surface: state

    /// The current state of the Bluetooth radio. A synchronous snapshot — readable without
    /// `await` from any isolation domain — kept current by ``handle(_:)`` on every
    /// `.didUpdateState`.
    public nonisolated var state: CentralState {
        stateBox.withLock { $0 }
    }

    /// The app's current Bluetooth authorization status.
    ///
    /// - Note: Returns `.notDetermined` after ``stopAndExtractState()`` — this host no longer
    ///   owns a manager to ask at that point.
    public var authorization: BluetoothAuthorization {
        guard let manager else { return .notDetermined }
        return type(of: manager).bluetoothAuthorization
    }

    /// Whether this host is currently advertising. A synchronous snapshot, kept current by
    /// ``startAdvertising(_:)``/``stopAdvertising()`` and the advertising completion.
    public nonisolated var isAdvertising: Bool {
        isAdvertisingBox.withLock { $0 }
    }

    /// Returns a multicast stream of every ``CentralState`` transition, replaying the most
    /// recent state to late subscribers.
    public func stateEvents() -> AsyncStream<CentralState> {
        stateBroadcaster.stream()
    }

    // MARK: - Public surface: GATT database

    /// Publishes a service (and its characteristics) into the local GATT database, awaiting
    /// CoreBluetooth's confirmation.
    ///
    /// - Parameter service: The service to publish.
    /// - Throws: ``BLESwiftError/stopped`` if this host has been stopped;
    ///   ``BLESwiftError/operationCancelled`` if the calling `Task` is cancelled; or whatever
    ///   error CoreBluetooth reports if it rejects the service.
    public func add(_ service: GATTService) async throws {
        guard manager != nil else { throw BLESwiftError.stopped }
        try await withCancellableContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                self.pendingAddService[service.identifier] = continuation
                self.log("Adding service \(service.identifier)", level: .info, category: "peripheral")
                self.manager?.add(service)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated { host in
                        host.cancelPendingAddService(service.identifier)
                    }
                }
            }
        )
    }

    /// Removes every published service from the local GATT database.
    public func removeAllServices() {
        manager?.removeAllHostedServices()
    }

    // MARK: - Public surface: advertising

    /// Begins advertising, awaiting `peripheralManagerDidStartAdvertising`.
    ///
    /// Returns immediately if already advertising. Only one advertise start may be awaited at
    /// a time.
    ///
    /// - Parameter advertisement: The local name and service UUIDs to advertise.
    /// - Throws: ``BLESwiftError/stopped`` if this host has been stopped;
    ///   ``BLESwiftError/invalidArgument(_:)`` if another ``startAdvertising(_:)`` is already
    ///   awaiting its completion; ``BLESwiftError/operationCancelled`` if the calling `Task`
    ///   is cancelled; or whatever error CoreBluetooth reports if advertising fails to start.
    public func startAdvertising(_ advertisement: PeripheralAdvertisement) async throws {
        guard let manager else { throw BLESwiftError.stopped }
        if manager.isAdvertising { return }

        try await withCancellableContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                guard self.pendingStartAdvertising == nil else {
                    continuation.resume(throwing: BLESwiftError.invalidArgument("startAdvertising is already in progress"))
                    return
                }
                self.pendingStartAdvertising = continuation
                self.log("Starting advertising: \(advertisement.localName ?? "<no name>")", level: .info, category: "peripheral")
                self.manager?.startAdvertising(advertisement)
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated { host in
                        host.cancelPendingStartAdvertising()
                    }
                }
            }
        )
    }

    /// Stops advertising. Idempotent; safe to call when not advertising.
    public func stopAdvertising() {
        manager?.stopAdvertising()
        isAdvertisingBox.withLock { $0 = false }
    }

    // MARK: - Public surface: request streams

    /// Returns a multicast stream of every read request from a remote central. Answer each
    /// with ``respond(to:with:)-(ReadRequest,_)``. Does not replay — subscribe before
    /// advertising.
    public func readRequests() -> AsyncStream<ReadRequest> {
        readRequestBroadcaster.stream()
    }

    /// Returns a multicast stream of every write-request batch from a remote central. Answer
    /// each with ``respond(to:with:)-(WriteRequest,_)``. Does not replay — subscribe before
    /// advertising.
    public func writeRequests() -> AsyncStream<WriteRequest> {
        writeRequestBroadcaster.stream()
    }

    /// Returns a multicast stream of every subscribe/unsubscribe from a remote central. Does
    /// not replay — subscribe before advertising. See also ``subscribers(for:)`` for the
    /// current snapshot.
    public func subscriptionEvents() -> AsyncStream<SubscriptionEvent> {
        subscriptionBroadcaster.stream()
    }

    /// The centrals currently subscribed to `characteristic`, sorted by identifier for
    /// determinism.
    public func subscribers(for characteristic: CharacteristicIdentifier) -> [Subscriber] {
        (subscribersByCharacteristic[characteristic]?.values).map { subscribers in
            subscribers.sorted { $0.id.uuidString < $1.id.uuidString }
        } ?? []
    }

    // MARK: - Public surface: respond

    /// Answers a remote central's read request. Every read request must be answered exactly
    /// once; a second response for the same request is a no-op.
    ///
    /// - Parameters:
    ///   - request: The read request to answer, from ``readRequests()``.
    ///   - result: `.success(Data)` with the value to return, or `.failure(ATTError)`.
    public func respond(to request: ReadRequest, with result: Result<Data, ATTError>) {
        switch result {
        case .success(let value):
            manager?.respond(to: request.token, value: value, error: nil)
        case .failure(let error):
            manager?.respond(to: request.token, value: nil, error: error)
        }
    }

    /// Answers a remote central's write-request batch. A single call acknowledges the whole
    /// batch. Every write request must be answered exactly once.
    ///
    /// - Parameters:
    ///   - request: The write-request batch to answer, from ``writeRequests()``.
    ///   - result: `.success` to apply the batch, or `.failure(ATTError)` to reject it.
    public func respond(to request: WriteRequest, with result: Result<Void, ATTError>) {
        switch result {
        case .success:
            manager?.respond(to: request.token, value: nil, error: nil)
        case .failure(let error):
            manager?.respond(to: request.token, value: nil, error: error)
        }
    }

    // MARK: - Public surface: notifications with back-pressure

    /// Pushes `value` as a notification/indication for `characteristic`, awaiting transmit
    /// capacity if the queue is momentarily full.
    ///
    /// Mirrors the central-side back-pressure pattern (``Peripheral``'s
    /// `writeWithoutResponse` awaiting `canSendWriteWithoutResponse`): CoreBluetooth's
    /// `updateValue` returns `false` when its transmit queue is full; this method then
    /// suspends until `peripheralManagerIsReady(toUpdateSubscribers:)` and retries.
    ///
    /// - Parameters:
    ///   - value: The bytes to notify. Values longer than a subscriber's
    ///     ``Subscriber/maximumUpdateValueLength`` are truncated by CoreBluetooth; fragment
    ///     larger payloads yourself.
    ///   - characteristic: The characteristic to notify on. Must have been added via
    ///     ``add(_:)`` and declare `.notify` or `.indicate`.
    ///   - centrals: The specific subscribers to notify, or `nil` (the default) for every
    ///     currently-subscribed central.
    /// - Throws: ``BLESwiftError/stopped`` if this host is stopped (including mid-wait);
    ///   ``BLESwiftError/operationCancelled`` if the calling `Task` is cancelled.
    public func updateValue(
        _ value: Data,
        for characteristic: CharacteristicIdentifier,
        onSubscribed centrals: [Subscriber]? = nil
    ) async throws {
        while true {
            guard let manager else { throw BLESwiftError.stopped }
            if manager.updateValue(value, for: characteristic, onSubscribed: centrals) {
                return
            }
            try await awaitReadyToUpdate()
        }
    }

    // MARK: - Public surface: background restoration

    #if os(iOS)
    /// Returns a stream of every ``PeripheralRestorationEvent`` — replaying every event
    /// buffered since this `PeripheralHost` was created to the first consumer, in order.
    /// Events appear here only when ``Configuration/peripheralRestoration`` was set.
    public func restorationEvents() -> AsyncStream<PeripheralRestorationEvent> {
        restorationBroadcaster.stream()
    }
    #else
    /// Internal mirror of the iOS-only public `restorationEvents()` — see the dual-access note
    /// in `RestorationConfiguration.swift`. Reachable off-iOS only via `@testable`.
    func restorationEvents() -> AsyncStream<PeripheralRestorationEvent> {
        restorationBroadcaster.stream()
    }
    #endif

    // MARK: - Event handling

    /// The delegate proxy (or fake) forwards every ``PeripheralHostEvent`` here, already on
    /// this actor's executor via `assumeIsolated`.
    func handle(_ event: PeripheralHostEvent) {
        switch event {
        case .didUpdateState(let state):
            stateBox.withLock { $0 = state }
            stateBroadcaster.yield(state)
            if state != .poweredOn {
                isAdvertisingBox.withLock { $0 = false }
                failPendingOperations(error: BLESwiftError.bluetoothUnavailable)
            }

        case .didStartAdvertising(let error):
            resumePendingStartAdvertising(error: error)

        case .didAddService(let identifier, let error):
            resumePendingAddService(identifier, error: error)

        case .didReceiveRead(let request):
            readRequestBroadcaster.yield(request)

        case .didReceiveWrite(let request):
            writeRequestBroadcaster.yield(request)

        case .didSubscribe(let central, let characteristic):
            subscribersByCharacteristic[characteristic, default: [:]][central.id] = central
            log("Central \(central.id) subscribed to \(characteristic)", level: .info, category: "peripheral")
            subscriptionBroadcaster.yield(.subscribed(central, characteristic: characteristic))

        case .didUnsubscribe(let central, let characteristic):
            subscribersByCharacteristic[characteristic]?.removeValue(forKey: central.id)
            if subscribersByCharacteristic[characteristic]?.isEmpty == true {
                subscribersByCharacteristic.removeValue(forKey: characteristic)
            }
            log("Central \(central.id) unsubscribed from \(characteristic)", level: .info, category: "peripheral")
            subscriptionBroadcaster.yield(.unsubscribed(central, characteristic: characteristic))

        case .readyToUpdateSubscribers:
            resumeReadyWaiters()

        case .willRestoreState(let restored):
            // CoreBluetooth itself re-publishes the GATT database and resumes advertising on
            // the app's behalf; BLESwift only reflects that and surfaces it. `updateValue`
            // post-restoration is handled separately, by the proxy re-registering the live
            // `CBMutableCharacteristic` handles (see `peripheralManager(_:willRestoreState:)`).
            if restored.advertisement != nil {
                isAdvertisingBox.withLock { $0 = true }
            }
            log("Will restore state: \(restored.services.count) service(s), advertising: \(restored.advertisement != nil)", level: .info, category: "restore")
            restorationBroadcaster.yield(.willRestore(restored))
        }
    }

    // MARK: - Continuation resolution (take-then-resume)

    private func resumePendingStartAdvertising(error: NSError?) {
        guard let continuation = pendingStartAdvertising else { return }
        pendingStartAdvertising = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            isAdvertisingBox.withLock { $0 = true }
            continuation.resume(returning: ())
        }
    }

    private func cancelPendingStartAdvertising() {
        guard let continuation = pendingStartAdvertising else { return }
        pendingStartAdvertising = nil
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    private func resumePendingAddService(_ identifier: ServiceIdentifier, error: NSError?) {
        guard let continuation = pendingAddService.removeValue(forKey: identifier) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }

    private func cancelPendingAddService(_ identifier: ServiceIdentifier) {
        guard let continuation = pendingAddService.removeValue(forKey: identifier) else { return }
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Suspends until the next `.readyToUpdateSubscribers`, registering a tokened waiter that
    /// cancels cleanly. Mirrors ``Central``'s `awaitWriteWithoutResponseReadiness`.
    private func awaitReadyToUpdate() async throws {
        let assignedToken = Mutex<UInt64?>(nil)
        try await withCancellableContinuation(
            register: { (continuation: CheckedContinuation<Void, Error>) in
                let token = self.nextReadyWaiterToken
                self.nextReadyWaiterToken += 1
                assignedToken.withLock { $0 = token }
                self.readyWaiters[token] = continuation
            },
            onCancelled: {
                self.queue.async {
                    self.assumeIsolated { host in
                        guard let token = assignedToken.withLock({ $0 }) else { return }
                        host.cancelReadyWaiter(token: token)
                    }
                }
            }
        )
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: ())
        }
    }

    private func cancelReadyWaiter(token: UInt64) {
        guard let continuation = readyWaiters.removeValue(forKey: token) else { return }
        continuation.resume(throwing: BLESwiftError.operationCancelled)
    }

    /// Fails every pending advertise/add-service/readiness continuation with `error` — called
    /// when the radio leaves `.poweredOn` and during ``stopAndExtractState()``.
    private func failPendingOperations(error: Error) {
        if let continuation = pendingStartAdvertising {
            pendingStartAdvertising = nil
            continuation.resume(throwing: error)
        }
        let adds = pendingAddService
        pendingAddService.removeAll()
        for continuation in adds.values {
            continuation.resume(throwing: error)
        }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: error)
        }
    }

    // MARK: - Helpers

    /// The one continuation wrapper for this actor: pairs `withCheckedThrowingContinuation`
    /// with a cancellation handler. `register` populates a continuation slot synchronously
    /// (actor-isolated); `onCancelled` hops back onto ``queue`` and `assumeIsolated` to
    /// take-then-resume it — never a `Task {}`. Mirrors ``Central``'s
    /// `withCancellableGATTContinuation`.
    private func withCancellableContinuation<T: Sendable>(
        register: (CheckedContinuation<T, Error>) -> Void,
        onCancelled: @escaping @Sendable () -> Void
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(register)
        } onCancel: {
            onCancelled()
        }
    }

    /// Writes one log line via the configured `swift-log` logger, tagged with a `category`
    /// metadata key. Mirrors ``Central``'s `log(_:level:category:)`.
    private func log(_ message: @autoclosure () -> Logger.Message, level: Logger.Level, category: String) {
        configuration.logger.log(level: level, message(), metadata: ["category": .string(category)])
    }
}
