//
//  FakePeripheral.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation

/// A scriptable stand-in for `CBPeripheral` that conforms to `PeripheralRemote`.
///
/// `CBPeripheral` has no public initializer, and you cannot script it in tests. `FakePeripheral`
/// lets you drive GATT operations and script the events that a real peripheral delivers with its
/// delegate.
///
/// **Concurrency: a queue confines it and no lock protects it.** For the rationale, see
/// ``FakeCentral``. Every stored property is `nonisolated(unsafe)`. This is safe because every
/// `PeripheralRemote` method and property accessor asserts `dispatchPrecondition(condition:
/// .onQueue(queue))` at entry and touches state inline. There is no `queue.sync`. ``onQueue(_:)``
/// is the only door for off-queue code. Event delivery is always `queue.async`, never inline.
public final class FakePeripheral: PeripheralRemote, Sendable {

    /// The identifier that CoreBluetooth would assign to this peripheral. It is immutable, so it
    /// needs no queue confinement.
    public let identifier: UUID

    /// The peripheral's advertised or cached name. It is immutable, so it needs no queue
    /// confinement. `FakePeripheral` cannot script a name change.
    public let name: String?

    /// The queue that confines every method and event delivery.
    public let queue: DispatchQueue

    nonisolated(unsafe) private var _connectionState: PeripheralConnectionState
    nonisolated(unsafe) private var _canSendWriteWithoutResponse: Bool
    nonisolated(unsafe) private var _ancsAuthorized = false
    nonisolated(unsafe) private var _eventHandler: ((PeripheralEvent) -> Void)?
    nonisolated(unsafe) private var _discoveredServices: Set<ServiceIdentifier> = []
    nonisolated(unsafe) private var _discoveredCharacteristics: Set<CharacteristicIdentifier> = []
    nonisolated(unsafe) private var _notifyingCharacteristics: Set<CharacteristicIdentifier> = []
    nonisolated(unsafe) private var _scriptedReadValues: [CharacteristicIdentifier: Data] = [:]
    nonisolated(unsafe) private var _scriptedMaximumWriteValueLength = 20
    nonisolated(unsafe) private var _scriptedRSSI = -50
    nonisolated(unsafe) private var _readCallCount = 0
    nonisolated(unsafe) private var _writeCallCounts: [CharacteristicIdentifier: Int] = [:]
    nonisolated(unsafe) private var _discoverServicesCallCount = 0
    nonisolated(unsafe) private var _discoverServicesAllCallCount = 0
    nonisolated(unsafe) private var _discoverCharacteristicsCallCount = 0
    nonisolated(unsafe) private var _holdServiceDiscoveryCompletions = false
    nonisolated(unsafe) private var _heldServiceDiscoveryCount = 0
    nonisolated(unsafe) private var _holdReadCompletions = false
    nonisolated(unsafe) private var _heldReads: [(characteristic: CharacteristicIdentifier, value: Data?)] = []
    nonisolated(unsafe) private var _availableServices: [ServiceIdentifier: Set<CharacteristicIdentifier>]?
    nonisolated(unsafe) private var _setNotifyValueCalls: [(characteristic: CharacteristicIdentifier, enabled: Bool)] = []
    nonisolated(unsafe) private var _onWrite: ((CharacteristicIdentifier, Data) -> Void)?
    nonisolated(unsafe) private var _onReadRequest: ((CharacteristicIdentifier) -> Void)?
    nonisolated(unsafe) private var _onWriteRequest: ((CharacteristicIdentifier, Data, WriteType) -> Void)?
    nonisolated(unsafe) private var _onSubscriptionChange: ((CharacteristicIdentifier, Bool) -> Void)?
    nonisolated(unsafe) private var _eventHandlerSetCount = 0
    nonisolated(unsafe) private var _scriptedProperties: [CharacteristicIdentifier: CharacteristicProperties] = [:]
    nonisolated(unsafe) private var _discoveredDescriptors: Set<DescriptorIdentifier> = []
    nonisolated(unsafe) private var _scriptedDescriptorValues: [DescriptorIdentifier: Data] = [:]
    nonisolated(unsafe) private var _availableDescriptors: [CharacteristicIdentifier: Set<DescriptorIdentifier>]?
    nonisolated(unsafe) private var _descriptorWriteCallCounts: [DescriptorIdentifier: Int] = [:]
    nonisolated(unsafe) private var _writtenDescriptorValues: [DescriptorIdentifier: Data] = [:]
    nonisolated(unsafe) private var _discoverDescriptorsCallCount = 0
    nonisolated(unsafe) private var _descriptorReadCallCount = 0
    nonisolated(unsafe) private var _holdDescriptorReadCompletions = false
    nonisolated(unsafe) private var _heldDescriptorReads: [(descriptor: DescriptorIdentifier, value: Data?)] = []
    nonisolated(unsafe) private var _l2capOpenBehavior: L2CAPOpenBehavior = .succeed
    nonisolated(unsafe) private var _openL2CAPChannelCalls: [L2CAPPSM] = []
    nonisolated(unsafe) private var _lastOpenedL2CAPChannel: FakeL2CAPChannel?

    /// Creates a `FakePeripheral` confined to `queue`.
    ///
    /// - Parameters:
    ///   - identifier: The peripheral's identifier. The default is a new `UUID`.
    ///   - name: The peripheral's advertised or cached name.
    ///   - state: The initial `PeripheralConnectionState`. The default is `.disconnected`.
    ///   - canSendWriteWithoutResponse: The initial back-pressure state. The default is `true`
    ///     (ready).
    ///   - queue: The queue that confines every method and event delivery. It must be serial
    ///     (`DispatchQueue(label:)` makes a serial queue).
    public init(
        identifier: UUID = UUID(),
        name: String? = "Fake Peripheral",
        state: PeripheralConnectionState = .disconnected,
        canSendWriteWithoutResponse: Bool = true,
        queue: DispatchQueue
    ) {
        self.identifier = identifier
        self.name = name
        self._connectionState = state
        self._canSendWriteWithoutResponse = canSendWriteWithoutResponse
        self.queue = queue
    }

    /// This peripheral's identity as a `PeripheralIdentifier`. It reads only immutable state, so it
    /// needs no queue confinement.
    public var peripheralIdentifier: PeripheralIdentifier {
        PeripheralIdentifier(uuid: identifier, name: name)
    }

    /// Runs `body` on ``queue`` and returns its result. Off-queue code must use this to configure
    /// this fake or to read its counters and state. It also flushes every `.async` event delivery
    /// that is already scheduled. It never blocks (see ``FakeCentral/onQueue(_:)``).
    ///
    /// - Warning: Never `await` this function from an ``eventHandler`` callback, or from other code
    ///   that already runs on `queue`. That deadlocks.
    public func onQueue<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// Receives every `PeripheralEvent` that this fake delivers, on ``queue``. It witnesses the
    /// `PeripheralRemote` requirement. Configure it with ``onQueue(_:)``. Every set, attach or
    /// `nil` clear, increments ``eventHandlerSetCount``.
    public var eventHandler: ((PeripheralEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
            _eventHandlerSetCount += 1
        }
    }

    /// The number of times that ``eventHandler`` was set, attach or `nil` clear. It proves that
    /// `Central` wires event delivery on every path that creates a session, before the session goes
    /// live. Read it with ``onQueue(_:)``.
    public var eventHandlerSetCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _eventHandlerSetCount
    }

    /// The characteristics that are now notifying. ``setNotifyValue(_:for:)`` changes them.
    public var notifyingCharacteristics: Set<CharacteristicIdentifier> {
        dispatchPrecondition(condition: .onQueue(queue))
        return _notifyingCharacteristics
    }

    /// Every ``setNotifyValue(_:for:)`` call that this fake received, in order. A test of the
    /// reference-count lifecycle uses this to assert when notifications were enabled or disabled.
    /// For example, they were enabled once for the first subscriber and disabled only when the last
    /// subscriber left. Read it with ``onQueue(_:)``.
    public var setNotifyValueCalls: [(characteristic: CharacteristicIdentifier, enabled: Bool)] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _setNotifyValueCalls
    }

    /// ``writeValue(_:for:type:)`` calls this synchronously, on ``queue``, before it enqueues the
    /// `didWriteValue` completion. Use it to script a device that responds to a write immediately.
    /// For example, if you call ``simulateNotification(for:value:error:)`` here, its delivery
    /// arrives *before* the write's completion. This is the hardest order for
    /// `writeAndAwaitNotification`'s no-loss-window guarantee. The closure can read queue-confined
    /// state. A call to ``onQueue(_:)`` from it deadlocks. The default is `nil`.
    public var onWrite: ((CharacteristicIdentifier, Data) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _onWrite
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _onWrite = newValue
        }
    }

    /// A bridge hook. ``FakeGATTBridge`` uses it to route a central-side read to a remote
    /// ``FakePeripheralManager`` host. If it is not `nil`, ``readValue(for:)`` calls it
    /// synchronously, on ``queue``, and returns. It does not deliver its own `didUpdateValue`
    /// completion, and it bypasses ``scriptedReadValues`` and ``holdReadCompletions``. The bridge
    /// delivers the final completion with ``simulateNotification(for:value:error:)``. The default
    /// is `nil`, which keeps the scripted behavior.
    public var onReadRequest: ((CharacteristicIdentifier) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _onReadRequest
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _onReadRequest = newValue
        }
    }

    /// A bridge hook. ``FakeGATTBridge`` uses it to route a central-side write to a remote
    /// ``FakePeripheralManager`` host. Unlike ``onWrite``, it can suppress the completion.
    /// ``writeValue(_:for:type:)`` calls it synchronously, on ``queue``. For a `.withResponse`
    /// write, the fake does *not* deliver `didWriteValue` automatically, and the bridge delivers it
    /// with ``simulateWriteCompletion(for:error:)``. A `.withoutResponse` write also calls the
    /// hook, but it completes as usual. The default is `nil`.
    public var onWriteRequest: ((CharacteristicIdentifier, Data, WriteType) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _onWriteRequest
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _onWriteRequest = newValue
        }
    }

    /// A bridge hook. ``setNotifyValue(_:for:)`` calls it synchronously, on ``queue``.
    /// ``FakeGATTBridge`` uses it to forward a central-side subscribe or unsubscribe to a remote
    /// ``FakePeripheralManager`` host. It never suppresses the local `didUpdateNotificationState`
    /// confirmation. The default is `nil`.
    public var onSubscriptionChange: ((CharacteristicIdentifier, Bool) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _onSubscriptionChange
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _onSubscriptionChange = newValue
        }
    }

    /// The value that ``readValue(for:)`` reports with `didUpdateValue`, keyed by characteristic.
    /// `nil` (no entry) reports `nil` data. Configure it with ``onQueue(_:)``.
    public var scriptedReadValues: [CharacteristicIdentifier: Data] {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _scriptedReadValues
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _scriptedReadValues = newValue
        }
    }

    /// The properties that ``properties(of:)`` reports for a characteristic with no entry in
    /// ``scriptedProperties``.
    public static let defaultProperties: CharacteristicProperties = [.read, .write, .writeWithoutResponse, .notify]

    /// The ``CharacteristicProperties`` that ``properties(of:)`` reports, keyed by characteristic.
    /// A characteristic with no entry reports ``defaultProperties``. Configure it with
    /// ``onQueue(_:)``.
    public var scriptedProperties: [CharacteristicIdentifier: CharacteristicProperties] {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _scriptedProperties
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _scriptedProperties = newValue
        }
    }

    /// The value that ``maximumWriteValueLength(for:)`` returns. The default is 20, the classic BLE
    /// ATT_MTU-3 default. Configure it with ``onQueue(_:)``.
    public var scriptedMaximumWriteValueLength: Int {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _scriptedMaximumWriteValueLength
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _scriptedMaximumWriteValueLength = newValue
        }
    }

    /// The value that ``readRSSI()`` reports with `didReadRSSI`. The default is `-50`. Configure it
    /// with ``onQueue(_:)``. A test with several peripherals can give each fake a different value,
    /// so a concurrent `readRSSI()` on each fake resolves with that peripheral's value.
    public var scriptedRSSI: Int {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _scriptedRSSI
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _scriptedRSSI = newValue
        }
    }

    /// The number of calls to ``readValue(for:)``.
    public var readCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _readCallCount
    }

    /// The number of calls to ``writeValue(_:for:type:)``, keyed by characteristic.
    public var writeCallCounts: [CharacteristicIdentifier: Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _writeCallCounts
    }

    /// The number of calls to ``discoverServices(_:)``.
    public var discoverServicesCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoverServicesCallCount
    }

    /// The number of ``discoverServices(_:)`` calls with `nil` (discover all). The total
    /// ``discoverServicesCallCount`` includes them.
    public var discoverServicesAllCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoverServicesAllCallCount
    }

    /// Whether ``discoverServices(_:)`` withholds its `didDiscoverServices` completion instead of
    /// delivering it immediately. It is the service-discovery counterpart of
    /// ``holdReadCompletions``. The default is `false`.
    /// ``simulateNextHeldServiceDiscoveryCompletion()`` releases held completions in
    /// first-in-first-out order. Configure it with ``onQueue(_:)``.
    public var holdServiceDiscoveryCompletions: Bool {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _holdServiceDiscoveryCompletions
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _holdServiceDiscoveryCompletions = newValue
        }
    }

    /// Delivers the oldest held `didDiscoverServices` completion (first-in-first-out). If none is
    /// held, it does nothing. ``discoverServices(_:)`` has already applied its changes to the
    /// scripted graph. Only the completion event was withheld.
    public func simulateNextHeldServiceDiscoveryCompletion() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard _heldServiceDiscoveryCount > 0 else { return }
            _heldServiceDiscoveryCount -= 1
            deliver(.didDiscoverServices(error: nil))
        }
    }

    /// The number of calls to ``discoverCharacteristics(_:for:)``.
    public var discoverCharacteristicsCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoverCharacteristicsCallCount
    }

    /// The GATT table that this fake has, if scripted. The keys are the services that exist. The
    /// values are the characteristics that exist under each service.
    ///
    /// `nil` (the default) is permissive. Every discovery call reveals exactly what it requested.
    /// If the table is not `nil`, ``discoverServices(_:)`` and ``discoverCharacteristics(_:for:)``
    /// reveal only the requested services and characteristics that are in this table. A requested
    /// item that is absent is silently not added to the discovered sets, as in real CoreBluetooth.
    /// `Central`'s `isDiscovered(_:)` recheck after discovery can therefore fail. Configure it
    /// with ``onQueue(_:)``.
    public var availableServices: [ServiceIdentifier: Set<CharacteristicIdentifier>]? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _availableServices
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _availableServices = newValue
        }
    }

    /// The value that ``readValue(for:)`` reports with `didUpdateValueForDescriptor`, keyed by
    /// descriptor. In permissive mode (``availableDescriptors`` is `nil`), a value that you script
    /// here also makes that descriptor exist for ``discoverDescriptors(for:)``. A descriptor with
    /// no entry reports `nil` data. Configure it with ``onQueue(_:)``.
    public var scriptedDescriptorValues: [DescriptorIdentifier: Data] {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _scriptedDescriptorValues
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _scriptedDescriptorValues = newValue
        }
    }

    /// The descriptors that this fake has, for each characteristic. It is the descriptor
    /// counterpart of ``availableServices``, with the same permissive or strict contract. `nil`
    /// (the default) reveals every descriptor in ``scriptedDescriptorValues``. A value that is not
    /// `nil` reveals only the descriptors that it lists, and an absent descriptor stays
    /// undiscovered. To make a write-only descriptor exist, set this property and not a scripted
    /// read value. Configure it with ``onQueue(_:)``.
    public var availableDescriptors: [CharacteristicIdentifier: Set<DescriptorIdentifier>]? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _availableDescriptors
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _availableDescriptors = newValue
        }
    }

    /// The number of ``writeValue(_:for:)`` calls (the descriptor overload), keyed by descriptor.
    /// Read it with ``onQueue(_:)``.
    public var descriptorWriteCallCounts: [DescriptorIdentifier: Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _descriptorWriteCallCounts
    }

    /// The latest bytes that ``writeValue(_:for:)`` (the descriptor overload) wrote to each
    /// descriptor. Read it with ``onQueue(_:)``.
    public var writtenDescriptorValues: [DescriptorIdentifier: Data] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _writtenDescriptorValues
    }

    /// The number of calls to ``discoverDescriptors(for:)``.
    public var discoverDescriptorsCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoverDescriptorsCallCount
    }

    /// The number of calls to ``readValue(for:)`` (the descriptor overload).
    public var descriptorReadCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _descriptorReadCallCount
    }

    /// Whether ``readValue(for:)`` (the descriptor overload) withholds its
    /// `didUpdateValueForDescriptor` completion instead of delivering it immediately. It is the
    /// descriptor counterpart of ``holdReadCompletions``. The default is `false`. Configure it with
    /// ``onQueue(_:)``.
    public var holdDescriptorReadCompletions: Bool {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _holdDescriptorReadCompletions
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _holdDescriptorReadCompletions = newValue
        }
    }

    /// Delivers the oldest held descriptor-read completion (first-in-first-out). If none is held,
    /// it does nothing.
    public func simulateNextHeldDescriptorReadCompletion() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !_heldDescriptorReads.isEmpty else { return }
            let (descriptor, value) = _heldDescriptorReads.removeFirst()
            deliver(.didUpdateValueForDescriptor(descriptor: descriptor, value: value, error: nil))
        }
    }

    /// Marks `descriptors` as discovered, with their characteristics and services, directly. It
    /// does not use ``discoverDescriptors(for:)`` or deliver an event.
    public func simulateDiscoveredDescriptors(_ descriptors: [DescriptorIdentifier]) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            for descriptor in descriptors {
                _discoveredServices.insert(descriptor.characteristic.service)
                _discoveredCharacteristics.insert(descriptor.characteristic)
            }
            _discoveredDescriptors.formUnion(descriptors)
        }
    }

    /// Simulates CoreBluetooth dropping this peripheral's cached service graph, as happens on a
    /// real disconnect. The function clears every discovered service, characteristic, and
    /// descriptor, and the notifying set. It does not change ``availableServices``,
    /// ``availableDescriptors``, or any scripted value, so a later discovery follows the same
    /// scripts. Use it to model a peripheral whose GATT graph must be discovered again (or has
    /// changed) across a reconnect.
    public func simulateGATTCacheReset() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _discoveredServices.removeAll()
            _discoveredCharacteristics.removeAll()
            _discoveredDescriptors.removeAll()
            _notifyingCharacteristics.removeAll()
        }
    }

    /// Simulates a connection-state change, asynchronously. It does not deliver an event, because
    /// `FakeCentral` owns the connect and disconnect flow and delivers those events.
    public func simulateStateChange(_ newState: PeripheralConnectionState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _connectionState = newState
        }
    }

    /// Simulates CoreBluetooth signaling renewed capacity for write-without-response. It then
    /// delivers `PeripheralEvent.isReadyToSendWriteWithoutResponse` asynchronously on ``queue``.
    public func simulateReadyToSendWriteWithoutResponse() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _canSendWriteWithoutResponse = true
            deliver(.isReadyToSendWriteWithoutResponse)
        }
    }

    /// Marks this peripheral as unable to accept a write-without-response until the next
    /// ``simulateReadyToSendWriteWithoutResponse()``. CoreBluetooth has no event for this. Only the
    /// "ready again" signal is a delegate callback.
    public func simulateWriteWithoutResponseBackPressure() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _canSendWriteWithoutResponse = false
        }
    }

    /// Simulates a notification (or an out-of-band read completion). It delivers
    /// `PeripheralEvent.didUpdateValue(characteristic:value:error:)` asynchronously on ``queue``.
    public func simulateNotification(for characteristic: CharacteristicIdentifier, value: Data?, error: NSError? = nil) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didUpdateValue(characteristic: characteristic, value: value, error: error))
        }
    }

    /// Simulates the completion of an in-flight write. It delivers
    /// `PeripheralEvent.didWriteValue(characteristic:error:)` asynchronously on ``queue``. It is
    /// the write counterpart of ``simulateNotification(for:value:error:)``. ``FakeGATTBridge`` uses
    /// it to complete a `.withResponse` write after ``onWriteRequest`` suppressed the completion.
    public func simulateWriteCompletion(for characteristic: CharacteristicIdentifier, error: NSError? = nil) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didWriteValue(characteristic: characteristic, error: error))
        }
    }

    /// Marks `services` as discovered directly. It does not use ``discoverServices(_:)`` or deliver
    /// an event.
    public func simulateDiscoveredServices(_ services: [ServiceIdentifier]) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _discoveredServices.formUnion(services)
        }
    }

    /// Marks `characteristics` as discovered on `service`. It does not use
    /// ``discoverCharacteristics(_:for:)`` or deliver an event.
    public func simulateDiscoveredCharacteristics(_ characteristics: [CharacteristicIdentifier], for service: ServiceIdentifier) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _discoveredServices.insert(service)
            _discoveredCharacteristics.formUnion(characteristics)
        }
    }

    /// Simulates CoreBluetooth invalidating `invalidatedServices` and the characteristics that were
    /// discovered under them. It then delivers `didModifyServices` asynchronously on ``queue``. A
    /// real `CBPeripheral` also removes invalidated services from its `.services` array, so
    /// `isDiscovered(_:)` shows the invalidation (see `PeripheralRemote` about the discovery
    /// cache).
    public func simulateServiceModification(invalidatedServices: [ServiceIdentifier]) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _discoveredServices.subtract(invalidatedServices)
            _discoveredCharacteristics = _discoveredCharacteristics.filter { !invalidatedServices.contains($0.service) }
            deliver(.didModifyServices(invalidatedServices))
        }
    }

    /// Mirrors one hosted `GATTService` into the discovery state of this fake. ``FakeGATTBridge``
    /// drives it from the `onAddService` hook of a remote ``FakePeripheralManager`` host.
    ///
    /// You can call it off the queue, because it hops onto ``queue`` itself. The bridge therefore
    /// calls it directly from the host's (different) queue, with no ``onQueue(_:)`` round trip. The
    /// read-modify-write of ``availableServices`` and ``scriptedProperties`` runs inside one
    /// `queue.async`, so it is atomic and composes with a service that is mirrored at the same
    /// time.
    public func simulateMirroredService(_ service: GATTService) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            var services = _availableServices ?? [:]
            var characteristics = services[service.identifier] ?? []
            for characteristic in service.characteristics {
                characteristics.insert(characteristic.identifier)
                _scriptedProperties[characteristic.identifier] = characteristic.properties
            }
            services[service.identifier] = characteristics
            _availableServices = services
        }
    }

    // MARK: - L2CAP scripting

    /// How this fake responds to ``openL2CAPChannel(_:)``.
    public enum L2CAPOpenBehavior: Sendable {
        /// Create a new ``FakeL2CAPChannel`` and deliver a successful `didOpenL2CAPChannel`. This
        /// is the default.
        case succeed
        /// Deliver a failing `didOpenL2CAPChannel` with `error` and no channel.
        case fail(NSError)
        /// Record the call but deliver nothing. Use it to test open timeout and cancellation.
        case hold
    }

    /// How ``openL2CAPChannel(_:)`` responds. The default is ``L2CAPOpenBehavior/succeed``.
    /// Configure it with ``onQueue(_:)``.
    public var l2capOpenBehavior: L2CAPOpenBehavior {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _l2capOpenBehavior
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _l2capOpenBehavior = newValue
        }
    }

    /// Every `L2CAPPSM` that ``openL2CAPChannel(_:)`` received, in order. Read it with
    /// ``onQueue(_:)``.
    public var openL2CAPChannelCalls: [L2CAPPSM] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _openL2CAPChannelCalls
    }

    /// The latest ``FakeL2CAPChannel`` that this fake created in a `.succeed`
    /// ``openL2CAPChannel(_:)``. Use it to drive `simulateInbound` and to inspect `writtenData` on
    /// the channel that the `Central` received. Read it with ``onQueue(_:)``. It is `nil` if no
    /// open has succeeded. A later failed or held open does not clear it.
    public var lastOpenedL2CAPChannel: FakeL2CAPChannel? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastOpenedL2CAPChannel
    }

    // MARK: - PeripheralRemote

    /// The current connection state of the peripheral.
    public var connectionState: PeripheralConnectionState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectionState
    }

    /// Whether this fake can accept a write-without-response now.
    public var canSendWriteWithoutResponse: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _canSendWriteWithoutResponse
    }

    /// The scripted ANCS authorization value that this fake reports. The default is `false`. Set it
    /// with ``onQueue(_:)``, before or together with
    /// `FakeCentral.simulateANCSAuthorization(_:for:)`. A real `CBPeripheral` shows the new value
    /// when the callback arrives.
    public var ancsAuthorized: Bool {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _ancsAuthorized
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _ancsAuthorized = newValue
        }
    }

    /// Records the call and delivers `didDiscoverServices` asynchronously on ``queue``. The
    /// ``availableServices`` contract (permissive or strict) applies. If ``availableServices`` is
    /// `nil`, every requested service becomes discovered. Otherwise only the requested services
    /// that are keys of it do.
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        _discoverServicesCallCount += 1
        if services == nil {
            _discoverServicesAllCallCount += 1
        }
        if let available = _availableServices {
            let requested = services ?? Array(available.keys)
            _discoveredServices.formUnion(requested.filter { available.keys.contains($0) })
        } else if let services {
            _discoveredServices.formUnion(services)
        }
        if _holdServiceDiscoveryCompletions {
            _heldServiceDiscoveryCount += 1
            return
        }
        queue.async { [self] in deliver(.didDiscoverServices(error: nil)) }
    }

    /// Records the call and delivers `didDiscoverCharacteristics` asynchronously on ``queue``. The
    /// ``availableServices`` contract is the same as for ``discoverServices(_:)``, scoped to
    /// `service`'s characteristics.
    public func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _discoverCharacteristicsCallCount += 1
        if let available = _availableServices {
            let availableForService = available[service] ?? []
            let requested = characteristics ?? Array(availableForService)
            _discoveredCharacteristics.formUnion(requested.filter { availableForService.contains($0) })
        } else if let characteristics {
            _discoveredCharacteristics.formUnion(characteristics)
        }
        queue.async { [self] in deliver(.didDiscoverCharacteristics(service: service, error: nil)) }
    }

    /// Records the call. If ``holdReadCompletions`` is not `true`, it delivers `didUpdateValue`
    /// asynchronously on ``queue``, with the value in ``scriptedReadValues`` for `characteristic`
    /// (`nil` if none). While reads are held, each pending completion waits until
    /// ``simulateNextHeldReadCompletion()`` delivers it.
    public func readValue(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _readCallCount += 1
        // A bridged read routes to a remote host. The bridge delivers the completion later (see
        // ``onReadRequest``).
        if let onReadRequest = _onReadRequest {
            onReadRequest(characteristic)
            return
        }
        let value = _scriptedReadValues[characteristic]
        if _holdReadCompletions {
            _heldReads.append((characteristic, value))
            return
        }
        queue.async { [self] in deliver(.didUpdateValue(characteristic: characteristic, value: value, error: nil)) }
    }

    /// Whether ``readValue(for:)`` withholds its `didUpdateValue` completion instead of delivering
    /// it immediately. The default is `false`: every read completes at once, as every other
    /// operation on this fake does. Configure it with ``onQueue(_:)``.
    public var holdReadCompletions: Bool {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _holdReadCompletions
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _holdReadCompletions = newValue
        }
    }

    /// Delivers the oldest held read completion (first-in-first-out). If none is held, it does
    /// nothing.
    public func simulateNextHeldReadCompletion() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !_heldReads.isEmpty else { return }
            let (characteristic, value) = _heldReads.removeFirst()
            deliver(.didUpdateValue(characteristic: characteristic, value: value, error: nil))
        }
    }

    /// Records the call, calls ``onWrite`` synchronously, and delivers `didWriteValue`
    /// asynchronously on ``queue``. Because ``onWrite`` is synchronous, anything that it enqueues,
    /// such as a scripted response notification, arrives before the write's completion.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        dispatchPrecondition(condition: .onQueue(queue))
        _writeCallCounts[characteristic, default: 0] += 1
        _onWrite?(characteristic, data)
        if let onWriteRequest = _onWriteRequest {
            onWriteRequest(characteristic, data, type)
            // The bridge completes a bridged `.withResponse` write (see
            // ``simulateWriteCompletion(for:error:)``), so do not complete it here.
            if type == .withResponse { return }
        }
        queue.async { [self] in deliver(.didWriteValue(characteristic: characteristic, error: nil)) }
    }

    /// Records the call in ``setNotifyValueCalls`` and updates whether `characteristic` is
    /// notifying. It delivers `didUpdateNotificationState` asynchronously on ``queue``.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _setNotifyValueCalls.append((characteristic, enabled))
        if enabled {
            _notifyingCharacteristics.insert(characteristic)
        } else {
            _notifyingCharacteristics.remove(characteristic)
        }
        // A bridged peripheral forwards the change to a remote host (see
        // ``onSubscriptionChange``). This never suppresses the local confirmation below.
        _onSubscriptionChange?(characteristic, enabled)
        queue.async { [self] in
            deliver(.didUpdateNotificationState(characteristic: characteristic, isNotifying: enabled, error: nil))
        }
    }

    /// Records the call and delivers `didDiscoverDescriptors` asynchronously on ``queue``. The
    /// permissive or strict contract is the same as for ``availableServices``, through
    /// ``availableDescriptors`` and ``scriptedDescriptorValues``.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _discoverDescriptorsCallCount += 1
        if let available = _availableDescriptors {
            _discoveredDescriptors.formUnion(available[characteristic] ?? [])
        } else {
            _discoveredDescriptors.formUnion(_scriptedDescriptorValues.keys.filter { $0.characteristic == characteristic })
        }
        queue.async { [self] in deliver(.didDiscoverDescriptors(characteristic: characteristic, error: nil)) }
    }

    /// Records the call. If ``holdDescriptorReadCompletions`` is not `true`, it delivers
    /// `didUpdateValueForDescriptor` asynchronously on ``queue``, with the value in
    /// ``scriptedDescriptorValues`` for `descriptor` (`nil` if none).
    public func readValue(for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _descriptorReadCallCount += 1
        let value = _scriptedDescriptorValues[descriptor]
        if _holdDescriptorReadCompletions {
            _heldDescriptorReads.append((descriptor, value))
            return
        }
        queue.async { [self] in deliver(.didUpdateValueForDescriptor(descriptor: descriptor, value: value, error: nil)) }
    }

    /// Records the call and the written bytes, and delivers `didWriteValueForDescriptor`
    /// asynchronously on ``queue``.
    public func writeValue(_ data: Data, for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _descriptorWriteCallCounts[descriptor, default: 0] += 1
        _writtenDescriptorValues[descriptor] = data
        queue.async { [self] in deliver(.didWriteValueForDescriptor(descriptor: descriptor, error: nil)) }
    }

    /// Delivers `didReadRSSI` with ``scriptedRSSI`` asynchronously on ``queue``.
    public func readRSSI() {
        dispatchPrecondition(condition: .onQueue(queue))
        let rssi = _scriptedRSSI
        queue.async { [self] in deliver(.didReadRSSI(rssi, error: nil)) }
    }

    /// Returns ``scriptedMaximumWriteValueLength``.
    public func maximumWriteValueLength(for type: WriteType) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _scriptedMaximumWriteValueLength
    }

    /// Whether `service` is discovered (with ``discoverServices(_:)`` or
    /// ``simulateDiscoveredServices(_:)``).
    public func isDiscovered(_ service: ServiceIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredServices.contains(service)
    }

    /// Whether `characteristic` is discovered (with ``discoverCharacteristics(_:for:)`` or
    /// ``simulateDiscoveredCharacteristics(_:for:)``).
    public func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredCharacteristics.contains(characteristic)
    }

    /// Whether `characteristic` is notifying (``setNotifyValue(_:for:)`` changes it).
    public func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _notifyingCharacteristics.contains(characteristic)
    }

    /// The scripted ``CharacteristicProperties`` for `characteristic` (see ``scriptedProperties``),
    /// or ``defaultProperties`` if none was scripted. Unlike real CoreBluetooth, this function does
    /// not require discovery.
    public func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties {
        dispatchPrecondition(condition: .onQueue(queue))
        return _scriptedProperties[characteristic] ?? Self.defaultProperties
    }

    /// Whether `descriptor` is discovered (with ``discoverDescriptors(for:)`` or
    /// ``simulateDiscoveredDescriptors(_:)``).
    public func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredDescriptors.contains(descriptor)
    }

    /// Every service that this fake has discovered so far (with ``discoverServices(_:)`` or
    /// ``simulateDiscoveredServices(_:)``). The order is unspecified, as the protocol allows.
    /// Tests compare the results as sets.
    public var discoveredServices: [ServiceIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return Array(_discoveredServices)
    }

    /// Every characteristic that this fake has discovered under `service`. The order is
    /// unspecified.
    public func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredCharacteristics.filter { $0.service == service }
    }

    /// Every descriptor that this fake has discovered under `characteristic`. The order is
    /// unspecified.
    public func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredDescriptors.filter { $0.characteristic == characteristic }
    }

    /// Records the call. It delivers `didOpenL2CAPChannel` asynchronously on ``queue``, as
    /// ``l2capOpenBehavior`` defines. Success delivers a new ``FakeL2CAPChannel`` and stores it in
    /// ``lastOpenedL2CAPChannel``. Failure delivers the scripted error. `.hold` delivers nothing,
    /// for tests of open timeout and cancellation.
    public func openL2CAPChannel(_ psm: L2CAPPSM) {
        dispatchPrecondition(condition: .onQueue(queue))
        _openL2CAPChannelCalls.append(psm)
        switch _l2capOpenBehavior {
        case .succeed:
            let channel = FakeL2CAPChannel(psm: psm, queue: queue)
            _lastOpenedL2CAPChannel = channel
            queue.async { [self] in deliver(.didOpenL2CAPChannel(channel: channel, error: nil)) }
        case .fail(let error):
            queue.async { [self] in deliver(.didOpenL2CAPChannel(channel: nil, error: error)) }
        case .hold:
            break
        }
    }

    private func deliver(_ event: PeripheralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventHandler?(event)
    }
}
