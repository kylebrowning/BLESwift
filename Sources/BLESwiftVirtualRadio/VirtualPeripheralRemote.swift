//
//  VirtualPeripheralRemote.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import BLESwiftCompat17

/// A `PeripheralRemote` backed by a ``VirtualRadio`` device.
/// ``VirtualCentralBackend/retrievePeripherals(withIdentifiers:)`` vends it.
///
/// **Concurrency: the queue confines the state. A lock does not protect it.** Every stored property
/// is `nonisolated(unsafe)`. Code touches it only on ``queue``. Every `PeripheralRemote` method
/// asserts this at entry. GATT work reaches the radio actor through one serial chain of `Task`s.
/// See `enqueue(_:)`. The remote delivers every resulting event back with `queue.async`, never
/// inline.
///
/// ``name`` is the one exception. The radio fills it in asynchronously, and CoreBluetooth callers
/// read it off-queue, so a `Mutex` protects it.
public final class VirtualPeripheralRemote: PeripheralRemote, Sendable {

    /// The device identifier that this remote stands for.
    public let identifier: UUID

    /// The queue that confines every method and every event delivery.
    public let queue: DispatchQueue

    private let radio: VirtualRadio
    private let session: UUID
    private let nameBox: Mutex<String?>

    nonisolated(unsafe) private var _eventHandler: ((PeripheralEvent) -> Void)?
    nonisolated(unsafe) private var _connectionState: PeripheralConnectionState = .disconnected
    nonisolated(unsafe) private var _discoveredServices: Set<ServiceIdentifier> = []
    nonisolated(unsafe) private var _discoveredCharacteristics: Set<CharacteristicIdentifier> = []
    nonisolated(unsafe) private var _properties: [CharacteristicIdentifier: CharacteristicProperties] = [:]
    nonisolated(unsafe) private var _notifying: Set<CharacteristicIdentifier> = []

    /// The number of `.withoutResponse` writes that this remote gave to the radio and has not yet
    /// seen answered. Back-pressure comes from it, as a real `CBPeripheral` reports it from its
    /// transmit queue.
    nonisolated(unsafe) private var _inFlightWrites = 0

    /// The one-packet length that the device negotiated at the last connect.
    /// ``maximumWriteValueLength(for:)`` reports it for `.withoutResponse`. The default applies
    /// until a connection answers with the device's length. The remote keeps the last answer across
    /// a disconnect, by choice: the value describes the device, not the link, so code that sizes
    /// its chunks before it reconnects does not see a default that is wrong for that device.
    nonisolated(unsafe) private var _maximumWriteWithoutResponseLength = VirtualRadio.maximumWriteWithoutResponseLength

    /// Which connect attempt is current. The hop that answers an attempt checks it.
    ///
    /// A connect has two steps, the radio call and the hop that applies its answer, with a gap
    /// between them. A forced disconnect can land in that gap:
    ///
    /// 1. The forced disconnect settles this remote `.disconnected`.
    /// 2. The consumer connects again at once. A reconnecting `Central` does this, and so does the
    ///    provider's `CentralSession` when it resends a link client's connect.
    /// 3. The first attempt's hop finds the remote `.connecting` for the *second* attempt.
    /// 4. The hop would mark the remote `.connected`, with the first attempt's name and length,
    ///    while the radio holds nothing.
    ///
    /// Every attempt takes a new token (``beginConnectAttempt()``), and its hop applies nothing
    /// unless the token is still current. A cancel does not take a token, so a cancel queued behind
    /// a connect still gets that connect's `didConnect`, then its own `didDisconnect`. The one
    /// exception is a cancel that catches an attempt still sleeping out its device's connect delay.
    /// See ``invalidateConnectAttempt()``.
    nonisolated(unsafe) private var _connectAttempt: UInt64 = 0

    /// The task that sleeps out the device's ``VirtualLatency/connect`` delay for the current
    /// attempt. The value is `nil` when no attempt is delayed: the attempt reached the radio, was
    /// cancelled, or had no delay.
    ///
    /// It lives here and not in the backend's serial chain. A cancel queued behind a delayed
    /// attempt would otherwise wait out the whole delay and then see a `didConnect` that it asked
    /// to prevent. Only the attempt's hop and
    /// ``VirtualCentralBackend/cancelPeripheralConnection(_:)`` clear it.
    nonisolated(unsafe) private var _pendingConnect: Task<Void, Never>?

    /// The token of the current connect attempt. Call this on ``queue``.
    var connectAttempt: UInt64 {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectAttempt
    }

    /// Starts a new connect attempt and returns its token. This invalidates every earlier attempt's
    /// hop. Call this on ``queue``.
    func beginConnectAttempt() -> UInt64 {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectAttempt += 1
        return _connectAttempt
    }

    /// Invalidates the current connect attempt and does not start another. The hop of an attempt in
    /// flight finds its token stale and applies nothing. Call this on ``queue``.
    ///
    /// **This is the only place where a non-connect bumps the token.** A cancel normally leaves the
    /// token alone, so a cancel queued behind a connect still gets that connect's `didConnect`
    /// before its own `didDisconnect`.
    ///
    /// A cancel that catches an attempt still sleeping out its connect delay is different. The
    /// attempt never reached the radio, and the cancel settles the remote itself. An attempt whose
    /// sleep already ended has its hop queued behind this cancel, and that hop must not enqueue a
    /// connect that the caller just withdrew.
    func invalidateConnectAttempt() {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectAttempt += 1
    }

    /// The task that sleeps out the current attempt's connect delay, if any. A set replaces the
    /// previous task without cancelling it. ``cancelPendingConnect()`` cancels. Call this on
    /// ``queue``.
    var pendingConnect: Task<Void, Never>? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _pendingConnect
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _pendingConnect = newValue
        }
    }

    /// Whether a connect attempt still sleeps out its delay. Call this on ``queue``.
    ///
    /// This is a test hook, not API. A test uses it to assert that a cancel, or an attempt's hop,
    /// left no delayed attempt behind.
    package var hasPendingConnect: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _pendingConnect != nil
    }

    /// Cancels the task that sleeps out the current attempt's connect delay, and clears it, so the
    /// attempt never reaches the radio. It does nothing when nothing is pending. Call this on
    /// ``queue``.
    func cancelPendingConnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        _pendingConnect?.cancel()
        _pendingConnect = nil
    }

    /// The serial chain of radio work that this remote queued. Swift gives no ordering between
    /// independent `Task`s, so without the chain two writes in a row, or a `setNotifyValue(true)`
    /// and the write that triggers the notification it arms, could reach the actor in either order.
    /// Every radio call is appended to this chain.
    nonisolated(unsafe) private var _work: Task<Void, Never>?

    /// Creates a remote for `identifier`, served by `radio` under `session`.
    init(identifier: UUID, radio: VirtualRadio, session: UUID, queue: DispatchQueue, name: String?) {
        self.identifier = identifier
        self.radio = radio
        self.session = session
        self.queue = queue
        self.nameBox = Mutex(name)
    }

    /// The device's name, filled in from the radio when it is known.
    public var name: String? {
        nameBox.withLock { $0 }
    }

    /// Updates the cached ``name``. ``VirtualCentralBackend`` calls this after the radio answers
    /// with the device's real name.
    func updateName(_ name: String?) {
        guard let name else { return }
        nameBox.withLock { $0 = name }
    }

    /// Records the one-packet length that the device answered a connect with.
    /// ``VirtualCentralBackend`` calls this before it marks the remote `.connected`, so the value
    /// is in place when the backend delivers `didConnect`. Call this on ``queue``.
    func updateMaximumWriteWithoutResponseLength(_ length: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        _maximumWriteWithoutResponseLength = length
    }

    /// Whether `candidate` is the session identifier of the backend that vended this remote.
    ///
    /// ``VirtualCentralBackend/connect(_:options:requiresANCS:)`` uses this ownership test and not
    /// a table lookup, because the remote cap can invalidate a lookup under a caller that still
    /// holds a valid remote.
    func isOwned(by candidate: UUID) -> Bool { session == candidate }

    /// The identity of this remote as a ``BLESwiftCore/PeripheralIdentifier``.
    var peripheralIdentifier: PeripheralIdentifier {
        PeripheralIdentifier(uuid: identifier, name: name)
    }

    /// Delivers `event` to ``eventHandler``. Call this on ``queue``.
    ///
    /// A `didModifyServices` prunes the caches as it passes, so a remote whose device dropped a
    /// service stops reporting that service, and everything under it, as discovered.
    /// `LinkPeripheral` and CoreBluetooth's `CBPeripheral.services` do the same.
    func deliver(_ event: PeripheralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        if case .didModifyServices(let invalidated) = event { prune(Set(invalidated)) }
        _eventHandler?(event)
    }

    /// Appends `body` to the serial chain of radio work, so it runs after every earlier operation.
    /// Call this on ``queue``.
    private func enqueue(_ body: @escaping @Sendable () async -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = _work
        _work = Task {
            await previous?.value
            await body()
        }
    }

    /// Suspends until every piece of radio work that this remote queued so far has run. This is the
    /// chain's tail at the moment this method reads it on ``queue``. It does not await the
    /// deliveries that the chain hopped onto the queue. To flush them, run an empty block on the
    /// queue afterward. It mirrors ``VirtualCentralBackend/waitForPendingWork()``.
    ///
    /// This is a test hook, not API. A test uses it to assert on what a delayed GATT request left
    /// behind after its delay ran out and the radio answered it.
    package func waitForPendingWork() async {
        let work = await withCheckedContinuation { (continuation: CheckedContinuation<Task<Void, Never>?, Never>) in
            queue.async { continuation.resume(returning: self._work) }
        }
        await work?.value
    }

    /// Records a connection-state transition. Call this on ``queue``.
    ///
    /// A transition to `.disconnected` empties every discovery cache and the notification set, as
    /// `LinkPeripheral.markDisconnected()` and CoreBluetooth's `CBPeripheral.services` do. The
    /// handles of a disconnected peripheral's database are gone. If the remote kept reporting them
    /// as discovered, a read, a write, or a `setNotifyValue(_:for:)` would pass the discovery guard
    /// and reach a radio that has no connection left to serve it.
    func setConnectionState(_ state: PeripheralConnectionState) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionState = state
        if state == .disconnected {
            _discoveredServices.removeAll()
            _discoveredCharacteristics.removeAll()
            _properties.removeAll()
            _notifying.removeAll()
        }
    }

    /// Records the answer to a service discovery. Call this on ``queue``.
    ///
    /// **A filtered answer joins the cache. Only an unfiltered answer replaces it.**
    ///
    /// The answer to `discoverServices([x])` describes `x` and says nothing about any other
    /// service. Pruning on it would discard services that the device still has, and the
    /// characteristics discovered under them.
    ///
    /// `GATTCompatibility.discovery` is `.filtered` by default, so `Central` asks for one service
    /// at a time. Without this rule, a read under a second service pruned the first service's
    /// characteristics here while the client's cache still held them. The next read under the first
    /// service failed the discovery guard of ``readValue(for:)-(CharacteristicIdentifier)`` and was
    /// never answered.
    ///
    /// The answer to `discoverServices(nil)` describes the whole database, so a service missing
    /// from it is gone and the code prunes it. `didModifyServices` and a disconnection prune as
    /// before.
    ///
    /// - Parameters:
    ///   - services: The services that the radio answered with.
    ///   - filtered: Whether the request named the services that it wanted.
    private func recordServices(_ services: [ServiceIdentifier], filtered: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        let discovered = Set(services)
        guard !filtered else {
            _discoveredServices.formUnion(discovered)
            return
        }
        let departed = _discoveredServices.subtracting(discovered)
        _discoveredServices = discovered
        prune(departed)
    }

    /// Drops `services` and everything beneath them from the caches, as
    /// `LinkPeripheral.invalidate(services:)` does on a `didModifyServices`. Call this on
    /// ``queue``.
    private func prune(_ services: Set<ServiceIdentifier>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !services.isEmpty else { return }
        _discoveredServices.subtract(services)
        _discoveredCharacteristics = _discoveredCharacteristics.filter { !services.contains($0.service) }
        _properties = _properties.filter { !services.contains($0.key.service) }
        _notifying = _notifying.filter { !services.contains($0.service) }
    }

    /// Translates a GATT-layer failure into the `NSError` that CoreBluetooth would report.
    static func error(for attError: ATTError) -> NSError {
        NSError(domain: "CBATTErrorDomain", code: attError.rawValue)
    }

    // MARK: - PeripheralRemote

    /// Receives every `PeripheralEvent` this remote produces, on ``queue``.
    public var eventHandler: ((PeripheralEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
        }
    }

    /// The remote's connection state, as the owning backend tracks it.
    public var connectionState: PeripheralConnectionState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectionState
    }

    /// Always `false`. The virtual radio has no ANCS.
    public var ancsAuthorized: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return false
    }

    /// Whether fewer than `LinkFlowControl.writeWithoutResponseWindow` `.withoutResponse` writes
    /// still wait on the radio.
    ///
    /// **A virtual radio does apply back-pressure**, although it has no transmit queue.
    ///
    /// A hosted `PeripheralHost` answers each write over its own link, and each write parks for up
    /// to ``VirtualRadio/attTimeout``. If the radio never refused a write, a central session's
    /// `drainWrites` would hand every queued write straight through, and the serial chain behind
    /// this remote would grow without bound against a slow host. `maximumPendingWrites` bounds
    /// exactly this growth and could never reach it. The same window that the link's clients honor
    /// bounds the writes here.
    public var canSendWriteWithoutResponse: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _inFlightWrites < LinkFlowControl.writeWithoutResponseWindow
    }

    /// Asks the radio for `services`, or for every service when `services` is `nil`. It delivers
    /// `didDiscoverServices` after the answer lands.
    ///
    /// **The answer to a filtered request joins the cache. The answer to an unfiltered request
    /// replaces it.** `LinkPeripheral` does the same. See `recordServices(_:filtered:)`.
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let filtered = services != nil
        enqueue { [radio, identifier, queue] in
            let found = await radio.services(of: identifier, matching: services)
            queue.async { [self] in
                recordServices(found, filtered: filtered)
                deliver(.didDiscoverServices(error: nil))
            }
        }
    }

    /// Asks the radio for the characteristics of `service`. It delivers
    /// `didDiscoverCharacteristics` after the answer lands, and caches each characteristic's
    /// advertised properties.
    ///
    /// The method does nothing for a service that this remote has not discovered: it sends nothing
    /// and no completion arrives. `LinkPeripheral.discoverCharacteristics(_:for:)` and
    /// CoreBluetooth do the same, because `CBPeripheral` takes a `CBService` that it vended.
    /// Answering anyway would make the two backends behind one seam disagree about what a caller
    /// may ask for.
    public func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discoveredServices.contains(service) else { return }
        enqueue { [radio, identifier, queue] in
            let found = await radio.characteristics(of: identifier, service: service, matching: characteristics)
            queue.async { [self] in
                // Replace this service's entries only, as
                // `LinkPeripheral.replaceCharacteristics(_:for:)` does.
                _discoveredCharacteristics = _discoveredCharacteristics.filter { $0.service != service }
                _properties = _properties.filter { $0.key.service != service }
                for characteristic in found {
                    _discoveredCharacteristics.insert(characteristic.identifier)
                    _properties[characteristic.identifier] = characteristic.properties
                }
                deliver(.didDiscoverCharacteristics(service: service, error: nil))
            }
        }
    }

    /// Reads `characteristic` through the radio and delivers the result as `didUpdateValue`. The
    /// method does nothing for a characteristic that this remote has not discovered: it sends
    /// nothing and no completion arrives. The seam specifies this, and the CoreBluetooth shim does
    /// the same because CoreBluetooth has no object to give to its `readValue(for:)`.
    public func readValue(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discoveredCharacteristics.contains(characteristic) else { return }
        enqueue { [radio, identifier, session, queue] in
            let result = await radio.read(device: identifier, characteristic: characteristic, offset: 0, session: session)
            queue.async { [self] in
                switch result {
                case .success(let value):
                    deliver(.didUpdateValue(characteristic: characteristic, value: value, error: nil))
                case .failure(let attError):
                    deliver(.didUpdateValue(characteristic: characteristic, value: nil, error: Self.error(for: attError)))
                }
            }
        }
    }

    /// Writes `data` through the radio. A `.withResponse` write delivers `didWriteValue` after the
    /// device's handler answers. A `.withoutResponse` write delivers nothing, as in CoreBluetooth.
    /// The method does nothing for a characteristic that this remote has not discovered, as
    /// ``readValue(for:)-(CharacteristicIdentifier)`` does.
    ///
    /// The radio refuses a write that is longer than ``maximumWriteValueLength(for:)`` permits:
    ///
    /// - A `.withResponse` write fails with `ATTError.invalidAttributeValueLength`.
    /// - A `.withoutResponse` write is dropped and nothing is reported, as CoreBluetooth drops a
    ///   write that is too large for one ATT packet.
    ///
    /// A `.withoutResponse` write occupies a slot in this remote's window until the radio answers
    /// it. Releasing the slot raises `PeripheralEvent.isReadyToSendWriteWithoutResponse`. A caller
    /// must wait for this signal when ``canSendWriteWithoutResponse`` is `false`.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discoveredCharacteristics.contains(characteristic) else { return }
        if type == .withoutResponse { _inFlightWrites += 1 }
        enqueue { [radio, identifier, session, queue] in
            let result = await radio.write(
                device: identifier,
                characteristic: characteristic,
                value: data,
                type: type,
                session: session
            )
            queue.async { [self] in
                guard type == .withResponse else {
                    releaseWriteSlot()
                    return
                }
                switch result {
                case .success:
                    deliver(.didWriteValue(characteristic: characteristic, error: nil))
                case .failure(let attError):
                    deliver(.didWriteValue(characteristic: characteristic, error: Self.error(for: attError)))
                }
            }
        }
    }

    /// Releases the window slot that one answered `.withoutResponse` write held. It raises
    /// `isReadyToSendWriteWithoutResponse` on the transition that reopens the window. Call this on
    /// ``queue``.
    ///
    /// Only the transition raises it, as CoreBluetooth raises the event when a full queue drains,
    /// not for each write.
    private func releaseWriteSlot() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _inFlightWrites > 0 else { return }
        _inFlightWrites -= 1
        if _inFlightWrites == LinkFlowControl.writeWithoutResponseWindow - 1 {
            deliver(.isReadyToSendWriteWithoutResponse)
        }
    }

    /// Records the new notification state immediately, so a racing read sees it, as CoreBluetooth's
    /// `isNotifying` would. The method forwards the change to the radio and delivers
    /// `didUpdateNotificationState` after the change lands. For a characteristic that this remote
    /// has not discovered, it does nothing and records nothing, as
    /// ``readValue(for:)-(CharacteristicIdentifier)`` does.
    ///
    /// The radio can refuse a request, for example for a characteristic that declares neither
    /// `notify` nor `indicate`. The method then delivers the unchanged notification state with the
    /// refusal's `ATTError`, as CoreBluetooth does for a CCCD write that hardware rejected.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discoveredCharacteristics.contains(characteristic) else { return }
        if enabled {
            _notifying.insert(characteristic)
        } else {
            _notifying.remove(characteristic)
        }
        enqueue { [radio, identifier, session, queue] in
            // Use the radio's answer, not the request. If the radio holds no connection for the
            // session, it arms nothing, and reporting `enabled` would claim a subscription that
            // does not exist.
            let outcome = await radio.setNotify(
                enabled, device: identifier, characteristic: characteristic, session: session
            )
            queue.async { [self] in
                // Arm the characteristic only while it is still discovered. The answer can land
                // after a `didModifyServices` pruned its service, and an insert would leave the
                // remote notifying on a characteristic that is gone.
                if outcome.isNotifying, _discoveredCharacteristics.contains(characteristic) {
                    _notifying.insert(characteristic)
                } else {
                    _notifying.remove(characteristic)
                }
                deliver(
                    .didUpdateNotificationState(
                        characteristic: characteristic,
                        isNotifying: outcome.isNotifying,
                        error: outcome.error.map(Self.error(for:))
                    )
                )
            }
        }
    }

    /// Delivers `didDiscoverDescriptors` with nothing discovered. Virtual devices expose no
    /// descriptors.
    ///
    /// The answer comes from the serial chain, not the next queue turn, although this backend asks
    /// the radio nothing. A bare `queue.async` runs *before* any radio round-trip already in
    /// flight, so a `discoverCharacteristics` and the `discoverDescriptors` behind it would
    /// complete out of call order. CoreBluetooth cannot produce that order. See `enqueue(_:)`.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [queue] in
            queue.async { [self] in
                deliver(.didDiscoverDescriptors(characteristic: characteristic, error: nil))
            }
        }
    }

    /// Does nothing. No descriptor is ever discovered on a virtual device, and the protocol
    /// specifies no action for an undiscovered target.
    public func readValue(for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// Does nothing, for the same reason as ``readValue(for:)-(DescriptorIdentifier)``.
    public func writeValue(_ data: Data, for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// Delivers `didReadRSSI` with ``VirtualRadio/rssi``, from the serial chain, for the reason
    /// given at ``discoverDescriptors(for:)``.
    public func readRSSI() {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [queue] in
            queue.async { [self] in
                deliver(.didReadRSSI(VirtualRadio.rssi, error: nil))
            }
        }
    }

    /// The length ceiling for `type`. For a `.withResponse` write it is
    /// ``VirtualRadio/maximumValueLength``, which ATT long writes really reach. For a
    /// `.withoutResponse` write it is one ATT packet on hardware: the device's
    /// ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``, which the remote learns at
    /// connect. Before the first connect it is ``VirtualRadio/maximumWriteWithoutResponseLength``.
    /// The radio enforces both.
    public func maximumWriteValueLength(for type: WriteType) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        switch type {
        case .withResponse: return VirtualRadio.maximumValueLength
        case .withoutResponse: return _maximumWriteWithoutResponseLength
        }
    }

    /// Whether `service` has been discovered on this remote.
    public func isDiscovered(_ service: ServiceIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredServices.contains(service)
    }

    /// Whether `characteristic` has been discovered on this remote.
    public func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredCharacteristics.contains(characteristic)
    }

    /// Always `false`. Virtual devices expose no descriptors.
    public func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return false
    }

    /// Whether `characteristic` currently has notifications enabled.
    public func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _notifying.contains(characteristic)
    }

    /// The properties that `characteristic` advertises, as discovery revealed them. The value is
    /// `[]` before the characteristic is discovered.
    public func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties {
        dispatchPrecondition(condition: .onQueue(queue))
        return _properties[characteristic] ?? []
    }

    /// Every service discovered on this remote so far.
    public var discoveredServices: [ServiceIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return Array(_discoveredServices)
    }

    /// Every characteristic discovered under `service` so far.
    public func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _discoveredCharacteristics.filter { $0.service == service }
    }

    /// Always empty. Virtual devices expose no descriptors.
    public func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return []
    }

    /// Fails the attempt, because the virtual radio serves GATT only and not L2CAP channels. The
    /// failure comes from the serial chain, for the reason given at ``discoverDescriptors(for:)``.
    public func openL2CAPChannel(_ psm: L2CAPPSM) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [queue] in
            queue.async { [self] in
                deliver(.didOpenL2CAPChannel(channel: nil, error: Self.l2capUnsupportedError))
            }
        }
    }

    /// The error every ``openL2CAPChannel(_:)`` attempt fails with.
    static var l2capUnsupportedError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "The virtual radio does not support L2CAP channels."]
        )
    }
}
