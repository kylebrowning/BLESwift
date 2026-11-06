//
//  PeripheralHost.swift
//  BLESwift
//

// The peripheral role compiles only for iOS and macOS. `CBPeripheralManager`'s designated
// initializer is `API_UNAVAILABLE` on watchOS and tvOS, and `CBMutableService` and
// `CBMutableCharacteristic` construction is unavailable on visionOS. The central role is not
// affected.
#if os(iOS) || os(macOS)

// `@preconcurrency`: `CBPeripheralManager` is not `Sendable`. `stopAndExtractState()` gives it
// to a caller outside this actor's isolation domain. This one-time ownership transfer
// type-checks only under `@preconcurrency`. `Central` has the same rationale.
import BLESwiftCore
@preconcurrency import CoreBluetooth
import Dispatch
import Foundation
import Logging
import BLESwiftCompat16
import BLESwiftCompat17

/// The peripheral-role entry point of BLESwift: an actor that wraps a single
/// `CBPeripheralManager`.
///
/// ``Central`` is the *central* role. `PeripheralHost` is the *peripheral* role. It hosts and
/// advertises a GATT database, and answers reads, writes, and subscriptions from remote
/// centrals. Its architecture mirrors ``Central``. The actor's isolation is tied to the
/// `DispatchQueue` on which its `CBPeripheralManager` delivers delegate callbacks (see
/// ``unownedExecutor``), so each proxy callback already runs on the actor's executor.
///
/// - Important: The peripheral role is available only on iOS and macOS. `PeripheralHost` does
///   not exist on watchOS or tvOS, which cannot create a `CBPeripheralManager`, or on
///   visionOS, which cannot build a GATT database.
///
/// - Note: Subscribe to ``readRequests()``, ``writeRequests()``, and
///   ``subscriptionEvents()`` **before** you call ``startAdvertising(_:)``. Those streams do
///   not replay.
public actor PeripheralHost {

    /// The serial `DispatchQueue` behind ``unownedExecutor`` and the `CBPeripheralManager`
    /// delegate callbacks. It must be serial (`DispatchQueue(label:)` is). From iOS 17 and the
    /// matching platform versions, a concurrent queue is rejected. Earlier, the behavior is
    /// undefined.
    nonisolated let queue: DispatchQueue

    /// Binds `PeripheralHost` to ``queue``. From iOS 17 and the matching platform versions, it
    /// uses `DispatchSerialQueue`'s executor. Earlier, it uses
    /// `BLESwiftCompat16.SerialQueueExecutor`.
    nonisolated let executor: QueueExecutor

    /// Ties this actor's isolation to ``queue`` (SE-0424 custom executors), as
    /// ``Central/unownedExecutor`` does. It is `public` only because the public `Actor`
    /// protocol requires it. Do not use it directly.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// The CoreBluetooth shim that this host drives. It is an optional `var`, so
    /// ``stopAndExtractState()`` can set it to `nil` when it gives the `CBPeripheralManager`
    /// to the caller. A sound non-`Sendable` ownership transfer needs this (see `manager` of
    /// ``Central``).
    private var manager: (any PeripheralManaging)?

    /// This host's `CBPeripheralManagerDelegate`, held strongly. It is non-`nil` only for
    /// ``init(configuration:)``.
    private let proxy: PeripheralManagerDelegateProxy?

    /// The configuration that created this host. It supplies the logger and the power-alert
    /// option.
    private let configuration: Configuration

    /// Backs the nonisolated ``state`` snapshot. It is a `Mutex` and not actor-isolated
    /// storage, so ``state`` reads without `await` from any isolation domain, as
    /// ``Central/state`` does. ``handle(_:)`` is the only writer.
    private let stateBox = Mutex<CentralState>(.unknown)

    /// Multicasts each ``CentralState`` transition to ``stateEvents()`` subscribers. It
    /// replays the latest value to late subscribers.
    private let stateBroadcaster = Broadcaster<CentralState>(replay: .latest)

    /// Backs the nonisolated ``isAdvertising`` snapshot.
    private let isAdvertisingBox = Mutex<Bool>(false)

    /// The single in-flight continuation of ``startAdvertising(_:)``. `.didStartAdvertising`
    /// resolves it. At most one advertise start can be pending.
    private var pendingStartAdvertising: CheckedContinuation<Void, Error>?

    /// In-flight continuations of ``add(_:)``, by service. `.didAddService` for that identifier
    /// resolves each one.
    private var pendingAddService: [ServiceIdentifier: CheckedContinuation<Void, Error>] = [:]

    /// Multicasts each remote central's read request to ``readRequests()`` subscribers.
    private let readRequestBroadcaster = Broadcaster<ReadRequest>(replay: .none)

    /// Multicasts each remote central's write-request batch to ``writeRequests()`` subscribers.
    private let writeRequestBroadcaster = Broadcaster<WriteRequest>(replay: .none)

    /// Multicasts each subscribe and unsubscribe to ``subscriptionEvents()`` subscribers.
    private let subscriptionBroadcaster = Broadcaster<SubscriptionEvent>(replay: .none)

    /// The subscribed centrals of each hosted characteristic, by characteristic and then
    /// `Subscriber.id`. `.didSubscribe` and `.didUnsubscribe` update it. ``subscribers(for:)``
    /// reports it.
    private var subscribersByCharacteristic: [CharacteristicIdentifier: [UUID: Subscriber]] = [:]

    /// Waiters for back-pressure readiness (see ``updateValue(_:for:onSubscribed:)``).
    /// `.readyToUpdateSubscribers` resumes all of them. Each has a token, so a cancelled waiter
    /// removes exactly itself. `pendingWriteWithoutResponseReady` of ``Central`` has the same
    /// shape.
    private var readyWaiters: [UInt64: CheckedContinuation<Void, Error>] = [:]

    /// Allocator for the increasing tokens of ``readyWaiters``.
    private var nextReadyWaiterToken: UInt64 = 0

    // MARK: - Background restoration state

    /// Multicasts each ``PeripheralRestorationEvent`` with `.allUntilFirstConsumer` replay.
    /// Restoration happens at launch, typically before any consumer starts, so the events are
    /// buffered and replayed to the first ``restorationEvents()`` consumer. It mirrors
    /// `restorationBroadcaster` of ``Central``.
    private let restorationBroadcaster = Broadcaster<PeripheralRestorationEvent>(replay: .allUntilFirstConsumer)

    /// Creates a `PeripheralHost` and its underlying `CBPeripheralManager` synchronously, on a
    /// new dedicated `DispatchQueue`. The creation is not deferred behind an async `start()`,
    /// so restoration registers its restore identifier before `willRestoreState` can arrive.
    /// See ``Central/init(configuration:)``.
    ///
    /// - Parameter configuration: Start-time options. The default is `Configuration()`.
    public init(configuration: Configuration = Configuration()) {
        let queue = DispatchQueue(label: "com.bleswift.PeripheralHost")
        self.queue = queue
        self.executor = QueueExecutor(queue: queue)
        self.configuration = configuration

        // A registered backend (see `BackendRegistry`) replaces CoreBluetooth completely.
        if let factory = BackendRegistry.peripheralManagerFactory {
            let backend = factory(queue)
            self.manager = backend
            self.proxy = nil
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

        let proxy = PeripheralManagerDelegateProxy()
        self.proxy = proxy

        #if os(iOS)
        var options: [String: Any] = [
            CBPeripheralManagerOptionShowPowerAlertKey: configuration.showPowerAlert
        ]
        // CoreBluetooth requires this to differ from any `Central` restore identifier.
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

        // Make the same proxy reachable through the associated object, so the conformance's
        // `respond`, `updateValue`, and `add` can recover the CoreBluetooth objects.
        manager.bleSwiftRegisterProxy(proxy)

        // Set the proxy's handler directly. The `eventHandler` associated-object path would
        // create a second proxy. `Central.init` does the same.
        proxy.handler = { [weak self] event in
            guard let self else { return }
            self.assumeIsolated(onQueue: self.queue) { $0.handle(event) }
        }
    }

    /// Creates a `PeripheralHost` that drives a custom backend, for example a scriptable fake
    /// instead of a real `CBPeripheralManager`. Production apps use ``init(configuration:)``.
    ///
    /// - Important: `queue` **must be the exact `DispatchQueue` instance** that `backend` uses
    ///   for its event deliveries. A mismatch causes an `assumeIsolated` trap the first time
    ///   an event arrives off the queue.
    ///
    /// - Important: **Retention.** The closure that this initializer installs on
    ///   `backend.eventHandler` captures `self` strongly, and this host holds `backend`. This
    ///   deliberate reference cycle keeps the host alive as long as `backend` lives. To tear
    ///   down deterministically, set `backend.eventHandler = nil`.
    ///
    /// - Parameters:
    ///   - backend: The ``PeripheralManaging`` conformance to drive.
    ///   - queue: The serial `DispatchQueue` that confines `backend`'s events.
    ///   - configuration: Start-time options. The default is `Configuration()`.
    public init(
        backend: any PeripheralManaging,
        queue: DispatchQueue,
        configuration: Configuration = Configuration()
    ) {
        self.queue = queue
        self.executor = QueueExecutor(queue: queue)
        self.configuration = configuration
        self.manager = backend
        self.proxy = nil

        // `queue.sync` is safe, because nothing else runs on `queue` during init. The strong
        // capture of `self` makes the deliberate cycle that the documentation describes.
        queue.sync {
            backend.eventHandler = { event in
                self.assumeIsolated(onQueue: self.queue) { $0.handle(event) }
            }
        }
    }

    /// Stops this host. It detaches the delegate of the underlying `CBPeripheralManager` and
    /// gives the manager to the caller, so other code can adopt it.
    ///
    /// Before it returns, it fails every pending advertise, add-service, and readiness
    /// continuation with ``BLESwiftError/stopped`` and finishes the request streams.
    ///
    /// - Returns: The underlying `CBPeripheralManager`.
    /// - Throws: ``BLESwiftError/stopped`` if this host is already stopped, or if a custom
    ///   backend (not a real `CBPeripheralManager`) created it.
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

        // Release this actor's reference before the method returns `cbManager`. See ``manager``.
        manager = nil
        cbManager.stopAdvertising()
        cbManager.delegate = nil
        proxy?.handler = nil

        return cbManager
    }

    // MARK: - Public surface: state

    /// The current state of the Bluetooth radio, as a synchronous snapshot. You can read it
    /// without `await` from any isolation domain.
    public nonisolated var state: CentralState {
        stateBox.withLock { $0 }
    }

    /// The current Bluetooth authorization status of the app.
    ///
    /// - Note: It returns `.notDetermined` after ``stopAndExtractState()``, because this host
    ///   no longer owns a manager.
    public var authorization: BluetoothAuthorization {
        guard let manager else { return .notDetermined }
        return type(of: manager).bluetoothAuthorization
    }

    /// Whether this host advertises, as a synchronous snapshot.
    public nonisolated var isAdvertising: Bool {
        isAdvertisingBox.withLock { $0 }
    }

    /// Returns a multicast stream of every ``CentralState`` transition. It replays the latest
    /// state to late subscribers.
    public func stateEvents() -> AsyncStream<CentralState> {
        stateBroadcaster.stream()
    }

    // MARK: - Public surface: GATT database

    /// Publishes a service and its characteristics into the local GATT database. It waits for
    /// CoreBluetooth's confirmation.
    ///
    /// - Parameter service: The service to publish.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/stopped`` if this host is stopped.
    ///   - ``BLESwiftError/operationCancelled`` if the calling `Task` is cancelled.
    ///   - The error that CoreBluetooth reports if it rejects the service.
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
                    self.assumeIsolated(onQueue: self.queue) { host in
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

    /// Starts to advertise. It waits for `peripheralManagerDidStartAdvertising`.
    ///
    /// It returns immediately if the host already advertises. Only one advertise start can be
    /// pending.
    ///
    /// - Parameter advertisement: The local name and service UUIDs to advertise.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/stopped`` if this host is stopped.
    ///   - ``BLESwiftError/invalidArgument(_:)`` if another ``startAdvertising(_:)`` waits for
    ///     its completion.
    ///   - ``BLESwiftError/operationCancelled`` if the calling `Task` is cancelled.
    ///   - The error that CoreBluetooth reports if advertising fails to start.
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
                    self.assumeIsolated(onQueue: self.queue) { host in
                        host.cancelPendingStartAdvertising()
                    }
                }
            }
        )
    }

    /// Stops advertising. It is idempotent.
    public func stopAdvertising() {
        manager?.stopAdvertising()
        isAdvertisingBox.withLock { $0 = false }
    }

    // MARK: - Public surface: request streams

    /// Returns a multicast stream of every read request from a remote central. Answer each
    /// with ``respond(to:with:)-(ReadRequest,_)``. It does not replay. Subscribe before you
    /// advertise.
    public func readRequests() -> AsyncStream<ReadRequest> {
        readRequestBroadcaster.stream()
    }

    /// Returns a multicast stream of every write-request batch from a remote central. Answer
    /// each with ``respond(to:with:)-(WriteRequest,_)``. It does not replay. Subscribe before
    /// you advertise.
    public func writeRequests() -> AsyncStream<WriteRequest> {
        writeRequestBroadcaster.stream()
    }

    /// Returns a multicast stream of every subscribe and unsubscribe from a remote central. It
    /// does not replay. Subscribe before you advertise. For the current set, see
    /// ``subscribers(for:)``.
    public func subscriptionEvents() -> AsyncStream<SubscriptionEvent> {
        subscriptionBroadcaster.stream()
    }

    /// The centrals that are subscribed to `characteristic`, sorted by identifier.
    public func subscribers(for characteristic: CharacteristicIdentifier) -> [Subscriber] {
        (subscribersByCharacteristic[characteristic]?.values).map { subscribers in
            subscribers.sorted { $0.id.uuidString < $1.id.uuidString }
        } ?? []
    }

    // MARK: - Public surface: respond

    /// Answers a read request from a remote central. Answer each request exactly once. A second
    /// response for the same request does nothing.
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

    /// Answers a write-request batch from a remote central. A single call acknowledges the
    /// whole batch. Answer each batch exactly once.
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

    /// Pushes `value` as a notification or indication for `characteristic`. If the transmit
    /// queue is full, it waits for capacity.
    ///
    /// This mirrors the central side's back-pressure pattern. When CoreBluetooth's
    /// `updateValue` returns `false`, the transmit queue is full. The method then suspends
    /// until `peripheralManagerIsReady(toUpdateSubscribers:)` and tries again.
    ///
    /// - Parameters:
    ///   - value: The bytes to notify. CoreBluetooth truncates a value that is longer than a
    ///     subscriber's ``Subscriber/maximumUpdateValueLength``. Fragment larger payloads
    ///     yourself.
    ///   - characteristic: The characteristic on which to notify. Add it with ``add(_:)``. It
    ///     must declare `.notify` or `.indicate`.
    ///   - centrals: The subscribers to notify. The default `nil` notifies every subscribed
    ///     central.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/stopped`` if this host is stopped, even during the wait.
    ///   - ``BLESwiftError/operationCancelled`` if the calling `Task` is cancelled.
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
    /// Returns a stream of every ``PeripheralRestorationEvent``. It replays to the first
    /// consumer, in order, every event since this `PeripheralHost` was created. Events appear
    /// only when ``Configuration/peripheralRestoration`` is set.
    public func restorationEvents() -> AsyncStream<PeripheralRestorationEvent> {
        restorationBroadcaster.stream()
    }
    #else
    /// Internal mirror of the iOS-only public `restorationEvents()`. See the dual-access note
    /// in `RestorationConfiguration.swift`. On other platforms, only `@testable` can reach it.
    func restorationEvents() -> AsyncStream<PeripheralRestorationEvent> {
        restorationBroadcaster.stream()
    }
    #endif

    // MARK: - Event handling

    /// The delegate proxy (or fake) forwards every ``PeripheralHostEvent`` here, already on this
    /// actor's executor through `assumeIsolated`.
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
            // CoreBluetooth itself publishes the GATT database again and resumes advertising.
            // BLESwift only mirrors that state. For `updateValue` after restoration, the proxy
            // registers the live `CBMutableCharacteristic` handles again (see
            // `peripheralManager(_:willRestoreState:)`).
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

    /// Suspends until the next `.readyToUpdateSubscribers`. The waiter has a token, so
    /// cancellation removes it cleanly. It mirrors `awaitWriteWithoutResponseReadiness` of
    /// ``Central``.
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
                    self.assumeIsolated(onQueue: self.queue) { host in
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

    /// Fails every pending advertise, add-service, and readiness continuation with `error`.
    /// It runs when the radio leaves `.poweredOn` and during ``stopAndExtractState()``.
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

    /// The one continuation wrapper for this actor. It pairs `withCheckedThrowingContinuation`
    /// with a cancellation handler. `register` fills a continuation slot synchronously, on the
    /// actor. `onCancelled` hops onto ``queue``, takes the continuation with `assumeIsolated`,
    /// and resumes it. It never uses a `Task {}`. It mirrors `withCancellableGATTContinuation`
    /// of ``Central``.
    private func withCancellableContinuation<T: Sendable>(
        register: (CheckedContinuation<T, Error>) -> Void,
        onCancelled: @escaping @Sendable () -> Void
    ) async throws -> T {
        // Explicit isolation pin for Swift 6.3 and earlier. See
        // `Central.withCancellableGATTContinuation`.
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

    /// Writes one log line to the configured `swift-log` logger, with a `category` metadata
    /// key. It mirrors `log(_:level:category:)` of ``Central``.
    private func log(_ message: @autoclosure () -> Logger.Message, level: Logger.Level, category: String) {
        configuration.logger.log(level: level, message(), metadata: ["category": .string(category)])
    }
}

#endif
