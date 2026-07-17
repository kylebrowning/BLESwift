//
//  CentralDelegateProxy.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
#if os(iOS)
import Synchronization
#endif

/// Bridges real CoreBluetooth delegate callbacks into ``Central``'s internal event
/// handlers.
///
/// Holds a `weak` back-reference to the ``Central`` it serves. `Central` strongly owns
/// this proxy (as its `CBCentralManagerDelegate`/`CBPeripheralDelegate`), so a strong
/// reference here would be a retain cycle.
///
/// Every callback forwards synchronously via `central.assumeIsolated { ... }` (SE-0424):
/// this is sound because CoreBluetooth only ever calls back on the queue the manager was
/// created with, which is exactly the `DispatchSerialQueue` backing `Central`'s custom
/// `SerialExecutor` — by the time a callback arrives here, it is already running on the
/// actor's own executor, just without the compiler's static proof of that fact.
/// `assumeIsolated` supplies that proof (or traps if it's ever wrong, which would indicate
/// a real bug in the queue/executor wiring, not a reachable runtime condition).
///
/// This proxy is also the ONLY place BLESwift touches a raw `[String: Any]` advertisement
/// dictionary: `didDiscover` converts it into ``AdvertisementData`` eagerly, before
/// anything crosses into actor-isolated code.
final class CentralDelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    /// The `Central` this proxy forwards callbacks to.
    weak var central: Central?

    #if os(iOS)
    /// Buffers the (already-converted) `willRestoreState` payload until the first
    /// `centralManagerDidUpdateState(_:)` drains it into the actor.
    ///
    /// Buffered rather than forwarded immediately because `willRestoreState` is the one
    /// delegate callback that can arrive **during `CBCentralManager.init` itself** —
    /// before `Central.init` has executed `proxy.central = self`, i.e. before the actor is
    /// wired to this proxy at all (Phase 0 verified constraint: `willRestoreState`
    /// precedes `centralManagerDidUpdateState`). A `Mutex` (not queue-confinement
    /// assumptions) guards the buffer precisely because of that unusual delivery timing;
    /// the conversion from the raw `[String: Any]` dictionary to the `Sendable`
    /// ``RestoredState`` happens eagerly, right here in the proxy — the only place BLESwift
    /// touches restoration dictionaries, same as advertisement dictionaries.
    private let bufferedRestoredState = Mutex<RestoredState?>(nil)
    #endif

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        #if os(iOS)
        // Drain a buffered `willRestoreState` into the actor *before* the state event, so
        // the actor observes CoreBluetooth's own ordering (restore first, then state). If
        // the actor still isn't wired (`central == nil` — not expected by the time a state
        // update arrives, but not provably impossible), leave the buffer intact for the
        // next state update rather than dropping the restoration payload.
        if self.central != nil {
            let restored = bufferedRestoredState.withLock { buffered -> RestoredState? in
                let value = buffered
                buffered = nil
                return value
            }
            if let restored {
                forward(.willRestoreState(restored))
            }
        }
        #endif
        forward(.didUpdateState(CentralState(central.state)))
    }

    #if os(iOS)
    /// Captures CoreBluetooth's state-restoration payload **synchronously**: converts the
    /// raw dictionary to the `Sendable` ``RestoredState`` eagerly, installs this proxy as
    /// the restored peripherals' delegate (so their GATT callbacks — including
    /// notifications from a listen that survived the relaunch — route here), and buffers
    /// the payload for ``centralManagerDidUpdateState(_:)`` to drain. See
    /// ``bufferedRestoredState`` for why this cannot forward into the actor directly.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                // The shared delegate-wiring mechanism (see `PeripheralRemote.attachEventTarget(_:)`),
                // applied here — earlier than `Central`'s own attach during `.poweredOn`
                // routing — so notifications arriving in the willRestoreState→routing
                // window already reach this proxy.
                peripheral.attachEventTarget(self)
            }
        }
        let restored = RestoredState(restorationDictionary: dict)
        bufferedRestoredState.withLock { $0 = restored }
    }
    #endif

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let identifier = PeripheralIdentifier(uuid: peripheral.identifier, name: peripheral.name)
        let advertisement = AdvertisementData(advertisementData: advertisementData)
        forward(.didDiscover(peripheral: identifier, advertisement: advertisement, rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        forward(.didConnect(identifier(for: peripheral)))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        forward(.didFailToConnect(identifier(for: peripheral), error: error as NSError?))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        forward(.didDisconnect(identifier(for: peripheral), error: error as NSError?))
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        forward(.didDiscoverServices(error: error as NSError?), from: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        forward(
            .didDiscoverCharacteristics(service: ServiceIdentifier(cbuuid: service.uuid), error: error as NSError?),
            from: peripheral
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(.didWriteValue(characteristic: identifier, error: error as NSError?), from: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(
            .didUpdateValue(characteristic: identifier, value: characteristic.value, error: error as NSError?),
            from: peripheral
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(
            .didUpdateNotificationState(characteristic: identifier, isNotifying: characteristic.isNotifying, error: error as NSError?),
            from: peripheral
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        forward(.didReadRSSI(RSSI.intValue, error: error as NSError?), from: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        forward(.didModifyServices(invalidatedServices.map { ServiceIdentifier(cbuuid: $0.uuid) }), from: peripheral)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        forward(.isReadyToSendWriteWithoutResponse, from: peripheral)
    }

    // MARK: - Forwarding

    private func identifier(for peripheral: CBPeripheral) -> PeripheralIdentifier {
        PeripheralIdentifier(uuid: peripheral.identifier, name: peripheral.name)
    }

    /// Resolves `characteristic`'s owning service, or `nil` if CoreBluetooth ever hands
    /// back a characteristic with no `service` set (not expected in practice, but
    /// `CBCharacteristic.service` is optional).
    private func characteristicIdentifier(for characteristic: CBCharacteristic) -> CharacteristicIdentifier? {
        guard let service = characteristic.service else { return nil }
        return CharacteristicIdentifier(cbuuid: characteristic.uuid, service: ServiceIdentifier(cbuuid: service.uuid))
    }

    private func forward(_ event: CentralEvent) {
        guard let central else { return }
        central.assumeIsolated { $0.handle(event) }
    }

    private func forward(_ event: PeripheralEvent, from peripheral: CBPeripheral) {
        guard let central else { return }
        let peripheralIdentifier = identifier(for: peripheral)
        central.assumeIsolated { $0.handle(event, from: peripheralIdentifier) }
    }
}
