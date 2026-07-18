//
//  FakePeripheralManager.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation
import Synchronization

/// A scriptable stand-in for `CBPeripheralManager`, conforming to `PeripheralManaging` — the
/// peripheral-role counterpart to ``FakeCentral``.
///
/// `CBPeripheralManager` cannot be instantiated or scripted in tests, so `FakePeripheralManager`
/// lets you drive the shim protocol's call sites (`startAdvertising`, `add`, `respond`,
/// `updateValue`, …) and script the events a real manager would deliver via its delegate,
/// without any hardware or CoreBluetooth. Because it models requests and responses as **owned
/// value types**, it imports no CoreBluetooth — so it compiles on every platform, including
/// ones where a real `CBPeripheralManager` could not advertise. Construct one with
/// ``init(queue:state:)`` and pass it to `PeripheralHost.init(backend:queue:configuration:)`.
///
/// **Concurrency — queue-confined, not lock-protected.** Identical discipline to
/// ``FakeCentral``: every stored property is `nonisolated(unsafe)`; every CB-mirroring method
/// and property accessor asserts `dispatchPrecondition(condition: .onQueue(queue))` at entry;
/// event delivery is always `queue.async` (never inline); and ``onQueue(_:)`` is the one
/// sanctioned door for off-queue (test) code to configure or inspect state. The single serial
/// queue itself *is* the synchronization. `static var bluetoothAuthorization` is the one
/// exception, backed by a `Mutex`.
public final class FakePeripheralManager: PeripheralManaging, Sendable {

    /// A recorded call to ``respond(to:value:error:)``.
    public struct RespondCall: Sendable, Equatable {
        /// The token the response targeted.
        public let token: RequestToken
        /// The value supplied (a read result), or `nil`.
        public let value: Data?
        /// The ATT failure supplied, or `nil` for success.
        public let error: ATTError?
    }

    /// A recorded call to ``updateValue(_:for:onSubscribed:)``.
    public struct UpdateValueCall: Sendable, Equatable {
        /// The value pushed.
        public let value: Data
        /// The characteristic notified.
        public let characteristic: CharacteristicIdentifier
        /// The targeted subscribers, or `nil` for all.
        public let centrals: [Subscriber]?
        /// What the scripted call returned (the back-pressure `Bool`).
        public let returned: Bool
    }

    /// The queue every CB-mirroring method and event delivery is confined to.
    public let queue: DispatchSerialQueue

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

    /// The `BluetoothAuthorization` this fake reports. `Mutex`-backed, so readable/writable
    /// off-queue without ``onQueue(_:)``.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        get { authorizationBox.withLock { $0 } }
        set { authorizationBox.withLock { $0 = newValue } }
    }

    /// Creates a `FakePeripheralManager` confined to `queue`.
    ///
    /// - Parameters:
    ///   - queue: The queue every CB-mirroring method and event delivery is confined to — the
    ///     same queue the `PeripheralHost` actor's executor must be tied to.
    ///   - state: The initial `CentralState`. Defaults to `.unknown`.
    public init(queue: DispatchSerialQueue, state: CentralState = .unknown) {
        self.queue = queue
        self._radioState = state
    }

    /// Hops onto ``queue`` (via `queue.async` + a continuation) to run `body`, then returns
    /// its result — the one sanctioned way for off-queue code to configure this fake or read
    /// its recorded calls for assertions. Also flushes every previously-scheduled `.async`
    /// event delivery first.
    ///
    /// This is `async` and **never blocks the calling thread** — it does *not* use
    /// `queue.sync`, whose cooperative-thread parking under the parallel test runner is the
    /// deadlock fixed in issue #13 (see ``FakeCentral/onQueue(_:)`` for the full rationale).
    ///
    /// - Warning: Never `await` from within an ``eventHandler`` callback or other on-queue
    ///   code — a deadlock, like `CBPeripheralManager`'s own queue.
    public func onQueue<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - Inspectable state (via onQueue)

    /// Receives every `PeripheralHostEvent` this fake delivers, on ``queue``.
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

    /// Whether this fake is currently "advertising" (flipped by the scripted advertising
    /// lifecycle).
    public var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _isAdvertising
    }

    /// The error the next ``startAdvertising(_:)`` should report (`nil` = success). Configure
    /// via ``onQueue(_:)``.
    public var startAdvertisingError: NSError? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _startAdvertisingError }
        set { dispatchPrecondition(condition: .onQueue(queue)); _startAdvertisingError = newValue }
    }

    /// The error the next ``add(_:)`` should report (`nil` = success). Configure via
    /// ``onQueue(_:)``.
    public var addServiceError: NSError? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _addServiceError }
        set { dispatchPrecondition(condition: .onQueue(queue)); _addServiceError = newValue }
    }

    /// The advertisement passed to the most recent ``startAdvertising(_:)`` (`nil` before any).
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

    /// Every service passed to ``add(_:)``, in order.
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

    /// A FIFO queue of scripted return values for upcoming ``updateValue(_:for:onSubscribed:)``
    /// calls — the back-pressure lever. Each call consumes the next entry; when empty, calls
    /// return `true` (queued). Set `[false]` to make exactly the next `updateValue` report a
    /// full transmit queue, then ``simulateReadyToUpdate()`` to unblock the retry. Configure
    /// via ``onQueue(_:)``.
    public var scriptedUpdateValueReturns: [Bool] {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _scriptedUpdateValueReturns }
        set { dispatchPrecondition(condition: .onQueue(queue)); _scriptedUpdateValueReturns = newValue }
    }

    /// A cross-role **bridge hook** invoked synchronously, on ``queue``, from inside ``add(_:)``
    /// with the service just published — the seam ``FakeGATTBridge`` uses to mirror this host's
    /// hosted GATT database into a central-side ``FakePeripheral``'s discovery state, so the
    /// central discovers exactly what the host published. Fires in addition to (not instead of)
    /// recording the service in ``addedServices`` and delivering `.didAddService`. `nil` (the
    /// default) is unchanged behavior. Configure via ``onQueue(_:)``.
    public var onAddService: ((GATTService) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _onAddService }
        set { dispatchPrecondition(condition: .onQueue(queue)); _onAddService = newValue }
    }

    /// A cross-role **bridge hook** invoked synchronously, on ``queue``, from inside
    /// ``respond(to:value:error:)`` with the recorded ``RespondCall`` — the seam
    /// ``FakeGATTBridge`` uses to route this host's answer back to the central as a read result
    /// (the response `value`) or a write acknowledgement (`error`, or success). Fires in
    /// addition to recording the call in ``respondCalls``. `nil` (the default) is unchanged
    /// behavior. Configure via ``onQueue(_:)``.
    public var onRespond: ((RespondCall) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _onRespond }
        set { dispatchPrecondition(condition: .onQueue(queue)); _onRespond = newValue }
    }

    /// A cross-role **bridge hook** invoked synchronously, on ``queue``, from inside
    /// ``updateValue(_:for:onSubscribed:)`` with the recorded ``UpdateValueCall`` (including the
    /// back-pressure `returned` flag) — the seam ``FakeGATTBridge`` uses to surface this host's
    /// notification as a central-side notification. Fires in addition to recording the call in
    /// ``updateValueCalls``. `nil` (the default) is unchanged behavior. Configure via
    /// ``onQueue(_:)``.
    public var onUpdateValue: ((UpdateValueCall) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _onUpdateValue }
        set { dispatchPrecondition(condition: .onQueue(queue)); _onUpdateValue = newValue }
    }

    // MARK: - Simulation (off-queue safe; hop onto queue themselves)

    /// Simulates the radio changing state and, asynchronously, delivers
    /// `.didUpdateState(_:)` on ``queue``.
    public func simulateStateChange(_ newState: CentralState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _radioState = newState
            deliver(.didUpdateState(newState))
        }
    }

    /// Simulates a remote central issuing a read request and, asynchronously, delivers
    /// `.didReceiveRead(_:)`. Returns the freshly minted ``RequestToken`` (synchronously) so a
    /// test can correlate the eventual ``respondCalls`` entry.
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

    /// Simulates a remote central issuing a single write and, asynchronously, delivers
    /// `.didReceiveWrite(_:)`. Returns the minted ``RequestToken``.
    @discardableResult
    public func simulateWriteRequest(
        central: Subscriber,
        characteristic: CharacteristicIdentifier,
        value: Data,
        offset: Int = 0
    ) -> RequestToken {
        simulateWriteRequests([WriteRequest.Entry(central: central, characteristic: characteristic, offset: offset, value: value)])
    }

    /// Simulates a remote central issuing a batch of writes and, asynchronously, delivers
    /// `.didReceiveWrite(_:)`. Returns the minted ``RequestToken``.
    @discardableResult
    public func simulateWriteRequests(_ entries: [WriteRequest.Entry]) -> RequestToken {
        let token = RequestToken()
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didReceiveWrite(WriteRequest(token: token, entries: entries)))
        }
        return token
    }

    /// Simulates a remote central subscribing to `characteristic`'s notifications and,
    /// asynchronously, delivers `.didSubscribe(central:characteristic:)`.
    public func simulateSubscribe(central: Subscriber, to characteristic: CharacteristicIdentifier) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didSubscribe(central: central, characteristic: characteristic))
        }
    }

    /// Simulates a remote central unsubscribing from `characteristic`'s notifications and,
    /// asynchronously, delivers `.didUnsubscribe(central:characteristic:)`.
    public func simulateUnsubscribe(central: Subscriber, from characteristic: CharacteristicIdentifier) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didUnsubscribe(central: central, characteristic: characteristic))
        }
    }

    /// Simulates the transmit queue draining and, asynchronously, delivers
    /// `.readyToUpdateSubscribers` — unblocks a ``PeripheralHost/updateValue(_:for:onSubscribed:)``
    /// that is awaiting capacity after a scripted `false` return.
    public func simulateReadyToUpdate() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.readyToUpdateSubscribers)
        }
    }

    #if os(iOS)
    /// Simulates CoreBluetooth restoring preserved peripheral-role state and, asynchronously,
    /// delivers `.willRestoreState(_:)`. Call **before** the `.poweredOn`
    /// ``simulateStateChange(_:)``, mirroring CoreBluetooth's ordering.
    public func simulateRestoration(_ state: RestoredPeripheralState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }
    #else
    /// `package` mirror of the iOS-only public `simulateRestoration(_:)` — see the dual-access
    /// note on `RestoredState`. **Keep the two in sync.**
    package func simulateRestoration(_ state: RestoredPeripheralState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.willRestoreState(state))
        }
    }
    #endif

    // MARK: - PeripheralManaging

    /// Records the call and asynchronously delivers `.didStartAdvertising(error:)` on
    /// ``queue`` (per ``startAdvertisingError``), flipping ``isAdvertising`` to `true` on
    /// success.
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

    /// Records the call and flips ``isAdvertising`` to `false`.
    public func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
        _stopAdvertisingCallCount += 1
        _isAdvertising = false
    }

    /// Records the service and asynchronously delivers `.didAddService(_:error:)` on ``queue``
    /// (per ``addServiceError``).
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
    /// ``scriptedUpdateValueReturns`` (or `true` when none scripted).
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
