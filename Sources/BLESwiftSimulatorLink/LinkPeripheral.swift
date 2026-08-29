//
//  LinkPeripheral.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// A `PeripheralRemote` whose GATT operations travel over the link to a provider's real
/// `CBPeripheral`, backed by a local mirror of that peripheral's discovery state.
///
/// A `LinkPeripheral` is never created directly: ``LinkCentral`` owns the table of them and
/// vends the same instance for a given identifier every time, exactly as CoreBluetooth
/// vends one `CBPeripheral` per peripheral. It refers back to its central `unowned` — the
/// central owns it, so it can never outlive it — and sends every request through the
/// central's one session.
///
/// **The mirror cache.** CoreBluetooth answers `isDiscovered`/`properties(of:)`/
/// `discoveredServices` synchronously from its own object graph; across a link there is no
/// such graph to consult, so every discovery result the provider reports is mirrored here.
/// The mirror is updated *inline* as each wire event arrives (both happen on ``queue``), and
/// the matching `PeripheralEvent` is delivered afterwards via `queue.async` — so by the time
/// `Central` handles a discovery completion, the cache it is about to interrogate is already
/// current.
///
/// **Concurrency — queue-confined, not lock-protected.** Every stored property is
/// `nonisolated(unsafe)`, safe only because every `PeripheralRemote` method and property
/// accessor asserts `dispatchPrecondition(condition: .onQueue(queue))` and touches state
/// inline: the serial queue itself is the synchronization, exactly as for `FakePeripheral`
/// and a real `CBPeripheral`. Event delivery is always `queue.async`, never inline.
public final class LinkPeripheral: PeripheralRemote, Sendable {

    /// The identifier the provider's CoreBluetooth stack uses for this peripheral.
    public let identifier: UUID

    /// The central that owns this peripheral and carries its requests. `unowned` because the
    /// central owns the table this peripheral lives in — it cannot outlive its central.
    /// `Central` retains the backend (its `manager`) for at least as long as any
    /// `PeripheralRemote` that backend hands out, so this reference can never dangle.
    private unowned let central: LinkCentral

    /// The queue every mirroring method, property accessor, and event delivery is confined
    /// to — the same queue the owning `Central` was constructed with.
    private let queue: DispatchSerialQueue

    nonisolated(unsafe) private var _name: String?
    nonisolated(unsafe) private var _connectionState: PeripheralConnectionState = .disconnected
    nonisolated(unsafe) private var _ancsAuthorized = false
    nonisolated(unsafe) private var _eventHandler: ((PeripheralEvent) -> Void)?
    nonisolated(unsafe) private var _services: [ServiceIdentifier] = []
    nonisolated(unsafe) private var _characteristics: [ServiceIdentifier: [CharacteristicIdentifier: CharacteristicProperties]] = [:]
    nonisolated(unsafe) private var _descriptors: [CharacteristicIdentifier: [DescriptorIdentifier]] = [:]
    nonisolated(unsafe) private var _notifying: Set<CharacteristicIdentifier> = []
    nonisolated(unsafe) private var _maximumWriteWithResponse = 512
    nonisolated(unsafe) private var _maximumWriteWithoutResponse = 20
    nonisolated(unsafe) private var _outstandingWithoutResponse = 0
    nonisolated(unsafe) private var _nextWriteSequence: UInt64 = 0

    /// Creates a peripheral mirror. `LinkCentral` is the only caller.
    ///
    /// - Parameters:
    ///   - identifier: The peripheral's identifier on the provider's machine.
    ///   - name: The last name the provider reported, if any.
    ///   - central: The owning central, referenced `unowned`.
    ///   - queue: The central's serial queue.
    init(identifier: UUID, name: String?, central: LinkCentral, queue: DispatchSerialQueue) {
        self.identifier = identifier
        self._name = name
        self.central = central
        self.queue = queue
    }

    // MARK: - PeripheralRemote state

    /// The peripheral's advertised or cached name, as last reported by the provider.
    public var name: String? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _name
    }

    /// The peripheral's current connection state, mirrored from the provider.
    public var connectionState: PeripheralConnectionState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectionState
    }

    /// Whether the provider reported this connection's ANCS data sharing as authorized.
    public var ancsAuthorized: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _ancsAuthorized
    }

    /// Whether another `.withoutResponse` write fits in the link's flow-control window
    /// (``LinkFlowControl/writeWithoutResponseWindow``).
    public var canSendWriteWithoutResponse: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _outstandingWithoutResponse < LinkFlowControl.writeWithoutResponseWindow
    }

    /// Receives every `PeripheralEvent` translated from this peripheral's wire events.
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

    /// Asks the provider to discover `services` (or every service, if `nil`).
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.discoverServices(peripheral: identifier, services: services?.map(\.uuidString)))
    }

    /// Asks the provider to discover `characteristics` (or every characteristic, if `nil`)
    /// of `service`.
    public func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.discoverCharacteristics(
            peripheral: identifier,
            service: service.uuidString,
            characteristics: characteristics?.map(\.uuidString)
        ))
    }

    /// Asks the provider to read `characteristic`.
    public func readValue(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.readValue(peripheral: identifier, characteristic: WireCharacteristicRef(characteristic)))
    }

    /// Asks the provider to write `data` to `characteristic`.
    ///
    /// A `.withoutResponse` write is always sent, even when the flow-control window is
    /// already full: `Central` consults ``canSendWriteWithoutResponse`` before writing, and
    /// dropping a payload the caller believes was sent would be worse than exceeding the
    /// window. The write is tagged with a monotonic sequence the provider echoes back as
    /// `writeWithoutResponseAccepted`, which reopens the window.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        dispatchPrecondition(condition: .onQueue(queue))
        let sequence = _nextWriteSequence
        _nextWriteSequence &+= 1
        if type == .withoutResponse {
            _outstandingWithoutResponse += 1
        }
        central.send(.writeValue(
            peripheral: identifier,
            characteristic: WireCharacteristicRef(characteristic),
            value: data,
            type: WireWriteType(type),
            sequence: sequence
        ))
    }

    /// Asks the provider to enable or disable notifications for `characteristic`.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.setNotifyValue(peripheral: identifier, characteristic: WireCharacteristicRef(characteristic), enabled: enabled))
    }

    /// Asks the provider to discover `characteristic`'s descriptors.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.discoverDescriptors(peripheral: identifier, characteristic: WireCharacteristicRef(characteristic)))
    }

    /// Asks the provider to read `descriptor`.
    public func readValue(for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.readDescriptor(peripheral: identifier, descriptor: WireDescriptorRef(descriptor)))
    }

    /// Asks the provider to write `data` to `descriptor`.
    public func writeValue(_ data: Data, for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.writeDescriptor(peripheral: identifier, descriptor: WireDescriptorRef(descriptor), value: data))
    }

    /// Asks the provider to read this peripheral's RSSI.
    public func readRSSI() {
        dispatchPrecondition(condition: .onQueue(queue))
        central.send(.readRSSI(peripheral: identifier))
    }

    /// Asks the provider to open an L2CAP channel to `psm`.
    ///
    /// The client half of the channel is created and filed with the central *before* the
    /// request goes out, so the provider's `didOpenL2CAPChannel` — and any bytes that follow
    /// it — always find a channel to route to. A failed open drops it again.
    public func openL2CAPChannel(_ psm: L2CAPPSM) {
        dispatchPrecondition(condition: .onQueue(queue))
        let channel = central.allocateChannelIdentifier()
        central.registerChannel(channel, psm: psm, peripheral: identifier)
        central.send(.openL2CAPChannel(peripheral: identifier, psm: psm.rawValue, channel: channel))
    }

    /// The provider-reported maximum payload length for a write of `type`.
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

    /// The properties the provider reported for `characteristic`, or `[]` if it has not been
    /// discovered.
    public func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties {
        dispatchPrecondition(condition: .onQueue(queue))
        return _characteristics[characteristic.service]?[characteristic] ?? []
    }

    /// Every service currently in the mirror cache.
    public var discoveredServices: [ServiceIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _services
    }

    /// Every characteristic currently in the mirror cache for `service`.
    public func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _characteristics[service].map { Array($0.keys) } ?? []
    }

    /// Every descriptor currently in the mirror cache for `characteristic`.
    public func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _descriptors[characteristic] ?? []
    }

    // MARK: - Mirror updates (called by LinkCentral, on `queue`)

    /// This peripheral's identity, for the `CentralEvent`s that carry one.
    var peripheralIdentifier: PeripheralIdentifier {
        dispatchPrecondition(condition: .onQueue(queue))
        return PeripheralIdentifier(uuid: identifier, name: _name)
    }

    /// Records a name the provider reported outside a connection (a scan sighting).
    func record(name: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let name { _name = name }
    }

    /// Marks a connection attempt as under way, mirroring `CBPeripheral.state`.
    func markConnecting() {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionState = .connecting
    }

    /// Marks an in-flight cancellation, mirroring `CBPeripheral.state` after
    /// `cancelPeripheralConnection(_:)`.
    func markDisconnecting() {
        dispatchPrecondition(condition: .onQueue(queue))
        if _connectionState != .disconnected {
            _connectionState = .disconnecting
        }
    }

    /// Records a completed connection and the maxima the provider negotiated.
    func markConnected(name: String?, maximumWriteWithResponse: Int, maximumWriteWithoutResponse: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionState = .connected
        if let name { _name = name }
        _maximumWriteWithResponse = maximumWriteWithResponse
        _maximumWriteWithoutResponse = maximumWriteWithoutResponse
    }

    /// Records a disconnect (or a failed connection attempt), discarding every piece of
    /// per-connection state: the discovery caches, the notifying set, the flow-control
    /// count, and the negotiated maxima.
    func markDisconnected() {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionState = .disconnected
        _services = []
        _characteristics = [:]
        _descriptors = [:]
        _notifying = []
        _outstandingWithoutResponse = 0
        _maximumWriteWithResponse = 512
        _maximumWriteWithoutResponse = 20
        _ancsAuthorized = false
    }

    /// Replaces the mirrored service list.
    func replaceServices(_ services: [ServiceIdentifier]) {
        dispatchPrecondition(condition: .onQueue(queue))
        _services = services
    }

    /// Replaces `service`'s mirrored characteristics and their properties.
    func replaceCharacteristics(_ characteristics: [CharacteristicIdentifier: CharacteristicProperties], for service: ServiceIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _characteristics[service] = characteristics
    }

    /// Replaces `characteristic`'s mirrored descriptors.
    func replaceDescriptors(_ descriptors: [DescriptorIdentifier], for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        _descriptors[characteristic] = descriptors
    }

    /// Drops `services` and everything beneath them from the mirror, as a `didModifyServices`
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

    /// Records `characteristic`'s new notification state.
    func setNotifying(_ isNotifying: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        if isNotifying {
            _notifying.insert(characteristic)
        } else {
            _notifying.remove(characteristic)
        }
    }

    /// Records the provider's acknowledgement of one `.withoutResponse` write.
    ///
    /// - Returns: `true` when this acknowledgement reopened a window that was full, meaning
    ///   `PeripheralEvent.isReadyToSendWriteWithoutResponse` is now owed to the consumer.
    func acknowledgeWriteWithoutResponse() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let window = LinkFlowControl.writeWithoutResponseWindow
        let wasFull = _outstandingWithoutResponse >= window
        _outstandingWithoutResponse = max(0, _outstandingWithoutResponse - 1)
        return wasFull && _outstandingWithoutResponse < window
    }

    /// Records an ANCS authorization change reported by the provider.
    func setANCSAuthorized(_ authorized: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        _ancsAuthorized = authorized
    }

    /// Delivers `event` to ``eventHandler`` asynchronously on ``queue``, honoring the
    /// seam's never-inline delivery contract.
    func deliver(_ event: PeripheralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            _eventHandler?(event)
        }
    }

    /// Detaches event delivery. Called during ``LinkCentral/shutdown()``, already on
    /// ``queue``.
    func detachEventHandler() {
        dispatchPrecondition(condition: .onQueue(queue))
        _eventHandler = nil
    }
}
