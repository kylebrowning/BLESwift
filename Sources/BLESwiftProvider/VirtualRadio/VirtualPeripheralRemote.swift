//
//  VirtualPeripheralRemote.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import Synchronization

/// A `PeripheralRemote` backed by a ``VirtualRadio`` device, vended by
/// ``VirtualCentralBackend/retrievePeripherals(withIdentifiers:)``.
///
/// **Concurrency — queue-confined, not lock-protected.** Every stored property is
/// `nonisolated(unsafe)` and touched only on ``queue``, which every `PeripheralRemote`
/// method asserts at entry — the serial queue is the synchronization, exactly as it is for
/// a real `CBPeripheral`. GATT work reaches the radio actor through one serial chain of
/// `Task`s (see `enqueue(_:)`), and every resulting event is delivered back with
/// `queue.async`, never inline. The one exception is ``name``, which the radio fills in
/// asynchronously and CoreBluetooth callers read off-queue, so it is `Mutex`-protected
/// instead.
public final class VirtualPeripheralRemote: PeripheralRemote, Sendable {

    /// The device identifier this remote stands for.
    public let identifier: UUID

    /// The queue every method and event delivery is confined to.
    public let queue: DispatchSerialQueue

    private let radio: VirtualRadio
    private let session: UUID
    private let nameBox: Mutex<String?>

    nonisolated(unsafe) private var _eventHandler: ((PeripheralEvent) -> Void)?
    nonisolated(unsafe) private var _connectionState: PeripheralConnectionState = .disconnected
    nonisolated(unsafe) private var _discoveredServices: Set<ServiceIdentifier> = []
    nonisolated(unsafe) private var _discoveredCharacteristics: Set<CharacteristicIdentifier> = []
    nonisolated(unsafe) private var _properties: [CharacteristicIdentifier: CharacteristicProperties] = [:]
    nonisolated(unsafe) private var _notifying: Set<CharacteristicIdentifier> = []

    /// How many `.withoutResponse` writes this remote has handed the radio and not yet seen
    /// answered — the transmit queue a real `CBPeripheral` reports back-pressure from.
    nonisolated(unsafe) private var _inFlightWrites = 0

    /// The serial chain of radio work this remote has queued. Swift guarantees no ordering
    /// between independent `Task`s, so two back-to-back writes — or a `setNotifyValue(true)`
    /// and the write that triggers the notification it arms — could otherwise reach the actor
    /// in either order. Every radio call is appended to this chain instead.
    nonisolated(unsafe) private var _work: Task<Void, Never>?

    /// Creates a remote for `identifier`, served by `radio` under `session`.
    init(identifier: UUID, radio: VirtualRadio, session: UUID, queue: DispatchSerialQueue, name: String?) {
        self.identifier = identifier
        self.radio = radio
        self.session = session
        self.queue = queue
        self.nameBox = Mutex(name)
    }

    /// The device's name, filled in from the radio once it is known.
    public var name: String? {
        nameBox.withLock { $0 }
    }

    /// Updates the cached ``name``. Called by ``VirtualCentralBackend`` once the radio has
    /// answered with the device's real name.
    func updateName(_ name: String?) {
        guard let name else { return }
        nameBox.withLock { $0 = name }
    }

    /// Whether `candidate` is the session identifier of the backend that vended this remote.
    ///
    /// The ownership test ``VirtualCentralBackend/connect(_:options:requiresANCS:)`` uses in
    /// place of a table lookup, which the remote cap can invalidate under a caller still
    /// holding a perfectly valid remote.
    func isOwned(by candidate: UUID) -> Bool { session == candidate }

    /// This remote's identity as a ``BLESwiftCore/PeripheralIdentifier``.
    var peripheralIdentifier: PeripheralIdentifier {
        PeripheralIdentifier(uuid: identifier, name: name)
    }

    /// Delivers `event` to ``eventHandler``. Must be called on ``queue``.
    ///
    /// A `didModifyServices` prunes the caches on its way past, so a remote whose device
    /// dropped a service stops reporting that service — and everything under it — as
    /// discovered, exactly as `LinkPeripheral` does with the same event off the link and as
    /// CoreBluetooth does to a `CBPeripheral`'s `services`.
    func deliver(_ event: PeripheralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        if case .didModifyServices(let invalidated) = event { prune(Set(invalidated)) }
        _eventHandler?(event)
    }

    /// Appends `body` to the serial chain of radio work, so it runs after every operation
    /// queued before it. Must be called on ``queue``.
    private func enqueue(_ body: @escaping @Sendable () async -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = _work
        _work = Task {
            await previous?.value
            await body()
        }
    }

    /// Records a connection-state transition. Must be called on ``queue``.
    ///
    /// A transition to `.disconnected` empties every discovery cache along with the
    /// notification set, exactly as `LinkPeripheral.markDisconnected()` does and as
    /// CoreBluetooth does to a `CBPeripheral`'s `services`: the handles a disconnected
    /// peripheral's database was described by are gone, so continuing to report them
    /// discovered would let a read, a write, or a `setNotifyValue(_:for:)` past the
    /// discovery guard and on to a radio that has no connection left to serve it over.
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

    /// Replaces the discovered-service cache with `services`, dropping everything beneath a
    /// service that is no longer there. Must be called on ``queue``.
    private func replaceServices(_ services: [ServiceIdentifier]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let discovered = Set(services)
        let departed = _discoveredServices.subtracting(discovered)
        _discoveredServices = discovered
        prune(departed)
    }

    /// Drops `services` and everything beneath them from the caches — the same pruning
    /// `LinkPeripheral.invalidate(services:)` does off a `didModifyServices`. Must be called
    /// on ``queue``.
    private func prune(_ services: Set<ServiceIdentifier>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !services.isEmpty else { return }
        _discoveredServices.subtract(services)
        _discoveredCharacteristics = _discoveredCharacteristics.filter { !services.contains($0.service) }
        _properties = _properties.filter { !services.contains($0.key.service) }
        _notifying = _notifying.filter { !services.contains($0.service) }
    }

    /// Translates a GATT-layer failure into the `NSError` CoreBluetooth would report.
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

    /// The remote's current connection state, as tracked by the owning backend.
    public var connectionState: PeripheralConnectionState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _connectionState
    }

    /// Always `false` — the virtual radio has no ANCS.
    public var ancsAuthorized: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return false
    }

    /// Whether fewer than `LinkFlowControl.writeWithoutResponseWindow` `.withoutResponse`
    /// writes are still waiting on the radio.
    ///
    /// **A virtual radio does apply back-pressure.** Reporting `true` unconditionally was the
    /// obvious reading of "no transmit queue to fill" and the wrong one: a hosted
    /// `PeripheralHost` answers each write over its own link, and each one parks for up to
    /// ``VirtualRadio/attTimeout`` waiting for that answer. With nothing ever refused, a
    /// central session's `drainWrites` hands every queued write straight through and the
    /// serial chain behind this remote grows without bound against a host that is merely slow
    /// — the one thing `maximumPendingWrites` exists to bound, and which it could never reach.
    /// The same window the link's own clients honor bounds it here.
    public var canSendWriteWithoutResponse: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _inFlightWrites < LinkFlowControl.writeWithoutResponseWindow
    }

    /// Asks the radio for `services` (or every service, when `nil`) and delivers
    /// `didDiscoverServices` once the answer lands.
    ///
    /// **The answer replaces the cache rather than joining it**, exactly as
    /// `LinkPeripheral.replaceServices(_:)` does with the same answer arriving over the link.
    /// A union kept reporting a service the device has since dropped as discovered, so a read
    /// or a `setNotifyValue(_:for:)` under it passed the discovery guard and reached a radio
    /// with no such attribute — and the two backends behind one seam disagreed about what the
    /// same device had.
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [radio, identifier, queue] in
            let found = await radio.services(of: identifier, matching: services)
            queue.async { [self] in
                replaceServices(found)
                deliver(.didDiscoverServices(error: nil))
            }
        }
    }

    /// Asks the radio for `service`'s characteristics and delivers
    /// `didDiscoverCharacteristics` once the answer lands, caching each characteristic's
    /// advertised properties.
    ///
    /// A no-op for a service this remote has not discovered, exactly as
    /// `LinkPeripheral.discoverCharacteristics(_:for:)` and CoreBluetooth are: `CBPeripheral`
    /// takes a `CBService` it vended, so there is nothing to ask about a service the caller
    /// cannot name, nothing is sent and no completion arrives. Answered anyway, this backend
    /// enumerated a service its link-side counterpart would have refused — and the two
    /// backends behind one seam disagreed about what a caller may ask for.
    public func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discoveredServices.contains(service) else { return }
        enqueue { [radio, identifier, queue] in
            let found = await radio.characteristics(of: identifier, service: service, matching: characteristics)
            queue.async { [self] in
                // This service's entries only, replaced — `LinkPeripheral`'s
                // `replaceCharacteristics(_:for:)` keys its mirror by service the same way.
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

    /// Reads `characteristic` through the radio and delivers the result as
    /// `didUpdateValue`. A no-op for a characteristic this remote has not discovered, as the
    /// seam specifies and the CoreBluetooth shim does — CoreBluetooth has no object to hand
    /// its own `readValue(for:)`, so nothing is sent and no completion arrives.
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

    /// Writes `data` through the radio. A `.withResponse` write delivers `didWriteValue`
    /// when the device's handler has answered; a `.withoutResponse` write delivers nothing,
    /// exactly as CoreBluetooth does. A no-op for a characteristic this remote has not
    /// discovered, for the same reason as ``readValue(for:)-(CharacteristicIdentifier)``.
    ///
    /// A `.withoutResponse` write occupies a slot in this remote's window until the radio has
    /// answered it; the slot's release raises
    /// `PeripheralEvent.isReadyToSendWriteWithoutResponse`, which is the
    /// signal the seam's contract says a caller waits on when
    /// ``canSendWriteWithoutResponse`` is `false`.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discoveredCharacteristics.contains(characteristic) else { return }
        if type == .withoutResponse { _inFlightWrites += 1 }
        enqueue { [radio, identifier, session, queue] in
            let result = await radio.write(
                device: identifier,
                characteristic: characteristic,
                value: data,
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

    /// Releases the window slot one answered `.withoutResponse` write held, raising
    /// `isReadyToSendWriteWithoutResponse` on the transition that reopens the
    /// window. Must be called on ``queue``.
    ///
    /// Only the transition raises it — a slot released while the window was already open is
    /// not news, and CoreBluetooth raises the event when a full queue drains, not per write.
    private func releaseWriteSlot() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _inFlightWrites > 0 else { return }
        _inFlightWrites -= 1
        if _inFlightWrites == LinkFlowControl.writeWithoutResponseWindow - 1 {
            deliver(.isReadyToSendWriteWithoutResponse)
        }
    }

    /// Records the new notification state immediately (so a racing read sees it, as
    /// CoreBluetooth's own `isNotifying` would), forwards the change to the radio, and
    /// delivers `didUpdateNotificationState` once it lands. A no-op for a characteristic this
    /// remote has not discovered, for the same reason as
    /// ``readValue(for:)-(CharacteristicIdentifier)`` — the notification state is not recorded
    /// either, since nothing was armed.
    ///
    /// A request the radio refuses — a characteristic declaring neither `notify` nor
    /// `indicate` — delivers the unchanged notification state along with the `ATTError` it was
    /// refused with, which is what CoreBluetooth reports for a CCCD write hardware rejected.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discoveredCharacteristics.contains(characteristic) else { return }
        if enabled {
            _notifying.insert(characteristic)
        } else {
            _notifying.remove(characteristic)
        }
        enqueue { [radio, identifier, session, queue] in
            // The radio's answer, not the request: a session the radio no longer holds a
            // connection for arms nothing, and reporting `enabled` anyway would leave the
            // remote claiming to notify on a subscription that does not exist.
            let outcome = await radio.setNotify(
                enabled, device: identifier, characteristic: characteristic, session: session
            )
            queue.async { [self] in
                if outcome.isNotifying {
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

    /// Delivers `didDiscoverDescriptors` with nothing discovered — virtual devices expose
    /// no descriptors.
    ///
    /// Answered from the serial chain rather than the next queue turn, though this backend
    /// asks the radio nothing: a bare `queue.async` runs *before* any radio round-trip already
    /// in flight, so a `discoverCharacteristics` and the `discoverDescriptors` behind it
    /// completed in the opposite order to the one they were called in — an ordering
    /// CoreBluetooth cannot produce. See ``_work``.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [queue] in
            queue.async { [self] in
                deliver(.didDiscoverDescriptors(characteristic: characteristic, error: nil))
            }
        }
    }

    /// A no-op — no descriptor is ever discovered on a virtual device, and the protocol
    /// specifies a no-op for an undiscovered target.
    public func readValue(for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// A no-op, for the same reason as ``readValue(for:)-(DescriptorIdentifier)``.
    public func writeValue(_ data: Data, for descriptor: DescriptorIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// Delivers `didReadRSSI` with ``VirtualRadio/rssi``, from the serial chain — for
    /// ``discoverDescriptors(for:)``'s reason.
    public func readRSSI() {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [queue] in
            queue.async { [self] in
                deliver(.didReadRSSI(VirtualRadio.rssi, error: nil))
            }
        }
    }

    /// Returns ``VirtualRadio/maximumValueLength`` for both write types.
    public func maximumWriteValueLength(for type: WriteType) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return VirtualRadio.maximumValueLength
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

    /// Always `false` — virtual devices expose no descriptors.
    public func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return false
    }

    /// Whether `characteristic` currently has notifications enabled.
    public func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _notifying.contains(characteristic)
    }

    /// The properties `characteristic` advertises, as revealed by discovery. `[]` before
    /// it has been discovered.
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

    /// Always empty — virtual devices expose no descriptors.
    public func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return []
    }

    /// Fails the attempt — the virtual radio serves GATT only, not L2CAP channels. Reported
    /// from the serial chain, for ``discoverDescriptors(for:)``'s reason.
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
#endif
