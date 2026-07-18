//
//  FakePeripheral.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation

/// A scriptable stand-in for `CBPeripheral`, conforming to `PeripheralRemote`.
///
/// `CBPeripheral` has no accessible public initializer and cannot be scripted in tests, so
/// `FakePeripheral` lets you drive GATT operations and script the events a real peripheral
/// would eventually deliver via its delegate.
///
/// **Concurrency — queue-confined, not lock-protected.** See ``FakeCentral``'s doc comment
/// for the full rationale; the same invariant holds here: every stored property is
/// `nonisolated(unsafe)`, safe only because every CB-mirroring method (the
/// `PeripheralRemote` conformance) and every property getter/setter asserts
/// `dispatchPrecondition(condition: .onQueue(queue))` at entry and then touches state
/// inline — no `queue.sync` anywhere in this type. ``onQueue(_:)``, the only sanctioned
/// door for off-queue code, hops on asynchronously (`queue.async` + an awaited
/// continuation, never a thread-parking `queue.sync`; see its docs and issue #13). Event
/// delivery is always `queue.async`, never inline from a "simulate" call.
public final class FakePeripheral: PeripheralRemote, Sendable {

    /// The identifier CoreBluetooth would assign this peripheral. Immutable, so it needs
    /// no queue confinement.
    public let identifier: UUID

    /// The peripheral's advertised or cached name. Immutable, so it needs no queue
    /// confinement — `FakePeripheral` doesn't currently support scripting a name change.
    public let name: String?

    /// The queue every CB-mirroring method and event delivery is confined to.
    public let queue: DispatchSerialQueue

    nonisolated(unsafe) private var _connectionState: PeripheralConnectionState
    nonisolated(unsafe) private var _canSendWriteWithoutResponse: Bool
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
    ///   - identifier: The peripheral's identifier. Defaults to a fresh `UUID`.
    ///   - name: The peripheral's advertised/cached name.
    ///   - state: The initial `PeripheralConnectionState`. Defaults to `.disconnected`.
    ///   - canSendWriteWithoutResponse: The initial back-pressure state. Defaults to
    ///     `true` (ready).
    ///   - queue: The queue every CB-mirroring method and event delivery is confined to.
    public init(
        identifier: UUID = UUID(),
        name: String? = "Fake Peripheral",
        state: PeripheralConnectionState = .disconnected,
        canSendWriteWithoutResponse: Bool = true,
        queue: DispatchSerialQueue
    ) {
        self.identifier = identifier
        self.name = name
        self._connectionState = state
        self._canSendWriteWithoutResponse = canSendWriteWithoutResponse
        self.queue = queue
    }

    /// This peripheral's identity as a `PeripheralIdentifier`. Reads only immutable
    /// state, so it needs no queue confinement.
    public var peripheralIdentifier: PeripheralIdentifier {
        PeripheralIdentifier(uuid: identifier, name: name)
    }

    /// Hops onto ``queue`` (via `queue.async` + a continuation) to run `body`, then returns
    /// its result — the only sanctioned way for off-queue code to configure this fake
    /// (``eventHandler``, scripted values) or read its counters/state for assertions.
    /// Because `queue` is serial, this also flushes every previously-scheduled `.async`
    /// event delivery before `body` runs.
    ///
    /// This is `async` and **never blocks the calling thread** — it does *not* use
    /// `queue.sync`, whose cooperative-thread parking under the parallel test runner is the
    /// deadlock fixed in issue #13 (see ``FakeCentral/onQueue(_:)`` for the full rationale).
    ///
    /// - Warning: Never `await` this from within an ``eventHandler`` callback, or from any
    ///   other code already executing on `queue` — the caller holds `queue` while awaiting a
    ///   `body` enqueued behind itself, a deadlock.
    public func onQueue<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// Receives every `PeripheralEvent` this fake delivers, on ``queue``. The
    /// `PeripheralRemote` protocol witness — configure via ``onQueue(_:)``. Every set
    /// (attach *and* `nil` clear) increments ``eventHandlerSetCount``.
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

    /// The number of times ``eventHandler`` has been set (attaches *and* `nil` clears).
    /// Replaces the old `attachEventTargetCallCount` — proves `Central` wires this
    /// peripheral's event delivery on every session-creating path before going live. Read
    /// via ``onQueue(_:)``.
    public var eventHandlerSetCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _eventHandlerSetCount
    }

    /// Characteristics currently "notifying", toggled by ``setNotifyValue(_:for:)``.
    public var notifyingCharacteristics: Set<CharacteristicIdentifier> {
        dispatchPrecondition(condition: .onQueue(queue))
        return _notifyingCharacteristics
    }

    /// Every ``setNotifyValue(_:for:)`` call this fake has received, in order — lets
    /// refcount-lifecycle tests assert exactly when notifications were enabled/disabled
    /// (e.g. enabled once for the first subscriber, disabled only when the last one goes
    /// away). Read via ``onQueue(_:)``.
    public var setNotifyValueCalls: [(characteristic: CharacteristicIdentifier, enabled: Bool)] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _setNotifyValueCalls
    }

    /// Invoked synchronously, on ``queue``, from inside ``writeValue(_:for:type:)`` —
    /// *before* the `didWriteValue` completion is enqueued. Lets you script a device that
    /// responds to a write instantly (e.g. by calling
    /// ``simulateNotification(for:value:error:)``, whose delivery then lands *ahead of*
    /// the write's own completion) — the hardest ordering for `writeAndAwaitNotification`'s
    /// no-loss-window guarantee. The closure runs on `queue`, so reading this fake's
    /// queue-confined state from it is legal; calling ``onQueue(_:)`` from it is the usual
    /// reentrant deadlock. Configure via ``onQueue(_:)``. `nil` (the default) does nothing.
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

    /// A cross-role **bridge hook** invoked synchronously, on ``queue``, from inside
    /// ``readValue(for:)`` — the seam ``FakeGATTBridge`` uses to route a central-side read to a
    /// remote ``FakePeripheralManager`` host. When non-`nil`, ``readValue(for:)`` fires this
    /// closure and returns **without** delivering its own `didUpdateValue` completion (bypassing
    /// ``scriptedReadValues`` and ``holdReadCompletions`` entirely): the bridge is then
    /// responsible for delivering the eventual completion via
    /// ``simulateNotification(for:value:error:)`` once the host answers. `nil` (the default)
    /// leaves ``readValue(for:)``'s original scripted behavior untouched. Configure via
    /// ``onQueue(_:)``.
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

    /// A cross-role **bridge hook** invoked synchronously, on ``queue``, from inside
    /// ``writeValue(_:for:type:)`` — the seam ``FakeGATTBridge`` uses to route a central-side
    /// write to a remote ``FakePeripheralManager`` host. Distinct from ``onWrite`` (an
    /// instant-response scripting seam that never suppresses completion): when this hook is
    /// non-`nil` **and** the write is `.withResponse`, ``writeValue(_:for:type:)`` fires this
    /// closure and returns **without** delivering its own `didWriteValue` completion — the
    /// bridge delivers it via ``simulateWriteCompletion(for:error:)`` once the host answers. A
    /// `.withoutResponse` write (which has no completion) still fires this hook but completes as
    /// usual. `nil` (the default) is unchanged behavior. Configure via ``onQueue(_:)``.
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

    /// A cross-role **bridge hook** invoked synchronously, on ``queue``, from inside
    /// ``setNotifyValue(_:for:)`` with the characteristic and its new enabled/disabled state —
    /// the seam ``FakeGATTBridge`` uses to forward a central-side subscribe (`true`) or
    /// unsubscribe (`false`) to a remote ``FakePeripheralManager`` host. This hook never
    /// suppresses anything: ``setNotifyValue(_:for:)`` still delivers its own
    /// `didUpdateNotificationState` completion (the central's local confirmation) as usual.
    /// `nil` (the default) is unchanged behavior. Configure via ``onQueue(_:)``.
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

    /// The value ``readValue(for:)`` reports back via `didUpdateValue`, keyed by
    /// characteristic. `nil` (no entry) reports back `nil` data. Configure via
    /// ``onQueue(_:)``.
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

    /// The default ``properties(of:)`` reports for any characteristic with no entry in
    /// ``scriptedProperties`` — `[.read, .write, .notify]`, the common capability set, chosen
    /// so pre-existing tests that never script properties keep observing a sensible value.
    public static let defaultProperties: CharacteristicProperties = [.read, .write, .notify]

    /// The ``CharacteristicProperties`` ``properties(of:)`` reports back, keyed by
    /// characteristic. A characteristic with no entry reports ``defaultProperties``
    /// (`[.read, .write, .notify]`), keeping existing tests unchanged. Configure via
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

    /// The value ``maximumWriteValueLength(for:)`` returns. Defaults to 20, the classic
    /// BLE ATT_MTU-3 default. Configure via ``onQueue(_:)``.
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

    /// The value ``readRSSI()`` reports back via `didReadRSSI`. Defaults to `-50`
    /// (this fake's original fixed placeholder value, preserved as the default so every
    /// pre-existing test that never scripts this keeps observing the same value). Configure
    /// via ``onQueue(_:)`` — lets a multi-peripheral test give distinct fakes distinct
    /// scripted RSSI values, so a concurrent `readRSSI()` on each can be asserted as
    /// resolving with the RIGHT peripheral's own value, not just "some" value.
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

    /// The number of times ``readValue(for:)`` has been called.
    public var readCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _readCallCount
    }

    /// The number of times ``writeValue(_:for:type:)`` has been called, keyed by
    /// characteristic.
    public var writeCallCounts: [CharacteristicIdentifier: Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _writeCallCounts
    }

    /// The number of times ``discoverServices(_:)`` has been called.
    public var discoverServicesCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoverServicesCallCount
    }

    /// Whether ``discoverServices(_:)`` withholds its `didDiscoverServices` completion
    /// instead of delivering it immediately — the service-discovery counterpart to
    /// ``holdReadCompletions``. `false` by default. Lets a test observe a *pending*
    /// enumeration (e.g. to disconnect out from under it), which this fake would otherwise
    /// complete within the same `queue.async` turn. Held completions are released, in FIFO
    /// order, by ``simulateNextHeldServiceDiscoveryCompletion()``. Configure via
    /// ``onQueue(_:)``.
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

    /// Delivers the oldest still-held `didDiscoverServices` completion (FIFO), if any. A
    /// no-op if none are held. The scripted-graph mutations that ``discoverServices(_:)``
    /// performs have already been applied (only the *completion event* was withheld), so the
    /// enumeration resumes seeing the fully-discovered graph.
    public func simulateNextHeldServiceDiscoveryCompletion() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard _heldServiceDiscoveryCount > 0 else { return }
            _heldServiceDiscoveryCount -= 1
            deliver(.didDiscoverServices(error: nil))
        }
    }

    /// The number of times ``discoverCharacteristics(_:for:)`` has been called.
    public var discoverCharacteristicsCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoverCharacteristicsCallCount
    }

    /// The GATT table this fake actually has, if scripted: keys are the services that
    /// genuinely exist, values are the characteristics that genuinely exist under each.
    /// `nil` (the default) keeps this fake's original permissive behavior — every
    /// ``discoverServices(_:)``/``discoverCharacteristics(_:for:)`` call unconditionally
    /// "succeeds" by revealing exactly what was requested, which is realistic for the happy
    /// path but makes `.missingService`/`.missingCharacteristic` structurally unreachable
    /// (a real peripheral's GATT table can simply not contain what was asked for; discovery
    /// still completes without error — CoreBluetooth just never adds the missing
    /// service/characteristic to `.services`/`.characteristics`). When non-`nil`,
    /// ``discoverServices(_:)`` only reveals requested services that are keys of this
    /// dictionary, and ``discoverCharacteristics(_:for:)`` only reveals requested
    /// characteristics present in that service's set — anything requested but absent is
    /// silently *not* added to the discovered-sets, exactly like real CoreBluetooth, letting
    /// `Central`'s post-discovery `isDiscovered(_:)` recheck genuinely fail. Configure via
    /// ``onQueue(_:)``.
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

    /// The value ``readValue(for:)`` reports back via `didUpdateValueForDescriptor`, keyed
    /// by descriptor. In permissive mode (``availableDescriptors`` is `nil`), scripting a
    /// value here also makes that descriptor "exist": ``discoverDescriptors(for:)`` reveals
    /// every scripted descriptor under the characteristic being discovered. A descriptor with
    /// no entry reports back empty `Data`. Configure via ``onQueue(_:)``.
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

    /// The descriptors this fake actually has, per characteristic — the descriptor
    /// counterpart to ``availableServices``. `nil` (the default) keeps the permissive
    /// behavior: ``discoverDescriptors(for:)`` reveals every descriptor scripted in
    /// ``scriptedDescriptorValues`` under the characteristic. When non-`nil`,
    /// ``discoverDescriptors(for:)`` reveals only the descriptors listed for that
    /// characteristic here — so a descriptor requested but absent stays undiscovered, exactly
    /// like real CoreBluetooth, letting `Central`'s post-discovery `isDiscovered(_:)` recheck
    /// genuinely fail with ``BLESwiftError/missingDescriptor(_:)``. Use this (rather than
    /// scripting a read value) to make a write-only descriptor exist. Configure via
    /// ``onQueue(_:)``.
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

    /// The number of times ``writeValue(_:for:)`` (the descriptor overload) has been called,
    /// keyed by descriptor. Read via ``onQueue(_:)``.
    public var descriptorWriteCallCounts: [DescriptorIdentifier: Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _descriptorWriteCallCounts
    }

    /// The most recent bytes written to each descriptor via ``writeValue(_:for:)`` (the
    /// descriptor overload). Read via ``onQueue(_:)``.
    public var writtenDescriptorValues: [DescriptorIdentifier: Data] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _writtenDescriptorValues
    }

    /// The number of times ``discoverDescriptors(for:)`` has been called.
    public var discoverDescriptorsCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoverDescriptorsCallCount
    }

    /// The number of times ``readValue(for:)`` (the descriptor overload) has been called.
    public var descriptorReadCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _descriptorReadCallCount
    }

    /// Whether ``readValue(for:)`` (the descriptor overload) withholds its
    /// `didUpdateValueForDescriptor` completion instead of delivering it immediately —
    /// the descriptor counterpart to ``holdReadCompletions``. `false` by default. Held
    /// completions are released by ``simulateNextHeldDescriptorReadCompletion()``. Configure
    /// via ``onQueue(_:)``.
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

    /// Delivers the oldest still-held descriptor-read completion (FIFO order), if any. A
    /// no-op if none are held.
    public func simulateNextHeldDescriptorReadCompletion() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !_heldDescriptorReads.isEmpty else { return }
            let (descriptor, value) = _heldDescriptorReads.removeFirst()
            deliver(.didUpdateValueForDescriptor(descriptor: descriptor, value: value, error: nil))
        }
    }

    /// Marks `descriptors` as discovered (along with their owning characteristic and
    /// service) without going through ``discoverDescriptors(for:)``/an event, for tests that
    /// need to seed descriptor discovery state directly. No event corresponds to this, so it
    /// seeds state on ``queue`` via `queue.async` (like the other `simulate*` calls); a
    /// later ``onQueue(_:)`` read observes it (FIFO on the serial queue).
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

    /// Simulates a connection-state change, asynchronously. Does not itself deliver an
    /// event — connection events are delivered by `FakeCentral`, which owns the
    /// connect/disconnect flow. Off-queue safe to call directly; flush with
    /// ``onQueue(_:)`` before asserting the new state.
    public func simulateStateChange(_ newState: PeripheralConnectionState) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _connectionState = newState
        }
    }

    /// Simulates CoreBluetooth signaling renewed write-without-response capacity and,
    /// asynchronously, delivers `PeripheralEvent.isReadyToSendWriteWithoutResponse` on
    /// ``queue``.
    public func simulateReadyToSendWriteWithoutResponse() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _canSendWriteWithoutResponse = true
            deliver(.isReadyToSendWriteWithoutResponse)
        }
    }

    /// Marks this peripheral as no longer able to accept a write-without-response until
    /// the next ``simulateReadyToSendWriteWithoutResponse()``. No event corresponds to
    /// this in CoreBluetooth (only the "ready again" signal is a delegate callback), so
    /// this seeds state on ``queue`` via `queue.async` (like the other `simulate*` calls)
    /// rather than delivering an event; a later ``onQueue(_:)`` read observes it.
    public func simulateWriteWithoutResponseBackPressure() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _canSendWriteWithoutResponse = false
        }
    }

    /// Simulates a notification (or an out-of-band read completion) by, asynchronously,
    /// delivering `PeripheralEvent.didUpdateValue(characteristic:value:error:)` on
    /// ``queue``.
    public func simulateNotification(for characteristic: CharacteristicIdentifier, value: Data?, error: NSError? = nil) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didUpdateValue(characteristic: characteristic, value: value, error: error))
        }
    }

    /// Simulates the completion of an in-flight write by, asynchronously, delivering
    /// `PeripheralEvent.didWriteValue(characteristic:error:)` on ``queue``.
    ///
    /// The counterpart to ``simulateNotification(for:value:error:)`` for writes: it exists so a
    /// cross-role bridge (``FakeGATTBridge``) can deliver a `.withResponse` write's completion
    /// *after* a remote ``FakePeripheralManager`` host has answered the corresponding
    /// ``WriteRequest`` — the write having been suppressed from auto-completing via
    /// ``onWriteRequest``. Off-queue safe to call directly; flush with ``onQueue(_:)`` before
    /// asserting the completion landed.
    public func simulateWriteCompletion(for characteristic: CharacteristicIdentifier, error: NSError? = nil) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            deliver(.didWriteValue(characteristic: characteristic, error: error))
        }
    }

    /// Marks `services` as discovered without going through ``discoverServices(_:)``/an
    /// event, for tests that need to seed discovery state directly. No event corresponds
    /// to this, so it seeds state on ``queue`` via `queue.async` (like the other `simulate*`
    /// calls); a later ``onQueue(_:)`` read observes it (FIFO on the serial queue).
    public func simulateDiscoveredServices(_ services: [ServiceIdentifier]) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _discoveredServices.formUnion(services)
        }
    }

    /// Marks `characteristics` as discovered on `service` without going through
    /// ``discoverCharacteristics(_:for:)``/an event.
    public func simulateDiscoveredCharacteristics(_ characteristics: [CharacteristicIdentifier], for service: ServiceIdentifier) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _discoveredServices.insert(service)
            _discoveredCharacteristics.formUnion(characteristics)
        }
    }

    /// Simulates CoreBluetooth invalidating `invalidatedServices` — and, with them, any
    /// characteristics previously discovered under those services — then, asynchronously,
    /// delivers `didModifyServices` on ``queue``.
    ///
    /// A real `CBPeripheral` removes invalidated services from its own `.services` array as
    /// part of reporting `didModifyServices`, so `isDiscovered(_:)` reflects the
    /// invalidation automatically with no separate BLESwift-side cache to invalidate (see
    /// `PeripheralRemote`'s doc comment on the discovery cache). `FakePeripheral`'s
    /// discovered-sets are its own bookkeeping rather than CoreBluetooth's, so this mirrors
    /// that removal explicitly — proving that a later re-discovery is required after
    /// `didModifyServices` is exactly what this fake's tests exercise.
    public func simulateServiceModification(invalidatedServices: [ServiceIdentifier]) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            _discoveredServices.subtract(invalidatedServices)
            _discoveredCharacteristics = _discoveredCharacteristics.filter { !invalidatedServices.contains($0.service) }
            deliver(.didModifyServices(invalidatedServices))
        }
    }

    /// Mirrors one hosted `GATTService` into this fake's queue-confined discovery state — the
    /// central-side counterpart a cross-role bridge (``FakeGATTBridge``) drives from a remote
    /// ``FakePeripheralManager`` host's `onAddService` hook, so the central discovers exactly the
    /// services and characteristics (with their properties) the host actually published.
    ///
    /// **Off-queue safe.** Like the other `simulate*` methods, this hops onto ``queue`` itself
    /// (via `queue.async`) rather than requiring the caller already be on it — so the bridge can
    /// call it directly from the *host's* queue (a distinct serial queue) without an ``onQueue(_:)``
    /// round trip. The whole read-modify-write of ``availableServices``/``scriptedProperties``
    /// runs inside that one `queue.async`, so it is atomic on ``queue`` and composes with any
    /// concurrently mirrored service. Flush with ``onQueue(_:)`` before asserting the result.
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
        /// Vend a fresh ``FakeL2CAPChannel`` and deliver a successful
        /// `didOpenL2CAPChannel`. The default.
        case succeed
        /// Deliver a failing `didOpenL2CAPChannel` carrying `error` and no channel.
        case fail(NSError)
        /// Record the call but deliver nothing — for exercising open timeout / cancellation.
        case hold
    }

    /// How ``openL2CAPChannel(_:)`` responds. Defaults to ``L2CAPOpenBehavior/succeed``.
    /// Configure via ``onQueue(_:)``.
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

    /// Every `L2CAPPSM` ``openL2CAPChannel(_:)`` was called with, in order. Read via
    /// ``onQueue(_:)``.
    public var openL2CAPChannelCalls: [L2CAPPSM] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _openL2CAPChannelCalls
    }

    /// The most recent ``FakeL2CAPChannel`` this fake vended from a `.succeed`
    /// ``openL2CAPChannel(_:)`` — use it to drive `simulateInbound`/inspect `writtenData` on
    /// the channel the `Central` actually handed back. Read via ``onQueue(_:)``. `nil` if no
    /// channel has been vended (or the last open failed / was held).
    public var lastOpenedL2CAPChannel: FakeL2CAPChannel? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _lastOpenedL2CAPChannel
    }

    // MARK: - PeripheralRemote

    /// The peripheral's current connection state.
    public var connectionState: PeripheralConnectionState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectionState
    }

    /// Whether this fake is currently able to accept a write-without-response.
    public var canSendWriteWithoutResponse: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _canSendWriteWithoutResponse
    }

    /// Records the call and asynchronously delivers `didDiscoverServices` on ``queue``.
    ///
    /// If ``availableServices`` is `nil` (the default), unconditionally marks `services`
    /// (or nothing, if `nil`) as discovered — the original permissive behavior. If
    /// ``availableServices`` is set, only marks requested services that are actually keys
    /// of it as discovered; a requested service absent from ``availableServices`` is never
    /// added, exactly like real CoreBluetooth silently not adding a nonexistent service to
    /// `.services`.
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        _discoverServicesCallCount += 1
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

    /// Records the call and asynchronously delivers `didDiscoverCharacteristics` on
    /// ``queue``.
    ///
    /// If ``availableServices`` is `nil` (the default), unconditionally marks
    /// `characteristics` (or nothing, if `nil`) as discovered on `service` — the original
    /// permissive behavior. If ``availableServices`` is set, only marks requested
    /// characteristics that actually appear in `service`'s set as discovered; a requested
    /// characteristic absent from that set is never added, exactly like real CoreBluetooth
    /// silently not adding a nonexistent characteristic to a service's `.characteristics`.
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

    /// Records the call and, unless ``holdReadCompletions`` is `true`, asynchronously
    /// delivers `didUpdateValue` on ``queue`` with the value scripted in
    /// ``scriptedReadValues`` for `characteristic` (`nil` if none). While held, the pending
    /// completion queues up for ``simulateNextHeldReadCompletion()`` to deliver later —
    /// use this to observe work queued behind an in-flight read (e.g. per-characteristic
    /// FIFO ordering), which this fake would otherwise complete too quickly (within the
    /// same `queue.async` turn) to observe.
    public func readValue(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _readCallCount += 1
        // A bridged read routes to a remote host instead of completing from scripted state:
        // fire the hook and let the bridge deliver the completion later (see ``onReadRequest``).
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

    /// Whether ``readValue(for:)`` withholds its `didUpdateValue` completion instead of
    /// delivering it immediately. `false` by default (every read completes right away, as
    /// every other operation on this fake does). Configure via ``onQueue(_:)``.
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

    /// Delivers the oldest still-held read completion (FIFO order among held reads), if
    /// any. A no-op if none are held.
    public func simulateNextHeldReadCompletion() {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !_heldReads.isEmpty else { return }
            let (characteristic, value) = _heldReads.removeFirst()
            deliver(.didUpdateValue(characteristic: characteristic, value: value, error: nil))
        }
    }

    /// Records the call, invokes ``onWrite`` (synchronously, so anything it enqueues —
    /// e.g. a scripted response notification — lands ahead of the write's own completion),
    /// and asynchronously delivers `didWriteValue` on ``queue``.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        dispatchPrecondition(condition: .onQueue(queue))
        _writeCallCounts[characteristic, default: 0] += 1
        _onWrite?(characteristic, data)
        if let onWriteRequest = _onWriteRequest {
            onWriteRequest(characteristic, data, type)
            // A bridged `.withResponse` write's completion is delivered by the bridge once the
            // remote host answers (via ``simulateWriteCompletion(for:error:)``), so it must not
            // also auto-complete here. `.withoutResponse` has no completion, so it falls
            // through unchanged.
            if type == .withResponse { return }
        }
        queue.async { [self] in deliver(.didWriteValue(characteristic: characteristic, error: nil)) }
    }

    /// Records whether `characteristic` is now notifying (and the call itself, in
    /// ``setNotifyValueCalls``) and asynchronously delivers `didUpdateNotificationState`
    /// on ``queue``.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _setNotifyValueCalls.append((characteristic, enabled))
        if enabled {
            _notifyingCharacteristics.insert(characteristic)
        } else {
            _notifyingCharacteristics.remove(characteristic)
        }
        // Forward the subscribe/unsubscribe to a remote host, if bridged (see
        // ``onSubscriptionChange``). Never suppresses the local confirmation below.
        _onSubscriptionChange?(characteristic, enabled)
        queue.async { [self] in
            deliver(.didUpdateNotificationState(characteristic: characteristic, isNotifying: enabled, error: nil))
        }
    }

    /// Records the call and asynchronously delivers `didDiscoverDescriptors` on ``queue``.
    ///
    /// If ``availableDescriptors`` is `nil` (the default), reveals every descriptor scripted
    /// in ``scriptedDescriptorValues`` under `characteristic` — the permissive behavior. If
    /// ``availableDescriptors`` is set, reveals only the descriptors listed for
    /// `characteristic` there; anything absent is never added, exactly like real
    /// CoreBluetooth silently not adding a nonexistent descriptor to `.descriptors`.
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

    /// Records the call and, unless ``holdDescriptorReadCompletions`` is `true`,
    /// asynchronously delivers `didUpdateValueForDescriptor` on ``queue`` with the value
    /// scripted in ``scriptedDescriptorValues`` for `descriptor` (empty `Data` if none).
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

    /// Records the call (and the written bytes) and asynchronously delivers
    /// `didWriteValueForDescriptor` on ``queue``.
    public func writeValue(_ data: Data, for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _descriptorWriteCallCounts[descriptor, default: 0] += 1
        _writtenDescriptorValues[descriptor] = data
        queue.async { [self] in deliver(.didWriteValueForDescriptor(descriptor: descriptor, error: nil)) }
    }

    /// Asynchronously delivers `didReadRSSI` on ``queue`` with ``scriptedRSSI``.
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

    /// Whether `service` has been discovered (via ``discoverServices(_:)`` or
    /// ``simulateDiscoveredServices(_:)``).
    public func isDiscovered(_ service: ServiceIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredServices.contains(service)
    }

    /// Whether `characteristic` has been discovered (via ``discoverCharacteristics(_:for:)``
    /// or ``simulateDiscoveredCharacteristics(_:for:)``).
    public func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredCharacteristics.contains(characteristic)
    }

    /// Whether `characteristic` is currently notifying (toggled by
    /// ``setNotifyValue(_:for:)``). Tests seed a "currently notifying" characteristic by
    /// calling `setNotifyValue(true, for:)` directly.
    public func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _notifyingCharacteristics.contains(characteristic)
    }

    /// The scripted ``CharacteristicProperties`` for `characteristic` (see
    /// ``scriptedProperties``), or ``defaultProperties`` (`[.read, .write, .notify]`) if none
    /// was scripted. Unlike real CoreBluetooth, this does not gate on discovery — tests seed
    /// discovery separately; scripting properties for a characteristic is enough for
    /// ``properties(of:)`` to report them.
    public func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties {
        dispatchPrecondition(condition: .onQueue(queue))
        return _scriptedProperties[characteristic] ?? Self.defaultProperties
    }

    /// Whether `descriptor` has been discovered (via ``discoverDescriptors(for:)`` or
    /// ``simulateDiscoveredDescriptors(_:)``).
    public func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredDescriptors.contains(descriptor)
    }

    /// Every service this fake has discovered so far (via ``discoverServices(_:)`` or
    /// ``simulateDiscoveredServices(_:)``). Order is unspecified (a `Set` drives it), matching
    /// the protocol contract — enumeration tests compare as sets.
    public var discoveredServices: [ServiceIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return Array(_discoveredServices)
    }

    /// Every characteristic this fake has discovered under `service`. Order is unspecified.
    public func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredCharacteristics.filter { $0.service == service }
    }

    /// Every descriptor this fake has discovered under `characteristic`. Order is unspecified.
    public func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredDescriptors.filter { $0.characteristic == characteristic }
    }

    /// Records the call and, per ``l2capOpenBehavior``, asynchronously delivers
    /// `didOpenL2CAPChannel` on ``queue`` — a success carrying a fresh ``FakeL2CAPChannel``
    /// (also stashed in ``lastOpenedL2CAPChannel``), a failure carrying the scripted error,
    /// or nothing at all (`.hold`, for open timeout / cancellation tests).
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
