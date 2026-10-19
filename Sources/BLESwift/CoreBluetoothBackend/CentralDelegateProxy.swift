//
//  CentralDelegateProxy.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import BLESwiftCompat17

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
/// `DispatchQueue` backing `Central`'s custom `SerialExecutor`.
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
    ///
    /// Wrapped in a struct, never stored as the `Mutex`'s `Value` directly (#53). `withLock`
    /// hands its `Value` to the body `inout`; when that `Value` is a function type the
    /// compiler reabstracts the closure on the way in and writes a reabstracted copy back on
    /// the way out, even from a read (swiftlang/swift#91348). Each `get` then nested the
    /// stored handler two thunks deeper, and after some thousands of events calling it
    /// overflowed the stack. A struct `Value` has no function-type abstraction to convert.
    /// Every closure-holding `Mutex` in BLESwift uses the same shape.
    private struct HandlerStorage: Sendable {
        var handler: (@Sendable (CentralEvent) -> Void)?
    }
    private let handlerBox = Mutex(HandlerStorage())

    /// The `CentralEvent` handler this proxy forwards to. Set once, by `Central`.
    var handler: (@Sendable (CentralEvent) -> Void)? {
        get { handlerBox.withLock { $0.handler } }
        set { handlerBox.withLock { $0.handler = newValue } }
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

    #if !os(macOS)
    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        let kind: SystemConnectionEvent.Kind
        switch event {
        case .peerConnected:
            kind = .peerConnected
        case .peerDisconnected:
            kind = .peerDisconnected
        @unknown default:
            return
        }
        forward(.connectionEventDidOccur(peripheral: peripheral.identifier, event: kind))
    }
    #endif

    #if os(iOS)
    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        forward(.didUpdateANCSAuthorization(peripheral: peripheral.identifier, authorized: peripheral.ancsAuthorized))
    }
    #endif

    // MARK: - Forwarding

    private func identifier(for peripheral: CBPeripheral) -> PeripheralIdentifier {
        PeripheralIdentifier(uuid: peripheral.identifier, name: peripheral.name)
    }

    private func forward(_ event: CentralEvent) {
        handler?(event)
    }
}
