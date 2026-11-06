//
//  LinkPeripheral.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import BLESwiftCompat17

/// A `PeripheralRemote` whose GATT operations travel over the link to a real `CBPeripheral` on a
/// provider. A local mirror of the peripheral's discovery state backs it.
///
/// Code never creates one directly. ``LinkCentral`` owns the table of them. It gives the same
/// instance for an identifier every time.
///
/// - A mirror does not prove that the peripheral exists.
///   ``LinkCentral/retrievePeripherals(withIdentifiers:)`` returns a placeholder for any
///   identifier. An unknown identifier fails at the connect with `didFailToConnect`, domain
///   `BLESwiftProvider`, code `1`.
/// - Call every member on `queue`, except ``name``. A `Mutex` protects ``name``.
/// - The mirror is current when its `PeripheralEvent` arrives.
///
/// For the full rules, see <doc:BLESwiftSimulatorLink#Peripherals-that-the-link-did-not-see>.
public final class LinkPeripheral: PeripheralRemote, Sendable {

    /// The identifier that the provider's CoreBluetooth stack uses for this peripheral.
    public let identifier: UUID

    /// The central that owns this peripheral and carries its requests. It is `unowned` because
    /// the central owns the table in which this peripheral lives, so the peripheral cannot
    /// outlive its central. `Central` retains the backend (its `manager`) for at least as long
    /// as any `PeripheralRemote` that the backend gives out. Thus this reference can never
    /// dangle.
    private unowned let central: LinkCentral

    /// Whether `candidate` is the central that owns this peripheral.
    ///
    /// ``LinkCentral/connect(_:options:requiresANCS:)`` uses this ownership test in place of a
    /// table lookup, because the mirror cap can invalidate a lookup under a caller that still
    /// holds a valid peripheral.
    func isOwned(by candidate: LinkCentral) -> Bool { central === candidate }

    /// The queue to which the code confines every mirroring method, property accessor, and event
    /// delivery. It is the queue with which the owning `Central` was constructed.
    private let queue: DispatchQueue

    /// The last name that the provider reported. A `Mutex` protects it, and the queue does not
    /// confine it: ``name`` is read off-queue, and every writer already runs on ``queue``.
    private let nameBox: Mutex<String?>
    nonisolated(unsafe) private var _connectionState: PeripheralConnectionState = .disconnected
    nonisolated(unsafe) private var _ancsAuthorized = false
    nonisolated(unsafe) private var _eventHandler: ((PeripheralEvent) -> Void)?
    nonisolated(unsafe) private var _services: [ServiceIdentifier] = []
    nonisolated(unsafe) private var _characteristics: [ServiceIdentifier: [CharacteristicIdentifier: CharacteristicProperties]] = [:]
    nonisolated(unsafe) private var _descriptors: [CharacteristicIdentifier: [DescriptorIdentifier]] = [:]
    nonisolated(unsafe) private var _notifying: Set<CharacteristicIdentifier> = []
    nonisolated(unsafe) private var _maximumWriteWithResponse = 512
    nonisolated(unsafe) private var _maximumWriteWithoutResponse = 20
    /// The sequences of the `.withoutResponse` writes that this peripheral sent and that have no
    /// acknowledgement yet, oldest first. This is an array and not a `Set`, for three reasons:
    ///
    /// - In practice it never holds more than the size of one window.
    /// - The order makes a stale acknowledgement easy to see in a debugger.
    /// - A linear scan of that many elements is cheaper than hashing.
    nonisolated(unsafe) private var _outstandingWithoutResponse: [UInt64] = []
    nonisolated(unsafe) private var _nextWriteSequence: UInt64 = 0

    /// For each service discovery that this peripheral sent and that has no answer yet: whether
    /// the request named the services that it wanted. The list is oldest first. This is the flag
    /// that `recordDiscoveredServices(_:)` needs and that the wire event does not carry. The
    /// provider answers a peripheral's requests in arrival order, so the oldest entry belongs to
    /// the answer that lands now.
    nonisolated(unsafe) private var _pendingServiceDiscoveryFilters: [Bool] = []

    /// Creates a peripheral mirror. `LinkCentral` is the only caller.
    ///
    /// - Parameters:
    ///   - identifier: The peripheral's identifier on the provider's machine.
    ///   - name: The last name that the provider reported, if any.
    ///   - central: The owning central, referenced as `unowned`.
    ///   - queue: The central's serial queue.
    init(identifier: UUID, name: String?, central: LinkCentral, queue: DispatchQueue) {
        self.identifier = identifier
        self.nameBox = Mutex(name)
        self.central = central
        self.queue = queue
    }

    // MARK: - PeripheralRemote state

    /// The advertised or cached name of the peripheral, as the provider last reported it. A
    /// `Mutex` backs it, so any context can read it. The `connectedPeripherals` adoption of
    /// `Central` reads it off the central's queue.
    public var name: String? {
        nameBox.withLock { $0 }
    }

    /// The current connection state of the peripheral, mirrored from the provider.
    public var connectionState: PeripheralConnectionState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectionState
    }

    /// Whether the provider reported the ANCS data sharing of this connection as authorized.
    public var ancsAuthorized: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _ancsAuthorized
    }

    /// Whether the flow-control window of the link has room for one more `.withoutResponse`
    /// write (`LinkFlowControl.writeWithoutResponseWindow`).
    public var canSendWriteWithoutResponse: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _outstandingWithoutResponse.count < LinkFlowControl.writeWithoutResponseWindow
    }

    /// Receives every `PeripheralEvent` that the code translated from this peripheral's wire
    /// events.
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

    // MARK: - PeripheralRemote requests

    /// Asks the provider to discover `services`. If `services` is `nil`, it asks for every
    /// service. The peripheral remembers whether the request was filtered, so
    /// `recordDiscoveredServices(_:)` can apply the correct rule to the answer.
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        _pendingServiceDiscoveryFilters.append(services != nil)
        central.send(.discoverServices(peripheral: identifier, services: services?.map(\.uuidString)))
    }

    /// Asks the provider to discover `characteristics` of `service`. If `characteristics` is
    /// `nil`, it asks for every characteristic. The function does nothing for a service that the
    /// mirror cache has not seen discovered, for the reason that
    /// ``readValue(for:)-(CharacteristicIdentifier)`` gives.
    public func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isDiscovered(service) else { return }
        central.send(.discoverCharacteristics(
            peripheral: identifier,
            service: service.uuidString,
            characteristics: characteristics?.map(\.uuidString)
        ))
    }

    /// Asks the provider to read `characteristic`. The function does nothing for a characteristic
    /// that the mirror cache has not seen discovered. The seam specifies this, and the
    /// CoreBluetooth shim does the same: CoreBluetooth has no `CBCharacteristic` to read, so it
    /// sends nothing and no completion arrives. A request sent anyway would make the provider
    /// answer for a characteristic that this client cannot name.
    public func readValue(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isDiscovered(characteristic) else { return }
        central.send(.readValue(peripheral: identifier, characteristic: WireCharacteristicRef(characteristic)))
    }

    /// Asks the provider to write `data` to `characteristic`.
    ///
    /// The function always sends a `.withoutResponse` write, even when the flow-control window is
    /// full. `Central` consults ``canSendWriteWithoutResponse`` before it writes, and dropping a
    /// payload that the caller believes was sent is worse than exceeding the window. The function
    /// tags the write with a monotonic sequence. The provider echoes the sequence back as
    /// `writeWithoutResponseAccepted`, which reopens the window.
    ///
    /// The function does nothing for a characteristic that the mirror cache has not seen
    /// discovered, for the reason that ``readValue(for:)-(CharacteristicIdentifier)`` gives. It
    /// also does not spend the flow-control sequence, because nothing goes out to get an
    /// acknowledgement.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isDiscovered(characteristic) else { return }
        let sequence = _nextWriteSequence
        _nextWriteSequence &+= 1
        if type == .withoutResponse {
            _outstandingWithoutResponse.append(sequence)
        }
        central.send(.writeValue(
            peripheral: identifier,
            characteristic: WireCharacteristicRef(characteristic),
            value: data,
            type: WireWriteType(type),
            sequence: sequence
        ))
    }

    /// Asks the provider to enable or disable notifications for `characteristic`. The function
    /// does nothing for a characteristic that the mirror cache has not seen discovered, for the
    /// reason that ``readValue(for:)-(CharacteristicIdentifier)`` gives.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isDiscovered(characteristic) else { return }
        central.send(.setNotifyValue(peripheral: identifier, characteristic: WireCharacteristicRef(characteristic), enabled: enabled))
    }

    /// Asks the provider to discover the descriptors of `characteristic`. The function does
    /// nothing for a characteristic that the mirror cache has not seen discovered, for the
    /// reason that ``readValue(for:)-(CharacteristicIdentifier)`` gives.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isDiscovered(characteristic) else { return }
        central.send(.discoverDescriptors(peripheral: identifier, characteristic: WireCharacteristicRef(characteristic)))
    }

    /// Asks the provider to read `descriptor`. The function does nothing for a descriptor that
    /// the mirror cache has not seen discovered, for the reason that
    /// ``readValue(for:)-(CharacteristicIdentifier)`` gives.
    public func readValue(for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isDiscovered(descriptor) else { return }
        central.send(.readDescriptor(peripheral: identifier, descriptor: WireDescriptorRef(descriptor)))
    }

    /// Asks the provider to write `data` to `descriptor`. The function does nothing for a
    /// descriptor that the mirror cache has not seen discovered, for the reason that
    /// ``readValue(for:)-(CharacteristicIdentifier)`` gives.
    public func writeValue(_ data: Data, for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isDiscovered(descriptor) else { return }
        central.send(.writeDescriptor(peripheral: identifier, descriptor: WireDescriptorRef(descriptor), value: data))
    }

    /// Asks the provider to read the RSSI of this peripheral.
    public func readRSSI() {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.readRSSI(peripheral: identifier))
    }

    /// Asks the provider to open an L2CAP channel to `psm`.
    ///
    /// The code creates the client half of the channel and files it with the central *before* it
    /// sends the request. Thus the provider's `didOpenL2CAPChannel`, and any bytes that follow
    /// it, always find a channel to route to. A failed open drops the channel again.
    public func openL2CAPChannel(_ psm: L2CAPPSM) {
        dispatchPrecondition(condition: .onQueue(queue))
        let channel = central.allocateChannelIdentifier()
        central.registerChannel(channel, psm: psm, peripheral: identifier)
        central.send(.openL2CAPChannel(peripheral: identifier, psm: psm.rawValue, channel: channel))
    }

    /// The maximum payload length that the provider reported for a write of `type`.
    public func maximumWriteValueLength(for type: WriteType) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        switch type {
        case .withResponse: return _maximumWriteWithResponse
        case .withoutResponse: return _maximumWriteWithoutResponse
        }
    }

    // MARK: - PeripheralRemote discovery cache

    /// Whether `service` is in the mirror cache.
    public func isDiscovered(_ service: ServiceIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _services.contains(service)
    }

    /// Whether `characteristic` is in the mirror cache.
    public func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _characteristics[characteristic.service]?[characteristic] != nil
    }

    /// Whether `descriptor` is in the mirror cache.
    public func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _descriptors[descriptor.characteristic]?.contains(descriptor) ?? false
    }

    /// Whether the provider last reported `characteristic` as notifying.
    public func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _notifying.contains(characteristic)
    }

    /// The properties that the provider reported for `characteristic`. The value is `[]` if the
    /// characteristic has not been discovered.
    public func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties {
        dispatchPrecondition(condition: .onQueue(queue))
        return _characteristics[characteristic.service]?[characteristic] ?? []
    }

    /// Every service that is now in the mirror cache.
    public var discoveredServices: [ServiceIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _services
    }

    /// Every characteristic that is now in the mirror cache for `service`.
    public func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _characteristics[service].map { Array($0.keys) } ?? []
    }

    /// Every descriptor that is now in the mirror cache for `characteristic`.
    public func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _descriptors[characteristic] ?? []
    }

    // MARK: - Mirror updates (called by LinkCentral, on `queue`)

    /// The identity of this peripheral, for the `CentralEvent`s that carry one.
    var peripheralIdentifier: PeripheralIdentifier {
        dispatchPrecondition(condition: .onQueue(queue))
        return PeripheralIdentifier(uuid: identifier, name: name)
    }

    /// Records a name that the provider reported outside a connection (a scan sighting).
    func record(name: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let name else { return }
        nameBox.withLock { $0 = name }
    }

    /// Marks a connection attempt as under way. This mirrors `CBPeripheral.state`.
    func markConnecting() {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionState = .connecting
    }

    /// Marks a cancellation that is in flight. This mirrors `CBPeripheral.state` after
    /// `cancelPeripheralConnection(_:)`.
    func markDisconnecting() {
        dispatchPrecondition(condition: .onQueue(queue))
        if _connectionState != .disconnected {
            _connectionState = .disconnecting
        }
    }

    /// Records a completed connection and the maxima that the provider negotiated.
    ///
    /// Both maxima already passed the wire boundary's ``BLESwiftLink/WireLengthValidation`` when
    /// they arrive here. Thus neither can be a value on which the chunked writer of `Peripheral`
    /// would loop or trap.
    func markConnected(name: String?, maximumWriteWithResponse: Int, maximumWriteWithoutResponse: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionState = .connected
        if let name { nameBox.withLock { $0 = name } }
        _maximumWriteWithResponse = maximumWriteWithResponse
        _maximumWriteWithoutResponse = maximumWriteWithoutResponse
    }

    /// Records a disconnect or a failed connection attempt. It discards all per-connection
    /// state:
    ///
    /// - the discovery caches
    /// - the notifying set
    /// - the flow-control count
    /// - the negotiated maxima
    func markDisconnected() {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionState = .disconnected
        _services = []
        _characteristics = [:]
        _descriptors = [:]
        _notifying = []
        _outstandingWithoutResponse = []
        _pendingServiceDiscoveryFilters = []
        _maximumWriteWithResponse = 512
        _maximumWriteWithoutResponse = 20
        _ancsAuthorized = false
    }

    /// Records the answer to a service discovery in the mirror.
    ///
    /// **The answer to a filtered request joins the mirror. The answer to an unfiltered request
    /// replaces it.** `VirtualPeripheralRemote.recordServices(_:filtered:)` applies the same rule
    /// on the provider side of the seam. The answer to `discoverServices([x])` describes `x` and
    /// nothing else, so dropping the services that are missing from it would discard services
    /// that the device still has. Also, `GATTCompatibility.discovery` defaults to `.filtered`,
    /// so `Central` asks for exactly one service at a time.
    ///
    /// The code treats an answer with no request behind it as unfiltered. A provider that
    /// volunteers a service list describes the whole database.
    ///
    /// `didModifyServices` prunes through ``invalidate(services:)``, and a disconnect empties
    /// the mirror.
    ///
    /// - Parameter services: The services that the provider reported.
    func recordDiscoveredServices(_ services: [ServiceIdentifier]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let filtered = _pendingServiceDiscoveryFilters.isEmpty ? false : _pendingServiceDiscoveryFilters.removeFirst()
        guard filtered else {
            _services = services
            return
        }
        for service in services where !_services.contains(service) {
            _services.append(service)
        }
    }

    /// Replaces the mirrored characteristics of `service` and their properties.
    func replaceCharacteristics(_ characteristics: [CharacteristicIdentifier: CharacteristicProperties], for service: ServiceIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _characteristics[service] = characteristics
    }

    /// Replaces the mirrored descriptors of `characteristic`.
    func replaceDescriptors(_ descriptors: [DescriptorIdentifier], for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _descriptors[characteristic] = descriptors
    }

    /// Drops `services` and everything below them from the mirror, as a `didModifyServices`
    /// invalidation requires.
    func invalidate(services: [ServiceIdentifier]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let invalidated = Set(services)
        _services.removeAll { invalidated.contains($0) }
        for service in invalidated {
            guard let characteristics = _characteristics.removeValue(forKey: service) else { continue }
            for characteristic in characteristics.keys {
                _descriptors.removeValue(forKey: characteristic)
                _notifying.remove(characteristic)
            }
        }
    }

    /// Records the new notification state of `characteristic`. The code records an enabled state
    /// only while the characteristic is still in the mirror. The answer to a notify request can
    /// arrive after a `didModifyServices` that ``invalidate(services:)`` already applied, and
    /// arming the notification again then would report notifying on a characteristic that is
    /// gone.
    func setNotifying(_ isNotifying: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        if isNotifying, _characteristics[characteristic.service]?[characteristic] != nil {
            _notifying.insert(characteristic)
        } else {
            _notifying.remove(characteristic)
        }
    }

    /// Records the provider's acknowledgement for the `.withoutResponse` write that has the tag
    /// `sequence`.
    ///
    /// The function honors an acknowledgement only for a write that this peripheral still has
    /// outstanding. It ignores these sequences:
    ///
    /// - A sequence that was never sent.
    /// - A sequence that was already acknowledged.
    /// - A sequence from before a disconnect. ``markDisconnected()`` empties the set, and the
    ///   provider's acknowledgement can still be in flight when it does.
    ///
    /// Thus the function does not credit the window that a later connection is filling.
    ///
    /// - Parameter sequence: The sequence that the provider echoed back.
    /// - Returns: `true` if this acknowledgement reopened a window that was full. In that case the
    ///   consumer is owed `PeripheralEvent.isReadyToSendWriteWithoutResponse`.
    func acknowledgeWriteWithoutResponse(sequence: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let index = _outstandingWithoutResponse.firstIndex(of: sequence) else { return false }
        let window = LinkFlowControl.writeWithoutResponseWindow
        let wasFull = _outstandingWithoutResponse.count >= window
        _outstandingWithoutResponse.remove(at: index)
        return wasFull && _outstandingWithoutResponse.count < window
    }

    /// Records an ANCS authorization change that the provider reported.
    func setANCSAuthorized(_ authorized: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        _ancsAuthorized = authorized
    }

    /// Delivers `event` to ``eventHandler`` asynchronously on ``queue``, as the seam's
    /// never-inline delivery contract requires.
    func deliver(_ event: PeripheralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            _eventHandler?(event)
        }
    }

    /// Detaches event delivery. ``LinkCentral/shutdown()`` calls this. It is already on
    /// ``queue``.
    func detachEventHandler() {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventHandler = nil
    }
}
