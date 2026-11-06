//
//  FakePeripheralManager.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation
import BLESwiftCompat17

/// A scriptable stand-in for `CBPeripheralManager` that conforms to `PeripheralManaging`. It is the
/// peripheral-role counterpart of ``FakeCentral``.
///
/// You cannot instantiate or script `CBPeripheralManager` in tests. `FakePeripheralManager` lets
/// you drive the shim protocol's call sites and script the events that a real manager delivers
/// with its delegate, with no hardware. It models requests and responses as owned value types, so
/// it imports no CoreBluetooth and compiles on every platform. Construct it with
/// ``init(queue:state:)``.
///
/// **Concurrency: a queue confines it and no lock protects it.** The rules match ``FakeCentral``:
/// - Every stored property is `nonisolated(unsafe)`.
/// - Every accessor asserts `dispatchPrecondition(condition: .onQueue(queue))`.
/// - Event delivery is always `queue.async`.
/// - ``onQueue(_:)`` is the one permitted door for off-queue code.
///
/// `static var bluetoothAuthorization` is the exception. A `Mutex` backs it.
public final class FakePeripheralManager: PeripheralManaging, Sendable {

    /// A recorded call to ``respond(to:value:error:)``.
    public struct RespondCall: Sendable, Equatable {
        /// The token that the response targeted.
        public let token: RequestToken
        /// The value that the call supplied (a read result), or `nil`.
        public let value: Data?
        /// The ATT failure that the call supplied, or `nil` for success.
        public let error: ATTError?
    }

    /// A recorded call to ``updateValue(_:for:onSubscribed:)``.
    public struct UpdateValueCall: Sendable, Equatable {
        /// The value that the call pushed.
        public let value: Data
        /// The characteristic that the call notified.
        public let characteristic: CharacteristicIdentifier
        /// The targeted subscribers, or `nil` for all.
        public let centrals: [Subscriber]?
        /// What the scripted call returned (the back-pressure `Bool`).
        public let returned: Bool
    }

    /// The queue that confines every method and event delivery that mirrors CoreBluetooth.
    public let queue: DispatchQueue

    nonisolated(unsafe) private var _radioState: CentralState
    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _isAdvertising = false

    nonisolated(unsafe) private var _startAdvertisingError: NSError?
    nonisolated(unsafe) private var _addServiceError: NSError?
    nonisolated(unsafe) private var _lastAdvertisement: PeripheralAdvertisement?
    nonisolated(unsafe) private var _startAdvertisingCallCount = 0
    nonisolated(unsafe) private var _stopAdvertisingCallCount = 0
    nonisolated(unsafe) private var _addedServices: [GATTService] = []
    nonisolated(unsafe) private var _removeAllServicesCallCount = 0
    nonisolated(unsafe) private var _respondCalls: [RespondCall] = []
    nonisolated(unsafe) private var _updateValueCalls: [UpdateValueCall] = []
    nonisolated(unsafe) private var _scriptedUpdateValueReturns: [Bool] = []
    nonisolated(unsafe) private var _onAddService: ((GATTService) -> Void)?
    nonisolated(unsafe) private var _onRespond: ((RespondCall) -> Void)?
    nonisolated(unsafe) private var _onUpdateValue: ((UpdateValueCall) -> Void)?

    private static let authorizationBox = Mutex<BluetoothAuthorization>(.allowedAlways)

    /// The `BluetoothAuthorization` that this fake reports. A `Mutex` backs it, so you can read and
    /// write it off the queue without ``onQueue(_:)``.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        get { authorizationBox.withLock { $0 } }
        set { authorizationBox.withLock { $0 = newValue } }
    }

    /// Creates a `FakePeripheralManager` confined to `queue`.
    ///
    /// - Parameters:
    ///   - queue: The queue that confines every method and event delivery. It must be the queue
    ///     that the `PeripheralHost` actor's executor uses. It must be serial
    ///     (`DispatchQueue(label:)` makes a serial queue).
    ///   - state: The initial `CentralState`. The default is `.unknown`.
    public init(queue: DispatchQueue, state: CentralState = .unknown) {
        self.queue = queue
        self._radioState = state
    }

    /// Runs `body` on ``queue`` and returns its result. Off-queue code must use this to configure
    /// this fake or to read its recorded calls. It also flushes every `.async` event delivery that
    /// is already scheduled. It never blocks (see ``FakeCentral/onQueue(_:)``).
    ///
    /// - Warning: Never `await` this function from an ``eventHandler`` callback or from other code
    ///   that runs on the queue. That deadlocks, as it does with `CBPeripheralManager`'s queue.
    public func onQueue<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - Inspectable state (via onQueue)

    /// Receives every `PeripheralHostEvent` that this fake delivers, on ``queue``.
    public var eventHandler: ((PeripheralHostEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
        }
    }

    /// The current radio state.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _radioState
    }

    /// Whether this fake is advertising. ``startAdvertising(_:)`` and ``stopAdvertising()`` change
    /// it.
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _isAdvertising
    }

    /// The error that the next ``startAdvertising(_:)`` reports (`nil` = success). Configure it
    /// with ``onQueue(_:)``.
    public var startAdvertisingError: NSError? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _startAdvertisingError }
        set { dispatchPrecondition(condition: .onQueue(queue)); _startAdvertisingError = newValue }
    }

    /// The error that the next ``add(_:)`` reports (`nil` = success). Configure it with
    /// ``onQueue(_:)``.
    public var addServiceError: NSError? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _addServiceError }
        set { dispatchPrecondition(condition: .onQueue(queue)); _addServiceError = newValue }
    }

    /// The advertisement of the latest ``startAdvertising(_:)`` call (`nil` before any call).
    public var lastAdvertisement: PeripheralAdvertisement? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastAdvertisement
    }

    /// The number of ``startAdvertising(_:)`` calls.
    public var startAdvertisingCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _startAdvertisingCallCount
    }

    /// The number of ``stopAdvertising()`` calls.
    public var stopAdvertisingCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _stopAdvertisingCallCount
    }

    /// Every service that ``add(_:)`` received, in order.
    public var addedServices: [GATTService] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _addedServices
    }

    /// The number of ``removeAllHostedServices()`` calls.
    public var removeAllServicesCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _removeAllServicesCallCount
    }

    /// Every ``respond(to:value:error:)`` call, in order.
    public var respondCalls: [RespondCall] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _respondCalls
    }

    /// Every ``updateValue(_:for:onSubscribed:)`` call, in order.
    public var updateValueCalls: [UpdateValueCall] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _updateValueCalls
    }

    /// A first-in-first-out list of scripted return values for the next
    /// ``updateValue(_:for:onSubscribed:)`` calls. It controls back-pressure. Each call takes the
    /// next entry. When the list is empty, calls return `true` (queued). Set `[false]` to make
    /// exactly the next `updateValue` report a full transmit queue. Then call
    /// ``simulateReadyToUpdate()`` to unblock the retry. Configure it with ``onQueue(_:)``.
    public var scriptedUpdateValueReturns: [Bool] {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _scriptedUpdateValueReturns }
        set { dispatchPrecondition(condition: .onQueue(queue)); _scriptedUpdateValueReturns = newValue }
    }

    /// A bridge hook. ``add(_:)`` calls it synchronously, on ``queue``, with the published service.
    /// ``FakeGATTBridge`` uses it to mirror the host's services into a central-side fake. The
    /// default is `nil`. Configure it with ``onQueue(_:)``.
    public var onAddService: ((GATTService) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _onAddService }
        set { dispatchPrecondition(condition: .onQueue(queue)); _onAddService = newValue }
    }

    /// A bridge hook. ``respond(to:value:error:)`` calls it synchronously, on ``queue``, with the
    /// recorded ``RespondCall``. ``FakeGATTBridge`` uses it to route the answer back to the
    /// central. The default is `nil`. Configure it with ``onQueue(_:)``.
    public var onRespond: ((RespondCall) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _onRespond }
        set { dispatchPrecondition(condition: .onQueue(queue)); _onRespond = newValue }
    }

    /// A bridge hook. ``updateValue(_:for:onSubscribed:)`` calls it synchronously, on ``queue``,
    /// with the recorded ``UpdateValueCall``. ``FakeGATTBridge`` uses it to deliver the
    /// notification to the central. The default is `nil`. Configure it with ``onQueue(_:)``.
    public var onUpdateValue: ((UpdateValueCall) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _onUpdateValue }
        set { dispatchPrecondition(condition: .onQueue(queue)); _onUpdateValue = newValue }
    }

    // MARK: - Simulation (off-queue safe; hop onto queue themselves)

    /// Simulates a radio state change. It then delivers `.didUpdateState(_:)` asynchronously on
    /// ``queue``.
    public func simulateStateChange(_ newState: CentralState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _radioState = newState
            deliver(.didUpdateState(newState))
        }
    }

    /// Simulates a remote central that sends a read request. It then delivers
    /// `.didReceiveRead(_:)` asynchronously. It returns the new ``RequestToken`` synchronously, so
    /// a test can correlate the later ``respondCalls`` entry.
    @discardableResult
    public func simulateReadRequest(
        central: Subscriber,
        characteristic: CharacteristicIdentifier,
        offset: Int = 0
    ) -> RequestToken {
        let token = RequestToken()
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didReceiveRead(ReadRequest(token: token, central: central, characteristic: characteristic, offset: offset)))
        }
        return token
    }

    /// Simulates a remote central that sends a single write. It then delivers
    /// `.didReceiveWrite(_:)` asynchronously. It returns the new ``RequestToken``.
    @discardableResult
    public func simulateWriteRequest(
        central: Subscriber,
        characteristic: CharacteristicIdentifier,
        value: Data,
        offset: Int = 0
    ) -> RequestToken {
        simulateWriteRequests([WriteRequest.Entry(central: central, characteristic: characteristic, offset: offset, value: value)])
    }

    /// Simulates a remote central that sends a batch of writes. It then delivers
    /// `.didReceiveWrite(_:)` asynchronously. It returns the new ``RequestToken``.
    @discardableResult
    public func simulateWriteRequests(_ entries: [WriteRequest.Entry]) -> RequestToken {
        let token = RequestToken()
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didReceiveWrite(WriteRequest(token: token, entries: entries)))
        }
        return token
    }

    /// Simulates a remote central that subscribes to `characteristic`'s notifications. It then
    /// delivers `.didSubscribe(central:characteristic:)` asynchronously.
    public func simulateSubscribe(central: Subscriber, to characteristic: CharacteristicIdentifier) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didSubscribe(central: central, characteristic: characteristic))
        }
    }

    /// Simulates a remote central that unsubscribes from `characteristic`'s notifications. It then
    /// delivers `.didUnsubscribe(central:characteristic:)` asynchronously.
    public func simulateUnsubscribe(central: Subscriber, from characteristic: CharacteristicIdentifier) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didUnsubscribe(central: central, characteristic: characteristic))
        }
    }

    /// Simulates the transmit queue draining. It then delivers `.readyToUpdateSubscribers`
    /// asynchronously. This unblocks a ``PeripheralHost/updateValue(_:for:onSubscribed:)`` that
    /// waits for capacity after a scripted `false` return.
    public func simulateReadyToUpdate() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.readyToUpdateSubscribers)
        }
    }

    #if os(iOS)
    /// Simulates CoreBluetooth restoring preserved peripheral-role state. It then delivers
    /// `.willRestoreState(_:)` asynchronously. Call it **before** the `.poweredOn`
    /// ``simulateStateChange(_:)``, which is the order CoreBluetooth uses.
    public func simulateRestoration(_ state: RestoredPeripheralState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }
    #else
    /// A `package` mirror of the public `simulateRestoration(_:)`, which exists on iOS only. See
    /// the dual-access note on `RestoredState`. **Keep the two in sync.**
    package func simulateRestoration(_ state: RestoredPeripheralState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }
    #endif

    // MARK: - PeripheralManaging

    /// Records the call and delivers `.didStartAdvertising(error:)` asynchronously on ``queue``,
    /// with ``startAdvertisingError`` as the error. On success, it sets ``isAdvertising`` to
    /// `true`.
    public func startAdvertising(_ advertisement: PeripheralAdvertisement) {
        dispatchPrecondition(condition: .onQueue(queue))
        _startAdvertisingCallCount += 1
        _lastAdvertisement = advertisement
        let error = _startAdvertisingError
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            if error == nil { _isAdvertising = true }
            deliver(.didStartAdvertising(error: error))
        }
    }

    /// Records the call and sets ``isAdvertising`` to `false`.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        _stopAdvertisingCallCount += 1
        _isAdvertising = false
    }

    /// Records the service and delivers `.didAddService(_:error:)` asynchronously on ``queue``,
    /// with ``addServiceError`` as the error.
    public func add(_ service: GATTService) {
        dispatchPrecondition(condition: .onQueue(queue))
        _addedServices.append(service)
        _onAddService?(service)
        let error = _addServiceError
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didAddService(service.identifier, error: error))
        }
    }

    /// Records the call and clears ``addedServices``.
    public func removeAllHostedServices() {
        dispatchPrecondition(condition: .onQueue(queue))
        _removeAllServicesCallCount += 1
        _addedServices.removeAll()
    }

    /// Records the response in ``respondCalls``.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let call = RespondCall(token: token, value: value, error: error)
        _respondCalls.append(call)
        _onRespond?(call)
    }

    /// Records the call and returns the next scripted back-pressure value from
    /// ``scriptedUpdateValueReturns`` (or `true` when none is scripted).
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let returned = _scriptedUpdateValueReturns.isEmpty ? true : _scriptedUpdateValueReturns.removeFirst()
        let call = UpdateValueCall(value: value, characteristic: characteristic, centrals: centrals, returned: returned)
        _updateValueCalls.append(call)
        _onUpdateValue?(call)
        return returned
    }

    private func deliver(_ event: PeripheralHostEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventHandler?(event)
    }
}
