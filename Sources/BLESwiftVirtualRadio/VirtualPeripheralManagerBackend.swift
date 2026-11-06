//
//  VirtualPeripheralManagerBackend.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import Dispatch
import Foundation
import BLESwiftCompat17

/// A peripheral-role backend that hosts its own device on a ``VirtualRadio`` and can take the
/// device back off the radio on demand.
///
/// Setting a backend's event handler to `nil` is a detach that a later attach can reverse. The
/// composites document it so and re-install every child from it. Thus the final teardown asks for
/// the removal outright, through whichever backend a session received.
package protocol HostedDeviceRemoving {

    /// Takes the hosted device off the radio. Call this method on the queue of the backend.
    func removeHostedDevice()
}


/// A `PeripheralManaging` that a ``VirtualRadio`` serves instead of CoreBluetooth. Give one to
/// `PeripheralHost(backend:queue:)`. The host becomes a virtual device on that radio, and any
/// ``VirtualCentralBackend`` on the radio can reach it. No hardware is needed.
///
/// The backend registers exactly one device. The device's ``VirtualDeviceHandler`` forwards every
/// read, write, and subscription change to the host as a `PeripheralHostEvent`. The host's
/// `PeripheralManaging.respond(to:value:error:)` resolves the parked request.
///
/// ```swift
/// let radio = VirtualRadio()
/// let queue = DispatchQueue(label: "host")
/// let host = PeripheralHost(backend: VirtualPeripheralManagerBackend(radio: radio, queue: queue), queue: queue)
/// try await host.add(service)
/// try await host.startAdvertising(PeripheralAdvertisement(localName: "Virtual HRM", serviceUUIDs: [service.identifier]))
/// ```
///
/// **Concurrency:** ``queue`` confines the state. A lock does not protect it, as in
/// ``VirtualCentralBackend``.
///
/// - Every stored property is `nonisolated(unsafe)`. Code touches it only on ``queue``.
/// - Every `PeripheralManaging` member asserts this at entry.
/// - The backend delivers every event with `queue.async`, never inline.
///
/// Registration on the radio is asynchronous. The backend runs every operation that needs the
/// device handle on a serial `Task` chain that begins with the registration. A call before the
/// device exists is neither lost nor reordered.
public final class VirtualPeripheralManagerBackend: PeripheralManaging, HostedDeviceRemoving, Sendable {

    /// The queue that confines every method and every event delivery.
    public let queue: DispatchQueue

    /// The registered device's identifier. Every ``VirtualCentralBackend`` reports it as the
    /// peripheral identifier for this host.
    public let identifier: UUID

    private let radio: VirtualRadio

    /// The device handler that parks the in-flight requests of this host.
    private let handler: VirtualHostedDeviceHandler

    /// The serial chain of radio work, rooted in the device's registration. It carries the
    /// resulting handle forward. The value is `nil` after the device is removed.
    nonisolated(unsafe) private var _work: Task<VirtualDeviceHandle?, Never>!

    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _announcedState = false
    nonisolated(unsafe) private var _isAdvertising = false
    nonisolated(unsafe) private var _services: [GATTService] = []

    /// A mirror of `_eventHandler != nil` that code can read off-queue. The device handler reads it
    /// before it parks a request. If no handler is attached, nothing would answer the request, so
    /// the handler refuses it with ``BLESwiftCore/ATTError/unlikelyError``.
    private let handlerAttached = Mutex<Bool>(false)

    /// Whether an ``eventHandler`` is attached. Readable from any context.
    private var isHandlerAttached: Bool {
        handlerAttached.withLock { $0 }
    }

    /// The authorization status that this backend reports. It is always `.allowedAlways`.
    ///
    /// The value is constant and not settable, because the system's Bluetooth permission never
    /// gates a virtual radio. A test that needs a denied backend uses the fakes of
    /// `BLESwiftTestSupport`, whose `bluetoothAuthorization` is scripted.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// Creates a backend that hosts one device on `radio` and that `queue` confines.
    ///
    /// The backend registers the device as *not* advertising, with an empty GATT database, like a
    /// new `CBPeripheralManager`. ``radioState`` is `CentralState.poweredOn` from construction. The
    /// matching `didUpdateState` arrives once, when code first attaches a non-`nil`
    /// ``eventHandler``.
    ///
    /// - Parameters:
    ///   - radio: The radio to host this peripheral on.
    ///   - queue: The queue that confines every method and event delivery. It must be serial and be
    ///     the queue that the owning `PeripheralHost` uses.
    ///   - identifier: The identifier to register the device under. The default is a new `UUID`.
    ///   - name: The device name that centrals see on discovery and connection. The default is
    ///     `nil`. ``startAdvertising(_:)`` supplies the advertised local name separately.
    public convenience init(radio: VirtualRadio, queue: DispatchQueue, identifier: UUID = UUID(), name: String? = nil) {
        self.init(radio: radio, queue: queue, identifier: identifier, name: name, attTimeout: VirtualRadio.attTimeout, clock: radio.clock)
    }

    /// Creates a backend whose parked requests time out after `attTimeout` on `clock`. This is the
    /// designated initializer. Tests use it to avoid waiting ``VirtualRadio/attTimeout``.
    ///
    /// - Parameters:
    ///   - radio: The radio to host this peripheral on.
    ///   - queue: The queue that confines every method and event delivery.
    ///   - identifier: The identifier to register the device under.
    ///   - name: The device name that centrals see on discovery and connection.
    ///   - attTimeout: How long a parked request waits for the host's answer. After that time, the
    ///     backend refuses it with ``BLESwiftCore/ATTError/unlikelyError``.
    ///   - clock: The clock that the wait runs on. The public initializer passes the radio's clock.
    package init(
        radio: VirtualRadio,
        queue: DispatchQueue,
        identifier: UUID = UUID(),
        name: String? = nil,
        attTimeout: Duration,
        clock: any Clock<Duration>
    ) {
        self.radio = radio
        self.queue = queue
        self.identifier = identifier
        self.handler = VirtualHostedDeviceHandler(attTimeout: attTimeout, clock: clock)

        let device = VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: identifier,
                name: name,
                advertisement: AdvertisementData(localName: name, isConnectable: true),
                services: []
            ),
            handler: handler
        )
        // The reference is weak, so the radio's registration never keeps this backend alive. The
        // hop's strong reference lasts only as long as the delivery. The `Bool` reports whether the
        // event reached an attached handler, so the handler refuses a request that nobody listens
        // for.
        let sink: @Sendable (PeripheralHostEvent) -> Bool = { [weak self] event in
            guard let self, self.isHandlerAttached else { return false }
            self.queue.async { self.deliver(event) }
            return true
        }
        // Attach the sink *before* registering the device, so no request reaches the handler before
        // it knows where to forward it.
        _work = Task { [radio, handler] in
            await handler.attach(sink)
            return await radio.register(device, advertising: false)
        }
    }

    /// Removes the hosted device. It disconnects any central still attached to it.
    ///
    /// It is safe to read `_work` off-queue here. `deinit` runs only after every reference is gone,
    /// and every queued delivery holds one.
    deinit {
        let work = _work
        let handler = self.handler
        Task {
            await handler.failPendingRequests()
            await work?.value?.remove()
        }
    }

    // MARK: - Internals

    /// Delivers `event` to ``eventHandler``. Call this method on ``queue``.
    private func deliver(_ event: PeripheralHostEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventHandler?(event)
    }

    /// Delivers `event` on ``queue`` from any context.
    private func deliverOffQueue(_ event: PeripheralHostEvent) {
        queue.async { [self] in deliver(event) }
    }

    /// Appends `body` to the serial chain of radio work, so it runs after the device's registration
    /// and every earlier operation. Call this method on ``queue``.
    ///
    /// - Parameters:
    ///   - body: The radio work to run. It receives the registered device's handle.
    ///   - ifRemoved: Runs instead of `body` when the hosted device is already gone, so an
    ///     operation that waits for a completion event fails and does not wait forever.
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

    /// Removes the hosted device and ends the chain. Later operations do nothing. Call this method
    /// on ``queue``.
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

    /// Receives every `PeripheralHostEvent` that this backend produces, on ``queue``. The first
    /// non-`nil` attachment also triggers the one-shot `didUpdateState(.poweredOn)`.
    ///
    /// Setting it back to `nil` only *detaches*. The hosted device stays on the radio, and the
    /// backend refuses a request that arrives when nobody listens. If you attach a handler again,
    /// the backend works again. `BLESwiftProvider`'s `CompositePeripheralManager.eventHandler`
    /// relies on this for every child that it clears and re-installs. `removeHostedDevice()` and
    /// `deinit` remove the device.
    public var eventHandler: ((PeripheralHostEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
            handlerAttached.withLock { $0 = newValue != nil }
            guard newValue != nil else { return }
            guard !_announcedState else { return }
            _announcedState = true
            queue.async { [self] in deliver(.didUpdateState(.poweredOn)) }
        }
    }

    /// Takes the hosted device off the radio. It disconnects any attached central with
    /// ``VirtualRadio/deviceRemovedError``. Every later operation does nothing and fails its
    /// completion.
    ///
    /// A session calls this method for an explicit teardown. `deinit` does the same work for a
    /// backend that the code drops. Call this method on ``queue``.
    package func removeHostedDevice() {
        dispatchPrecondition(condition: .onQueue(queue))
        removeDevice()
    }

    /// Always `CentralState.poweredOn`. A virtual radio is never off.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return .poweredOn
    }

    /// Whether the hosted device is advertising on the radio now.
    ///
    /// The value comes from the radio chain. It becomes `true` after the radio applies
    /// ``startAdvertising(_:)``, when the backend delivers `didStartAdvertising`. It becomes
    /// `false` after the radio applies ``stopAdvertising()``. No write that could land out of order
    /// behind either call sets it.
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _isAdvertising
    }

    /// Starts advertising. The device's advertisement becomes the local name and the service UUIDs
    /// of `advertisement`. It is always connectable, and the device then matches scans. The backend
    /// delivers `didStartAdvertising(error:)` after the radio applies the change. It always
    /// succeeds, because a virtual radio has nothing to refuse.
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

    /// Stops advertising. It is idempotent. It reports no completion, as
    /// `CBPeripheralManager.stopAdvertising()` does not.
    ///
    /// **The chain clears ``isAdvertising``, not this method.** A synchronous write would race
    /// ``startAdvertising(_:)``, which sets the flag from a queue hop *inside* its enqueued body. A
    /// `start()` and a `stop()` on the same turn would leave the radio silent but this backend
    /// reporting `isAdvertising == true` for good. Both writes now come from the same serial chain,
    /// so the last call decides.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue({ [weak self] handle in
            await handle.setAdvertising(false)
            guard let self else { return }
            self.queue.async { self._isAdvertising = false }
        }, ifRemoved: { [weak self] in
            // A device that is gone does not advertise, and no later call will say so.
            guard let self else { return }
            self.queue.async { self._isAdvertising = false }
        })
    }

    /// Publishes `service` into the hosted device's GATT database. The backend delivers
    /// `didAddService(_:error:)` after the radio applies it. A service that is already published
    /// fails with `BLESwiftProvider` code 4, as CoreBluetooth also refuses a repeat.
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

    /// Resolves the parked read or write request that `token` identifies. If `error` is set, the
    /// request fails with that ATT error. Otherwise it succeeds, with `value` (or empty `Data`) for
    /// a read. The method does nothing if `token` is unknown, already answered, or from a removed
    /// device.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        Task { [handler] in
            await handler.respond(to: token, value: value, error: error)
        }
    }

    /// Pushes `value` to every central that is subscribed to `characteristic`, or only to
    /// `centrals`.
    ///
    /// - Returns: Always `true`. The virtual radio has no transmit queue, so it applies no
    ///   back-pressure.
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { handle in
            await handle.notify(value, for: characteristic, to: centrals)
        }
        return true
    }

    /// Detaches ``eventHandler`` from off ``queue``, by hopping onto the queue. The hosted device
    /// stays on the radio, and the backend refuses a request that arrives in this state.
    package func detachEventHandlerForTesting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                _eventHandler = nil
                handlerAttached.withLock { $0 = false }
                continuation.resume()
            }
        }
    }

    /// The error that an operation reports when it was queued after the hosted device was removed.
    /// Without it, the caller would wait for a completion that can never arrive.
    private static var removedError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "The backend's hosted device has been removed."]
        )
    }

    /// The error that ``add(_:)`` reports for an already-published service.
    private static var duplicateServiceError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "That service is already published in the hosted GATT database."]
        )
    }
}

/// The ``VirtualDeviceHandler`` behind a ``VirtualPeripheralManagerBackend``. It turns each piece
/// of GATT traffic from the radio into a ``BLESwiftCore/PeripheralHostEvent`` for the
/// `PeripheralHost`, and parks a continuation until the host answers.
///
/// There is one continuation for each ``BLESwiftCore/RequestToken``, in two maps. A read and a
/// write both succeed with `value: nil, error: nil`, so the code finds the request's kind from the
/// map that holds the token, never from the response's shape.
///
/// **No request parks forever.** ``VirtualRadio/attTimeout`` bounds each request. If a host never
/// answers, the handler refuses the request with ``BLESwiftCore/ATTError/unlikelyError``. This
/// releases the central's call and every operation queued behind it on that remote. A later
/// response does nothing, as for any unknown token.
actor VirtualHostedDeviceHandler: VirtualDeviceHandler {

    /// Delivers events to the owning backend's `eventHandler`, hopping onto the backend's queue. It
    /// reports whether a handler was attached to receive them.
    private var sink: (@Sendable (PeripheralHostEvent) -> Bool)?

    private var pendingReads: [RequestToken: CheckedContinuation<Result<Data, ATTError>, Never>] = [:]
    private var pendingWrites: [RequestToken: CheckedContinuation<Result<Void, ATTError>, Never>] = [:]

    /// How long a parked request waits for the host's answer before the handler refuses it.
    private let attTimeout: Duration

    /// The clock that the wait runs on. It is the radio's clock, so a test that drives a
    /// `ManualClock` can run the ATT timeout out like any other delay.
    private let clock: any Clock<Duration>

    /// The countdown for each parked request. The handler cancels it when any other route settles
    /// the request.
    private var timeouts: [RequestToken: Task<Void, Never>] = [:]

    /// Creates a handler whose parked requests time out after `attTimeout`.
    ///
    /// - Parameters:
    ///   - attTimeout: The ATT transaction timeout. The default is ``VirtualRadio/attTimeout``.
    ///     Tests shorten it.
    ///   - clock: The clock that the timeout sleeps on. It is the radio's clock.
    init(attTimeout: Duration = VirtualRadio.attTimeout, clock: any Clock<Duration>) {
        self.attTimeout = attTimeout
        self.clock = clock
    }

    /// Attaches the event sink before the radio registers the device.
    func attach(_ sink: @escaping @Sendable (PeripheralHostEvent) -> Bool) {
        self.sink = sink
    }

    /// Detaches the sink and fails every parked request with
    /// ``BLESwiftCore/ATTError/unlikelyError``, because nothing is left to answer them after the
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

    /// Answers the request that `token` identifies, if it is still parked. A response after the
    /// request timed out does nothing, as for any unknown token.
    func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        timeouts.removeValue(forKey: token)?.cancel()
        if let continuation = pendingReads.removeValue(forKey: token) {
            continuation.resume(returning: error.map { .failure($0) } ?? .success(value ?? Data()))
        } else if let continuation = pendingWrites.removeValue(forKey: token) {
            continuation.resume(returning: error.map { .failure($0) } ?? .success(()))
        }
    }

    /// Surfaces the read to the host as `didReceiveRead` and suspends until the host responds.
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

    /// Surfaces the batch to the host as `didReceiveWrite` and suspends until the host responds.
    /// One response settles the whole batch, as CoreBluetooth requires.
    func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
        guard let sink else { return .failure(.unlikelyError) }
        let token = RequestToken()
        return await withCheckedContinuation { continuation in
            pendingWrites[token] = continuation
            startTimeout(for: token)
            if !sink(.didReceiveWrite(WriteRequest(token: token, entries: entries))) { fail(token) }
        }
    }

    /// Starts the ATT transaction countdown for a request that was just parked. If the host never
    /// answers, the countdown refuses the request after ``attTimeout``, so the caller and every
    /// operation queued behind it on that remote do not stay suspended forever.
    private func startTimeout(for token: RequestToken) {
        timeouts[token] = Task { [attTimeout, clock] in
            try? await clock.sleep(for: attTimeout)
            guard !Task.isCancelled else { return }
            fail(token)
        }
    }

    /// Refuses the parked request that `token` identifies with
    /// ``BLESwiftCore/ATTError/unlikelyError``. It answers a request that no attached handler saw,
    /// and one that the host let time out.
    private func fail(_ token: RequestToken) {
        timeouts.removeValue(forKey: token)?.cancel()
        if let continuation = pendingReads.removeValue(forKey: token) {
            continuation.resume(returning: .failure(.unlikelyError))
        } else if let continuation = pendingWrites.removeValue(forKey: token) {
            continuation.resume(returning: .failure(.unlikelyError))
        }
    }

    /// Reports the change to the host as `didSubscribe` or `didUnsubscribe`. It parks nothing,
    /// because a subscription change needs no answer.
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
