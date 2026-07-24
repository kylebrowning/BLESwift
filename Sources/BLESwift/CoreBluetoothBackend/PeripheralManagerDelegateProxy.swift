//
//  PeripheralManagerDelegateProxy.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import Synchronization

/// Bridges real `CBPeripheralManagerDelegate` callbacks into a ``PeripheralHostEvent``
/// handler closure — the `PeripheralManaging` conformance's implementation of
/// `eventHandler` for `CBPeripheralManager`. The peripheral-role counterpart to
/// ``CentralDelegateProxy``.
///
/// Every callback forwards **synchronously** to ``handler``, no `Task {}`: sound because
/// CoreBluetooth only ever calls back on the queue the manager was created with, exactly
/// the `DispatchSerialQueue` backing `PeripheralHost`'s custom `SerialExecutor`.
///
/// Beyond forwarding, this proxy owns three CoreBluetooth-object registries the
/// `CBPeripheralManager` conformance reaches via the shared associated object, so raw
/// CoreBluetooth objects never cross into BLESwift-owned code: a ``RequestToken`` →
/// `[CBATTRequest]` map, a ``CharacteristicIdentifier`` → `CBMutableCharacteristic` map, and
/// a subscribed-central map (`UUID` → `CBCentral`).
///
/// **Concurrency.** ``handler`` is `Mutex`-guarded, like ``CentralDelegateProxy``'s. The
/// three registries below are `nonisolated(unsafe)` and **queue-confined** — touched only
/// from a delegate callback or a `PeripheralManaging` conformance method, both on the same
/// serial queue, never off-queue.
final class PeripheralManagerDelegateProxy: NSObject, CBPeripheralManagerDelegate {

    /// Receives every ``PeripheralHostEvent`` this proxy converts from a real CoreBluetooth
    /// callback. `Mutex`-guarded (assigned off-queue during construction). Typed `@Sendable`
    /// for the same reason as ``CentralDelegateProxy/handler`` — see that type.
    private let handlerBox = Mutex<(@Sendable (PeripheralHostEvent) -> Void)?>(nil)

    /// The `PeripheralHostEvent` handler this proxy forwards to. Set once, by `PeripheralHost`.
    var handler: (@Sendable (PeripheralHostEvent) -> Void)? {
        get { handlerBox.withLock { $0 } }
        set { handlerBox.withLock { $0 = newValue } }
    }

    /// In-flight read/write requests, keyed by the ``RequestToken`` this proxy minted for
    /// each. Queue-confined (see the type's concurrency note).
    private nonisolated(unsafe) var pendingRequests: [UUID: [CBATTRequest]] = [:]

    /// Live `CBMutableCharacteristic` handles, keyed by identifier — populated as services
    /// are added, cleared by `removeAllServices()`. Queue-confined.
    private nonisolated(unsafe) var characteristicHandles: [CharacteristicIdentifier: CBMutableCharacteristic] = [:]

    /// Currently-subscribed centrals, keyed by `CBCentral.identifier`, so a value-type
    /// ``Subscriber`` can be resolved back to its `CBCentral`. Queue-confined.
    private nonisolated(unsafe) var subscribedCentrals: [UUID: CBCentral] = [:]

    #if os(iOS)
    /// Buffers the (already-converted) peripheral-role `willRestoreState` payload until the
    /// first `peripheralManagerDidUpdateState(_:)` drains it into ``handler``. Same delivery
    /// timing hazard as ``CentralDelegateProxy/bufferedRestoredState``: `willRestoreState`
    /// can arrive during `CBPeripheralManager.init` itself.
    private let bufferedRestoredState = Mutex<RestoredPeripheralState?>(nil)
    #endif

    // MARK: - Registry access (queue-confined; called from the CB conformance)

    /// Mints a token for `requests` and stores them for a later `respond(to:…)`.
    func storeRequests(_ requests: [CBATTRequest]) -> RequestToken {
        let token = RequestToken()
        pendingRequests[token.rawValue] = requests
        return token
    }

    /// Removes and returns the requests stored for `token`, or `nil` if unknown (already
    /// answered, or minted by a different manager).
    func takeRequests(for token: RequestToken) -> [CBATTRequest]? {
        pendingRequests.removeValue(forKey: token.rawValue)
    }

    /// Records a live characteristic handle so `updateValue` can resolve it later.
    func registerCharacteristic(_ characteristic: CBMutableCharacteristic, for identifier: CharacteristicIdentifier) {
        characteristicHandles[identifier] = characteristic
    }

    /// The live `CBMutableCharacteristic` for `identifier`, if it has been added.
    func characteristicHandle(for identifier: CharacteristicIdentifier) -> CBMutableCharacteristic? {
        characteristicHandles[identifier]
    }

    /// Clears every recorded characteristic handle (mirrors `removeAllServices()`).
    func removeAllCharacteristicHandles() {
        characteristicHandles.removeAll()
    }

    /// Resolves value-type ``Subscriber``s back to the live `CBCentral`s currently known to
    /// be subscribed. Unknown subscribers are dropped.
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
    /// Captures CoreBluetooth's peripheral-role restoration payload **synchronously**:
    /// converts the raw dictionary to the `Sendable` ``RestoredPeripheralState`` eagerly and
    /// buffers it for ``peripheralManagerDidUpdateState(_:)`` to drain. See
    /// ``CentralDelegateProxy``'s equivalent for why this cannot forward directly.
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        let serviceIdentifiers = services.map { ServiceIdentifier(cbuuid: $0.uuid) }

        // Re-register the live characteristic handles CoreBluetooth restored, so
        // `updateValue(_:for:onSubscribed:)` can resolve them after a background relaunch.
        // Idempotent with a later `add(_:)`.
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
    /// Bridges a `CBCentral` to a value-type ``Subscriber``. Internal to the CoreBluetooth
    /// seam — the only place `CBCentral` is read.
    init(_ central: CBCentral) {
        self.init(id: central.identifier, maximumUpdateValueLength: central.maximumUpdateValueLength)
    }
}
