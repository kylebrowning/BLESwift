//
//  VirtualPeripheralManagerBackend.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Dispatch
import Foundation
import Synchronization

/// A `PeripheralManaging` served by a ``VirtualRadio`` instead of
/// CoreBluetooth — hand one to `PeripheralHost(backend:queue:)` and the resulting host
/// becomes a virtual device on that radio, reachable from any ``VirtualCentralBackend``
/// sharing it. A real `PeripheralHost` and a real `Central`, talking to each other in one
/// process, with no hardware involved.
///
/// The backend registers exactly one device on the radio, whose
/// ``VirtualDeviceHandler`` forwards every read, write, and subscription change to the
/// host as a `PeripheralHostEvent`; the host's
/// `PeripheralManaging.respond(to:value:error:)` resolves the parked
/// request. Publishing a service, advertising, and notifying are applied to the device
/// through its ``VirtualDeviceHandle``.
///
/// ```swift
/// let radio = VirtualRadio()
/// let queue = DispatchSerialQueue(label: "host")
/// let host = PeripheralHost(backend: VirtualPeripheralManagerBackend(radio: radio, queue: queue), queue: queue)
/// try await host.add(service)
/// try await host.startAdvertising(PeripheralAdvertisement(localName: "Virtual HRM", serviceUUIDs: [service.identifier]))
/// ```
///
/// **Concurrency — queue-confined, not lock-protected.** Identical discipline to
/// ``VirtualCentralBackend``: every stored property is `nonisolated(unsafe)` and touched
/// only on ``queue``, which every `PeripheralManaging` member asserts at entry, and every
/// event is delivered with `queue.async`, never inline. Registration on the radio is
/// asynchronous, so every operation needing the device handle is appended to a serial
/// `Task` chain that begins with that registration — nothing is lost or reordered when a
/// call lands before the device exists.
public final class VirtualPeripheralManagerBackend: PeripheralManaging, Sendable {

    /// The queue every method and event delivery is confined to.
    public let queue: DispatchSerialQueue

    /// The identifier the registered device is reachable at — the peripheral identifier
    /// every ``VirtualCentralBackend`` reports for this host.
    public let identifier: UUID

    private let radio: VirtualRadio

    /// The device handler parking this host's in-flight requests.
    private let handler: VirtualHostedDeviceHandler

    /// The serial chain of radio work, rooted in the device's registration and carrying the
    /// resulting handle forward. `nil` once the device has been removed.
    nonisolated(unsafe) private var _work: Task<VirtualDeviceHandle?, Never>!

    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _announcedState = false
    nonisolated(unsafe) private var _isAdvertising = false
    nonisolated(unsafe) private var _services: [GATTService] = []

    /// An off-queue-readable mirror of `_eventHandler != nil`. The device handler consults it
    /// before parking a request: with no handler attached, nothing would ever answer, so the
    /// request is refused with ``BLESwiftCore/ATTError/unlikelyError`` instead of hanging.
    private let handlerAttached = Mutex<Bool>(false)

    /// Whether an ``eventHandler`` is currently attached. Readable from any context.
    private var isHandlerAttached: Bool {
        handlerAttached.withLock { $0 }
    }

    /// The authorization status this backend reports: always `.allowedAlways`.
    ///
    /// Constant, not settable — a virtual radio is never gated by the system's Bluetooth
    /// permission, and a `static` setter would be process-wide state no one backend owns.
    /// A test that needs a denied backend uses `BLESwiftTestSupport`'s fakes, whose
    /// `bluetoothAuthorization` is scripted for exactly that.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// Creates a backend that hosts one device on `radio`, confined to `queue`.
    ///
    /// The device is registered *not* advertising, with an empty GATT database — exactly
    /// the state a freshly created `CBPeripheralManager` is in. ``radioState`` is
    /// `CentralState.poweredOn` from construction; the matching
    /// `didUpdateState` is delivered once, when a non-`nil` ``eventHandler`` is first
    /// attached, mirroring CoreBluetooth's delegate-only state reporting.
    ///
    /// - Parameters:
    ///   - radio: The radio to host this peripheral on.
    ///   - queue: The queue every method and event delivery is confined to — the same queue
    ///     the owning `PeripheralHost` is constructed with.
    ///   - identifier: The identifier to register the device under. Defaults to a fresh
    ///     `UUID`.
    ///   - name: The device name centrals see on discovery and connection. Defaults to
    ///     `nil`; ``startAdvertising(_:)`` supplies the advertised local name separately.
    public convenience init(radio: VirtualRadio, queue: DispatchSerialQueue, identifier: UUID = UUID(), name: String? = nil) {
        self.init(radio: radio, queue: queue, identifier: identifier, name: name, attTimeout: VirtualRadio.attTimeout)
    }

    /// Creates a backend whose parked requests time out after `attTimeout` — the designated
    /// initializer, for tests that cannot wait ``VirtualRadio/attTimeout`` for a host that
    /// never answers.
    ///
    /// - Parameters:
    ///   - radio: The radio to host this peripheral on.
    ///   - queue: The queue every method and event delivery is confined to.
    ///   - identifier: The identifier to register the device under.
    ///   - name: The device name centrals see on discovery and connection.
    ///   - attTimeout: How long a request parked for the host waits for its answer before it
    ///     is refused with ``BLESwiftCore/ATTError/unlikelyError``.
    package init(
        radio: VirtualRadio,
        queue: DispatchSerialQueue,
        identifier: UUID = UUID(),
        name: String? = nil,
        attTimeout: Duration
    ) {
        self.radio = radio
        self.queue = queue
        self.identifier = identifier
        self.handler = VirtualHostedDeviceHandler(attTimeout: attTimeout)

        let device = VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: identifier,
                name: name,
                advertisement: AdvertisementData(localName: name, isConnectable: true),
                services: []
            ),
            handler: handler
        )
        // Weak, so the radio's registration never keeps this backend alive; the strong
        // reference the hop takes lasts only as long as the delivery itself. The `Bool`
        // reports whether the event reached an attached handler — a request nobody is
        // listening for is refused rather than parked forever.
        let sink: @Sendable (PeripheralHostEvent) -> Bool = { [weak self] event in
            guard let self, self.isHandlerAttached else { return false }
            self.queue.async { self.deliver(event) }
            return true
        }
        // Attaching the sink *before* registering is what guarantees no request can reach
        // the handler before it knows where to forward it.
        _work = Task { [radio, handler] in
            await handler.attach(sink)
            return await radio.register(device, advertising: false)
        }
    }

    /// Removes the hosted device, disconnecting any central still attached to it.
    ///
    /// Reading `_work` off-queue is safe here: `deinit` runs only once every reference is
    /// gone, and every queued delivery holds one.
    deinit {
        let work = _work
        let handler = self.handler
        Task {
            await handler.failPendingRequests()
            await work?.value?.remove()
        }
    }

    // MARK: - Internals

    /// Delivers `event` to ``eventHandler``. Must be called on ``queue``.
    private func deliver(_ event: PeripheralHostEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventHandler?(event)
    }

    /// Delivers `event` on ``queue`` from any context.
    private func deliverOffQueue(_ event: PeripheralHostEvent) {
        queue.async { [self] in deliver(event) }
    }

    /// Appends `body` to the serial chain of radio work, so it runs after the device's
    /// registration and after every operation queued before it. Must be called on ``queue``.
    ///
    /// - Parameters:
    ///   - body: The radio work to run, given the registered device's handle.
    ///   - ifRemoved: Run instead of `body` when the hosted device is already gone, so an
    ///     operation awaiting a completion event is failed rather than left waiting forever.
    private func enqueue(
        _ body: @escaping @Sendable (VirtualDeviceHandle) async -> Void,
        ifRemoved: (@Sendable () -> Void)? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = _work
        _work = Task {
            guard let handle = await previous?.value else {
                ifRemoved?()
                return nil
            }
            await body(handle)
            return handle
        }
    }

    /// Removes the hosted device and ends the chain, so later operations are no-ops. Must be
    /// called on ``queue``.
    private func removeDevice() {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = _work
        _work = Task { [handler] in
            await handler.failPendingRequests()
            await previous?.value?.remove()
            return nil
        }
    }

    // MARK: - PeripheralManaging

    /// Receives every `PeripheralHostEvent` this backend produces, on
    /// ``queue``. The first non-`nil` attachment also triggers the one-shot
    /// `didUpdateState(.poweredOn)`; setting it back to `nil` removes the hosted device from
    /// the radio, disconnecting any central attached to it with
    /// ``VirtualRadio/deviceRemovedError``.
    public var eventHandler: ((PeripheralHostEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
            handlerAttached.withLock { $0 = newValue != nil }
            guard newValue != nil else {
                removeDevice()
                return
            }
            guard !_announcedState else { return }
            _announcedState = true
            queue.async { [self] in deliver(.didUpdateState(.poweredOn)) }
        }
    }

    /// Always `CentralState.poweredOn` — a virtual radio is never off.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return .poweredOn
    }

    /// Whether the hosted device is currently advertising on the radio.
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _isAdvertising
    }

    /// Starts advertising: the device's advertisement becomes `advertisement`'s local name
    /// and service UUIDs (always connectable), and it begins matching scans.
    /// `didStartAdvertising(error:)` — always successful, a virtual radio having nothing to
    /// refuse — is delivered once the radio has applied the change.
    public func startAdvertising(_ advertisement: PeripheralAdvertisement) {
        dispatchPrecondition(condition: .onQueue(queue))
        let data = AdvertisementData(
            localName: advertisement.localName,
            serviceUUIDs: advertisement.serviceUUIDs,
            isConnectable: true
        )
        enqueue({ [weak self] handle in
            await handle.setAdvertisement(data)
            await handle.setAdvertising(true)
            guard let self else { return }
            self.queue.async {
                self._isAdvertising = true
                self.deliver(.didStartAdvertising(error: nil))
            }
        }, ifRemoved: { [weak self] in
            self?.deliverOffQueue(.didStartAdvertising(error: Self.removedError))
        })
    }

    /// Stops advertising. Idempotent, and reports no completion of its own — exactly like
    /// `CBPeripheralManager.stopAdvertising()`.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        _isAdvertising = false
        enqueue { handle in
            await handle.setAdvertising(false)
        }
    }

    /// Publishes `service` into the hosted device's GATT database, delivering
    /// `didAddService(_:error:)` once the radio has applied it. Re-adding a service already
    /// published fails with `BLESwiftProvider` code 4, mirroring CoreBluetooth's refusal to
    /// publish the same service twice.
    public func add(_ service: GATTService) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !_services.contains(where: { $0.identifier == service.identifier }) else {
            queue.async { [self] in deliver(.didAddService(service.identifier, error: Self.duplicateServiceError)) }
            return
        }
        _services.append(service)
        let services = _services
        enqueue({ [weak self] handle in
            await handle.setServices(services)
            self?.deliverOffQueue(.didAddService(service.identifier, error: nil))
        }, ifRemoved: { [weak self] in
            self?.deliverOffQueue(.didAddService(service.identifier, error: Self.removedError))
        })
    }

    /// Empties the hosted device's GATT database.
    public func removeAllHostedServices() {
        dispatchPrecondition(condition: .onQueue(queue))
        _services.removeAll()
        enqueue { handle in
            await handle.setServices([])
        }
    }

    /// Resolves the parked read or write request `token` identifies: `error` fails it with
    /// that ATT error, otherwise it succeeds — with `value` (or empty `Data`) for a read.
    /// A no-op if `token` is unknown, already answered, or belongs to a removed device.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        Task { [handler] in
            await handler.respond(to: token, value: value, error: error)
        }
    }

    /// Pushes `value` to every central subscribed to `characteristic` (or just `centrals`).
    ///
    /// - Returns: Always `true` — the virtual radio has no transmit queue to fill, so it
    ///   never applies back-pressure.
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { handle in
            await handle.notify(value, for: characteristic, to: centrals)
        }
        return true
    }

    /// Detaches ``eventHandler`` **without** removing the hosted device — the one state the
    /// public setter cannot produce, and the one a request must be refused in rather than
    /// parked. Test-only; production code sets `eventHandler = nil`, which also removes the
    /// device.
    package func detachEventHandlerForTesting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                _eventHandler = nil
                handlerAttached.withLock { $0 = false }
                continuation.resume()
            }
        }
    }

    /// The error an operation queued after the hosted device was removed reports, instead of
    /// leaving its caller waiting for a completion that can never arrive.
    private static var removedError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "The backend's hosted device has been removed."]
        )
    }

    /// The error a repeat ``add(_:)`` of an already-published service reports.
    private static var duplicateServiceError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "That service is already published in the hosted GATT database."]
        )
    }
}

/// The ``VirtualDeviceHandler`` behind a ``VirtualPeripheralManagerBackend``: it turns each
/// piece of GATT traffic the radio hands it into a ``BLESwiftCore/PeripheralHostEvent`` for
/// the `PeripheralHost`, and parks a continuation until the host answers.
///
/// One continuation per ``BLESwiftCore/RequestToken``, in two maps — a read and a write
/// success are both answered as `value: nil, error: nil`, so the request's kind is
/// recovered from which map the token is in, never from the response's shape.
///
/// **No request parks forever.** Each one is bounded by ``VirtualRadio/attTimeout``: a host
/// that never answers has its request refused with
/// ``BLESwiftCore/ATTError/unlikelyError``, which releases the central's call and every
/// operation queued behind it on that remote. A response arriving after that is a no-op,
/// exactly as one for any other unknown token is.
actor VirtualHostedDeviceHandler: VirtualDeviceHandler {

    /// Delivers events to the owning backend's `eventHandler`, hopping onto its queue, and
    /// reports whether a handler was attached to receive them.
    private var sink: (@Sendable (PeripheralHostEvent) -> Bool)?

    private var pendingReads: [RequestToken: CheckedContinuation<Result<Data, ATTError>, Never>] = [:]
    private var pendingWrites: [RequestToken: CheckedContinuation<Result<Void, ATTError>, Never>] = [:]

    /// How long a parked request waits for the host's answer before it is refused.
    private let attTimeout: Duration

    /// The countdown running against each parked request, cancelled the moment that request
    /// is settled by any other route.
    private var timeouts: [RequestToken: Task<Void, Never>] = [:]

    /// Creates a handler whose parked requests time out after `attTimeout`.
    ///
    /// - Parameter attTimeout: The ATT transaction timeout. Defaults to
    ///   ``VirtualRadio/attTimeout``; tests shorten it.
    init(attTimeout: Duration = VirtualRadio.attTimeout) {
        self.attTimeout = attTimeout
    }

    /// Attaches the event sink, before the device is registered.
    func attach(_ sink: @escaping @Sendable (PeripheralHostEvent) -> Bool) {
        self.sink = sink
    }

    /// Detaches the sink and fails every parked request with
    /// ``BLESwiftCore/ATTError/unlikelyError`` — nothing is left to answer them once the
    /// host is gone.
    func failPendingRequests() {
        sink = nil
        for countdown in timeouts.values { countdown.cancel() }
        timeouts.removeAll()
        let reads = pendingReads
        pendingReads.removeAll()
        for continuation in reads.values { continuation.resume(returning: .failure(.unlikelyError)) }
        let writes = pendingWrites
        pendingWrites.removeAll()
        for continuation in writes.values { continuation.resume(returning: .failure(.unlikelyError)) }
    }

    /// Answers the request `token` identifies, if it is still parked. A response that arrives
    /// after the request timed out is a no-op, as the seam's contract for an unknown token
    /// already says.
    func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        timeouts.removeValue(forKey: token)?.cancel()
        if let continuation = pendingReads.removeValue(forKey: token) {
            continuation.resume(returning: error.map { .failure($0) } ?? .success(value ?? Data()))
        } else if let continuation = pendingWrites.removeValue(forKey: token) {
            continuation.resume(returning: error.map { .failure($0) } ?? .success(()))
        }
    }

    /// Surfaces the read to the host as `didReceiveRead` and suspends until it responds.
    func read(
        _ characteristic: CharacteristicIdentifier,
        offset: Int,
        from central: Subscriber
    ) async -> Result<Data, ATTError> {
        guard let sink else { return .failure(.unlikelyError) }
        let token = RequestToken()
        return await withCheckedContinuation { continuation in
            pendingReads[token] = continuation
            startTimeout(for: token)
            let event = PeripheralHostEvent.didReceiveRead(
                ReadRequest(token: token, central: central, characteristic: characteristic, offset: offset)
            )
            if !sink(event) { fail(token) }
        }
    }

    /// Surfaces the batch to the host as `didReceiveWrite` and suspends until it responds.
    /// One response settles the whole batch, exactly as CoreBluetooth requires.
    func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
        guard let sink else { return .failure(.unlikelyError) }
        let token = RequestToken()
        return await withCheckedContinuation { continuation in
            pendingWrites[token] = continuation
            startTimeout(for: token)
            if !sink(.didReceiveWrite(WriteRequest(token: token, entries: entries))) { fail(token) }
        }
    }

    /// Starts the ATT transaction countdown for a freshly parked request: a host that never
    /// answers refuses it after ``attTimeout`` rather than leaving its caller — and every
    /// operation queued behind it on that remote — suspended forever.
    private func startTimeout(for token: RequestToken) {
        timeouts[token] = Task { [attTimeout] in
            try? await Task.sleep(for: attTimeout)
            guard !Task.isCancelled else { return }
            fail(token)
        }
    }

    /// Refuses the parked request `token` identifies with
    /// ``BLESwiftCore/ATTError/unlikelyError`` — the answer for a request no attached handler
    /// ever saw, and for one the host let time out.
    private func fail(_ token: RequestToken) {
        timeouts.removeValue(forKey: token)?.cancel()
        if let continuation = pendingReads.removeValue(forKey: token) {
            continuation.resume(returning: .failure(.unlikelyError))
        } else if let continuation = pendingWrites.removeValue(forKey: token) {
            continuation.resume(returning: .failure(.unlikelyError))
        }
    }

    /// Reports the change to the host as `didSubscribe`/`didUnsubscribe`. Nothing is parked:
    /// a subscription change needs no answer.
    func subscriptionChanged(
        _ characteristic: CharacteristicIdentifier,
        central: Subscriber,
        isSubscribed: Bool
    ) async {
        _ = sink?(isSubscribed
            ? .didSubscribe(central: central, characteristic: characteristic)
            : .didUnsubscribe(central: central, characteristic: characteristic))
    }
}
#endif
