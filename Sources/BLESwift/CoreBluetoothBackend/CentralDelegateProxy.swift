//
//  CentralDelegateProxy.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import BLESwiftCompat17

/// Bridges `CBCentralManagerDelegate` callbacks into a `CentralEvent` handler closure. It
/// implements `eventHandler` for `CBCentralManager` in the `CentralManaging` conformance.
///
/// A `Mutex` guards the handler and not a plain stored property, because `willRestoreState`
/// can arrive **during `CBCentralManager.init` itself**, before `Central` assigns the handler
/// (see ``bufferedRestoredState``).
///
/// Each callback forwards synchronously to ``handler``. This is safe, because CoreBluetooth
/// calls back only on the queue that `Central` used to create the manager. That queue is the
/// `DispatchQueue` behind `Central`'s custom `SerialExecutor`.
///
/// This proxy is the ONLY place where BLESwift reads a raw `[String: Any]` advertisement
/// dictionary. `didDiscover` converts it to ``AdvertisementData`` before anything crosses into
/// actor-isolated code.
///
/// ``PeripheralDelegateProxy`` has the `CBPeripheralDelegate` half, one instance for each
/// `CBPeripheral`.
final class CentralDelegateProxy: NSObject, CBCentralManagerDelegate {

    /// Receives each ``CentralEvent`` that this proxy converts from a CoreBluetooth callback.
    /// A `Mutex` guards it, so the assignment from `Central` (off the CB queue, during `init`)
    /// and a callback on the CB queue can race without a torn value.
    ///
    /// The type is `@Sendable`, because `Mutex.withLock` needs a `Value` that is safe to hand
    /// across isolation domains. The protocol's plain `eventHandler` closure is not
    /// `@Sendable`. The `CBCentralManager.eventHandler` setter bridges the two with a narrow
    /// `nonisolated(unsafe)` wrap.
    ///
    /// The handler is wrapped in a struct and never stored directly as the `Mutex` `Value`.
    /// `withLock` passes its `Value` to the body as `inout`. For a function-type `Value`, the
    /// compiler reabstracts the closure on the way in and writes a reabstracted copy back,
    /// even from a read (swiftlang/swift#91348). Each `get` then nested the handler two
    /// thunks deeper, and after some thousands of events a call overflowed the stack. A struct
    /// `Value` has no function-type abstraction to convert. Each `Mutex` in BLESwift that holds
    /// a closure uses this shape.
    private struct HandlerStorage: Sendable {
        var handler: (@Sendable (CentralEvent) -> Void)?
    }
    private let handlerBox = Mutex(HandlerStorage())

    /// The `CentralEvent` handler that this proxy forwards to. `Central` sets it once.
    var handler: (@Sendable (CentralEvent) -> Void)? {
        get { handlerBox.withLock { $0.handler } }
        set { handlerBox.withLock { $0.handler = newValue } }
    }

    #if os(iOS)
    /// Buffers the converted `willRestoreState` payload. The first
    /// `centralManagerDidUpdateState(_:)` drains it into ``handler``. The proxy does not
    /// forward it immediately, because `willRestoreState` can arrive **during
    /// `CBCentralManager.init` itself**, before `Central` installs ``handler``. For the same
    /// reason, a `Mutex` guards it and not queue confinement.
    private let bufferedRestoredState = Mutex<RestoredState?>(nil)
    #endif

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        #if os(iOS)
        // Drain a buffered `willRestoreState` before the state event, to keep CoreBluetooth's
        // order. If `handler` is not installed yet, keep the buffer. Do not drop the payload.
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
    /// Captures CoreBluetooth's state-restoration payload **synchronously**, converts it to the
    /// `Sendable` ``RestoredState``, and buffers it for ``centralManagerDidUpdateState(_:)`` to
    /// drain. For why it cannot forward directly, see ``bufferedRestoredState``.
    ///
    /// This proxy does not conform to `CBPeripheralDelegate`. After the buffer drains, the
    /// `.willRestoreState` case of `Central.handle(_:)` connects the `eventHandler` of each
    /// restored peripheral. Known limitation: a peripheral event that arrives between the raw
    /// `willRestoreState` callback and that drain has no event target yet.
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
