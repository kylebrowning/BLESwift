//
//  VirtualPeripheralRemote.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Dispatch
import Foundation
import Synchronization

/// A ``BLESwiftCore/PeripheralRemote`` backed by a ``VirtualRadio`` device, vended by
/// ``VirtualCentralBackend/retrievePeripherals(withIdentifiers:)``.
///
/// **Concurrency — queue-confined, not lock-protected.** Every stored property is
/// `nonisolated(unsafe)` and touched only on ``queue``, which every `PeripheralRemote`
/// method asserts at entry — the serial queue is the synchronization, exactly as it is for
/// a real `CBPeripheral`. GATT work reaches the radio actor through one serial chain of
/// `Task`s (see ``enqueue(_:)``), and every resulting event is delivered back with
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

    /// This remote's identity as a ``BLESwiftCore/PeripheralIdentifier``.
    var peripheralIdentifier: PeripheralIdentifier {
        PeripheralIdentifier(uuid: identifier, name: name)
    }

    /// Delivers `event` to ``eventHandler``. Must be called on ``queue``.
    func deliver(_ event: PeripheralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
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
    func setConnectionState(_ state: PeripheralConnectionState) {
        dispatchPrecondition(condition: .onQueue(queue))
        _connectionState = state
        if state == .disconnected {
            _notifying.removeAll()
        }
    }

    /// Translates a GATT-layer failure into the `NSError` CoreBluetooth would report.
    static func error(for attError: ATTError) -> NSError {
        NSError(domain: "CBATTErrorDomain", code: attError.rawValue)
    }

    // MARK: - PeripheralRemote

    /// Receives every ``BLESwiftCore/PeripheralEvent`` this remote produces, on ``queue``.
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
    public var ancsAuthorized: Bool { false }

    /// Always `true` — the virtual radio applies no write-without-response back-pressure.
    public var canSendWriteWithoutResponse: Bool { true }

    /// Asks the radio for `services` (or every service, when `nil`) and delivers
    /// `didDiscoverServices` once the answer lands.
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [radio, identifier, queue] in
            let found = await radio.services(of: identifier, matching: services)
            queue.async { [self] in
                _discoveredServices.formUnion(found)
                deliver(.didDiscoverServices(error: nil))
            }
        }
    }

    /// Asks the radio for `service`'s characteristics and delivers
    /// `didDiscoverCharacteristics` once the answer lands, caching each characteristic's
    /// advertised properties.
    public func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [radio, identifier, queue] in
            let found = await radio.characteristics(of: identifier, service: service, matching: characteristics)
            queue.async { [self] in
                for characteristic in found {
                    _discoveredCharacteristics.insert(characteristic.identifier)
                    _properties[characteristic.identifier] = characteristic.properties
                }
                deliver(.didDiscoverCharacteristics(service: service, error: nil))
            }
        }
    }

    /// Reads `characteristic` through the radio and delivers the result as
    /// `didUpdateValue`.
    public func readValue(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [radio, identifier, session, queue] in
            let result = await radio.read(device: identifier, characteristic: characteristic, session: session)
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
    /// exactly as CoreBluetooth does.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [radio, identifier, session, queue] in
            let result = await radio.write(
                device: identifier,
                characteristic: characteristic,
                value: data,
                session: session
            )
            guard type == .withResponse else { return }
            queue.async { [self] in
                switch result {
                case .success:
                    deliver(.didWriteValue(characteristic: characteristic, error: nil))
                case .failure(let attError):
                    deliver(.didWriteValue(characteristic: characteristic, error: Self.error(for: attError)))
                }
            }
        }
    }

    /// Records the new notification state immediately (so a racing read sees it, as
    /// CoreBluetooth's own `isNotifying` would), forwards the change to the radio, and
    /// delivers `didUpdateNotificationState` once it lands.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        if enabled {
            _notifying.insert(characteristic)
        } else {
            _notifying.remove(characteristic)
        }
        enqueue { [radio, identifier, session, queue] in
            await radio.setNotify(enabled, device: identifier, characteristic: characteristic, session: session)
            queue.async { [self] in
                deliver(.didUpdateNotificationState(characteristic: characteristic, isNotifying: enabled, error: nil))
            }
        }
    }

    /// Delivers `didDiscoverDescriptors` with nothing discovered — virtual devices expose
    /// no descriptors.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            deliver(.didDiscoverDescriptors(characteristic: characteristic, error: nil))
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

    /// Delivers `didReadRSSI` with ``VirtualRadio/rssi``.
    public func readRSSI() {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            deliver(.didReadRSSI(VirtualRadio.rssi, error: nil))
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

    /// Fails the attempt — the virtual radio serves GATT only, not L2CAP channels.
    public func openL2CAPChannel(_ psm: L2CAPPSM) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            deliver(.didOpenL2CAPChannel(channel: nil, error: Self.l2capUnsupportedError))
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
