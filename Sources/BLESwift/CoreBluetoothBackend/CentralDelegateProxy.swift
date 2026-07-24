//
//  CentralDelegateProxy.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import Synchronization

/// Bridges real `CBCentralManagerDelegate` callbacks into a `CentralEvent` handler
/// closure — the `CentralManaging` conformance's implementation of `eventHandler` for
/// `CBCentralManager`.
///
/// Holds its handler `Mutex`-guarded rather than a plain stored property specifically
/// because `willRestoreState` can arrive **during `CBCentralManager.init` itself**, before
/// the handler has been assigned (see ``bufferedRestoredState``).
///
/// Every callback forwards synchronously to ``handler``: sound because CoreBluetooth only
/// ever calls back on the queue the manager was created with, which is exactly the
/// `DispatchSerialQueue` backing `Central`'s custom `SerialExecutor`.
///
/// This proxy is also the ONLY place BLESwift touches a raw `[String: Any]` advertisement
/// dictionary: `didDiscover` converts it into ``AdvertisementData`` eagerly, before
/// anything crosses into actor-isolated code.
///
/// The `CBPeripheralDelegate` half of what was previously a combined proxy now lives in
/// ``PeripheralDelegateProxy`` — one instance per `CBPeripheral`.
final class CentralDelegateProxy: NSObject, CBCentralManagerDelegate {

    /// Receives every ``CentralEvent`` this proxy converts from a real CoreBluetooth
    /// callback. `Mutex`-guarded so the assignment (from `Central`, off the CB queue
    /// during `init`) and a callback delivery racing in from the CB queue can never
    /// observe a torn value.
    ///
    /// Typed `@Sendable` because `Mutex.withLock` requires its `Value` be safely handed
    /// across isolation domains, which the protocol's plain, non-`@Sendable`
    /// `eventHandler` closure type cannot satisfy — `CBCentralManager`'s `eventHandler`
    /// setter bridges the two with a narrowly justified `nonisolated(unsafe)` wrap.
    private let handlerBox = Mutex<(@Sendable (CentralEvent) -> Void)?>(nil)

    /// The `CentralEvent` handler this proxy forwards to. Set once, by `Central`.
    var handler: (@Sendable (CentralEvent) -> Void)? {
        get { handlerBox.withLock { $0 } }
        set { handlerBox.withLock { $0 = newValue } }
    }

    #if os(iOS)
    /// Buffers the (already-converted) `willRestoreState` payload until the first
    /// `centralManagerDidUpdateState(_:)` drains it into ``handler``. Buffered rather than
    /// forwarded immediately because `willRestoreState` is the one delegate callback that
    /// can arrive **during `CBCentralManager.init` itself**, before `Central` has installed
    /// ``handler`` at all. `Mutex`-guarded, not queue-confinement, for that reason.
    private let bufferedRestoredState = Mutex<RestoredState?>(nil)
    #endif

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        #if os(iOS)
        // Drain a buffered `willRestoreState` before the state event, preserving
        // CoreBluetooth's own ordering. If `handler` isn't installed yet, leave the buffer
        // intact rather than dropping the restoration payload.
        if handler != nil {
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
    /// raw dictionary to the `Sendable` ``RestoredState`` eagerly and buffers it for
    /// ``centralManagerDidUpdateState(_:)`` to drain. See ``bufferedRestoredState`` for why
    /// this cannot forward directly.
    ///
    /// This proxy no longer conforms to `CBPeripheralDelegate`; `Central.handle(_:)`'s
    /// `.willRestoreState` case wires each restored peripheral's `eventHandler` instead,
    /// once the buffer drains. Known narrow limitation: a peripheral event arriving between
    /// the raw `willRestoreState` callback and that drain is not yet covered by an attached
    /// event target.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
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

    // MARK: - Forwarding

    private func identifier(for peripheral: CBPeripheral) -> PeripheralIdentifier {
        PeripheralIdentifier(uuid: peripheral.identifier, name: peripheral.name)
    }

    private func forward(_ event: CentralEvent) {
        handler?(event)
    }
}
