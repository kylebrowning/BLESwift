//
//  PeripheralManagerDelegateProxy.swift
//  BLESwift
//

// iOS and macOS only, like `PeripheralHost` and the `CBPeripheralManager` conformance.
#if os(iOS) || os(macOS)

import BLESwiftCore
import CoreBluetooth
import Foundation
import BLESwiftCompat17

/// Bridges `CBPeripheralManagerDelegate` callbacks into a ``PeripheralHostEvent`` handler
/// closure. It implements `eventHandler` for `CBPeripheralManager` in the `PeripheralManaging`
/// conformance. It is the peripheral-role counterpart to ``CentralDelegateProxy``.
///
/// Each callback forwards **synchronously** to ``handler``, with no `Task {}`. This is safe,
/// because CoreBluetooth calls back only on the queue that `PeripheralHost` used to create the
/// manager. That queue is the `DispatchQueue` behind `PeripheralHost`'s custom
/// `SerialExecutor`.
///
/// This proxy also owns three registries of CoreBluetooth objects, so raw CoreBluetooth
/// objects never cross into BLESwift code. The `CBPeripheralManager` conformance reaches them
/// through the shared associated object. The registries are:
///
/// - a map from ``RequestToken`` to `[CBATTRequest]`
/// - a map from ``CharacteristicIdentifier`` to `CBMutableCharacteristic`
/// - a map of subscribed centrals (`UUID` to `CBCentral`)
///
/// **Concurrency.** A `Mutex` guards ``handler``, as in ``CentralDelegateProxy``. The three
/// registries are `nonisolated(unsafe)` and **queue-confined**. Only delegate callbacks and
/// `PeripheralManaging` conformance methods touch them, and both run on the same serial queue.
final class PeripheralManagerDelegateProxy: NSObject, CBPeripheralManagerDelegate {

    /// Receives each ``PeripheralHostEvent`` that this proxy converts from a CoreBluetooth
    /// callback. A `Mutex` guards it, because the assignment happens off the queue during
    /// construction. The type is `@Sendable` for the reason in ``CentralDelegateProxy/handler``.
    /// The struct wrapper avoids storing the handler directly as the `Mutex` `Value`. See
    /// `CentralDelegateProxy.handlerBox`.
    private struct HandlerStorage: Sendable {
        var handler: (@Sendable (PeripheralHostEvent) -> Void)?
    }
    private let handlerBox = Mutex(HandlerStorage())

    /// The `PeripheralHostEvent` handler that this proxy forwards to. `PeripheralHost` sets it
    /// once.
    var handler: (@Sendable (PeripheralHostEvent) -> Void)? {
        get { handlerBox.withLock { $0.handler } }
        set { handlerBox.withLock { $0.handler = newValue } }
    }

    /// In-flight read and write requests, by the ``RequestToken`` that this proxy created.
    /// Queue-confined (see the type's concurrency note).
    private nonisolated(unsafe) var pendingRequests: [UUID: [CBATTRequest]] = [:]

    /// Live `CBMutableCharacteristic` handles by identifier. Adding services adds them and
    /// `removeAllServices()` clears them. Queue-confined.
    private nonisolated(unsafe) var characteristicHandles: [CharacteristicIdentifier: CBMutableCharacteristic] = [:]

    /// The subscribed centrals by `CBCentral.identifier`, to resolve a value-type
    /// ``Subscriber`` back to its `CBCentral`. Queue-confined.
    private nonisolated(unsafe) var subscribedCentrals: [UUID: CBCentral] = [:]

    #if os(iOS)
    /// Buffers the converted peripheral-role `willRestoreState` payload. The first
    /// `peripheralManagerDidUpdateState(_:)` drains it into ``handler``. As in
    /// ``CentralDelegateProxy/bufferedRestoredState``, `willRestoreState` can arrive during
    /// `CBPeripheralManager.init` itself.
    private let bufferedRestoredState = Mutex<RestoredPeripheralState?>(nil)
    #endif

    // MARK: - Registry access (queue-confined; called from the CB conformance)

    /// Creates a token for `requests` and stores them for a later `respond(to:…)`.
    func storeRequests(_ requests: [CBATTRequest]) -> RequestToken {
        let token = RequestToken()
        pendingRequests[token.rawValue] = requests
        return token
    }

    /// Removes and returns the requests stored for `token`. Returns `nil` if the token is
    /// unknown: it was already answered, or a different manager created it.
    func takeRequests(for token: RequestToken) -> [CBATTRequest]? {
        pendingRequests.removeValue(forKey: token.rawValue)
    }

    /// Records a live characteristic handle for `updateValue` to resolve.
    func registerCharacteristic(_ characteristic: CBMutableCharacteristic, for identifier: CharacteristicIdentifier) {
        characteristicHandles[identifier] = characteristic
    }

    /// The live `CBMutableCharacteristic` for `identifier`, if added.
    func characteristicHandle(for identifier: CharacteristicIdentifier) -> CBMutableCharacteristic? {
        characteristicHandles[identifier]
    }

    /// Clears every recorded characteristic handle. This mirrors `removeAllServices()`.
    func removeAllCharacteristicHandles() {
        characteristicHandles.removeAll()
    }

    /// Resolves value-type ``Subscriber`` values to the live `CBCentral` objects of the current
    /// subscribers. It drops unknown subscribers.
    func resolveCentrals(_ subscribers: [Subscriber]) -> [CBCentral] {
        subscribers.compactMap { subscribedCentrals[$0.id] }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        #if os(iOS)
        if handler != nil {
            let restored = bufferedRestoredState.withLock { buffered -> RestoredPeripheralState? in
                let value = buffered
                buffered = nil
                return value
            }
            if let restored {
                forward(.willRestoreState(restored))
            }
        }
        #endif
        forward(.didUpdateState(CentralState(peripheral.state)))
    }

    #if os(iOS)
    /// Captures CoreBluetooth's peripheral-role restoration payload **synchronously**, converts
    /// it to the `Sendable` ``RestoredPeripheralState``, and buffers it for
    /// ``peripheralManagerDidUpdateState(_:)`` to drain. For why it cannot forward directly,
    /// see ``CentralDelegateProxy``.
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        let serviceIdentifiers = services.map { ServiceIdentifier(cbuuid: $0.uuid) }

        // Register the restored live characteristic handles again, so
        // `updateValue(_:for:onSubscribed:)` can resolve them after a background relaunch. A
        // later `add(_:)` does the same, so this is idempotent.
        for service in services {
            let serviceIdentifier = ServiceIdentifier(cbuuid: service.uuid)
            for characteristic in service.characteristics ?? [] {
                guard let mutable = characteristic as? CBMutableCharacteristic else { continue }
                registerCharacteristic(
                    mutable,
                    for: CharacteristicIdentifier(cbuuid: mutable.uuid, service: serviceIdentifier)
                )
            }
        }

        var advertisement: PeripheralAdvertisement?
        if let advertisementData = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any] {
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .map { ServiceIdentifier(cbuuid: $0) } ?? []
            advertisement = PeripheralAdvertisement(localName: localName, serviceUUIDs: serviceUUIDs)
        }

        bufferedRestoredState.withLock { $0 = RestoredPeripheralState(services: serviceIdentifiers, advertisement: advertisement) }
    }
    #endif

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        forward(.didStartAdvertising(error: error as NSError?))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        forward(.didAddService(ServiceIdentifier(cbuuid: service.uuid), error: error as NSError?))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let characteristic = characteristicIdentifier(for: request.characteristic) else { return }
        let token = storeRequests([request])
        let read = ReadRequest(
            token: token,
            central: Subscriber(request.central),
            characteristic: characteristic,
            offset: request.offset
        )
        forward(.didReceiveRead(read))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        let entries: [WriteRequest.Entry] = requests.compactMap { request in
            guard let characteristic = characteristicIdentifier(for: request.characteristic) else { return nil }
            return WriteRequest.Entry(
                central: Subscriber(request.central),
                characteristic: characteristic,
                offset: request.offset,
                value: request.value ?? Data()
            )
        }
        guard !entries.isEmpty else { return }
        let token = storeRequests(requests)
        forward(.didReceiveWrite(WriteRequest(token: token, entries: entries)))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        subscribedCentrals[central.identifier] = central
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(.didSubscribe(central: Subscriber(central), characteristic: identifier))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscribedCentrals.removeValue(forKey: central.identifier)
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(.didUnsubscribe(central: Subscriber(central), characteristic: identifier))
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        forward(.readyToUpdateSubscribers)
    }

    // MARK: - Forwarding

    private func characteristicIdentifier(for characteristic: CBCharacteristic) -> CharacteristicIdentifier? {
        guard let serviceUUID = characteristic.service?.uuid else { return nil }
        return CharacteristicIdentifier(cbuuid: characteristic.uuid, service: ServiceIdentifier(cbuuid: serviceUUID))
    }

    private func forward(_ event: PeripheralHostEvent) {
        handler?(event)
    }
}

extension Subscriber {
    /// Bridges a `CBCentral` to a value-type ``Subscriber``. It is the only place that reads a
    /// `CBCentral`.
    init(_ central: CBCentral) {
        self.init(id: central.identifier, maximumUpdateValueLength: central.maximumUpdateValueLength)
    }
}

#endif
