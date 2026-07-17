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
/// Holds its handler `Mutex`-guarded (set once, by `Central`, either directly during
/// `init(configuration:)`'s special construction-order path, or via the `eventHandler`
/// computed property on `CBCentralManager` — see `CBCentralManager+CentralManaging.swift`).
/// A `Mutex` rather than a plain stored property specifically because `willRestoreState`
/// can arrive **during `CBCentralManager.init` itself**, before the handler has been
/// assigned (see ``bufferedRestoredState``) — the same timing hazard the buffer below
/// exists for.
///
/// Every callback forwards synchronously to ``handler`` (SE-0424-adjacent pattern: the
/// handler closure `Central` installs itself calls `assumeIsolated`): this is sound
/// because CoreBluetooth only ever calls back on the queue the manager was created with,
/// which is exactly the `DispatchSerialQueue` backing `Central`'s custom `SerialExecutor`.
///
/// This proxy is also the ONLY place BLESwift touches a raw `[String: Any]` advertisement
/// dictionary: `didDiscover` converts it into ``AdvertisementData`` eagerly, before
/// anything crosses into actor-isolated code.
///
/// The `CBPeripheralDelegate` half of what was previously a combined proxy now lives in
/// ``PeripheralDelegateProxy`` — one instance per `CBPeripheral`, attached via that type's
/// own `eventHandler` conformance, not this one.
final class CentralDelegateProxy: NSObject, CBCentralManagerDelegate {

    /// Receives every ``CentralEvent`` this proxy converts from a real CoreBluetooth
    /// callback. `Mutex`-guarded so the assignment (from `Central`, off the CB queue
    /// during `init`) and a callback delivery racing in from the CB queue can never
    /// observe a torn value.
    ///
    /// Typed `@Sendable` (unlike the `CentralManaging.eventHandler` protocol requirement
    /// this ultimately backs, which is plain `((CentralEvent) -> Void)?` per its BINDING
    /// signature): `Mutex`'s `withLock` requires its `Value` to be safely handed across
    /// isolation domains at the point of storage (a `sending` parameter), which a
    /// non-`@Sendable` closure type cannot satisfy even though the closures `Central`
    /// actually stores here (capturing only `[weak self]` of the `Central` actor itself,
    /// which is unconditionally `Sendable`) are safe in practice. `CBCentralManager`'s
    /// `eventHandler` setter (`CBCentralManager+CentralManaging.swift`) bridges the
    /// protocol's non-`@Sendable` closure into this `@Sendable` storage with a narrowly
    /// justified `nonisolated(unsafe)` wrap — see that setter's doc comment.
    private let handlerBox = Mutex<(@Sendable (CentralEvent) -> Void)?>(nil)

    /// The `CentralEvent` handler this proxy forwards to. Set once, by `Central`.
    var handler: (@Sendable (CentralEvent) -> Void)? {
        get { handlerBox.withLock { $0 } }
        set { handlerBox.withLock { $0 = newValue } }
    }

    #if os(iOS)
    /// Buffers the (already-converted) `willRestoreState` payload until the first
    /// `centralManagerDidUpdateState(_:)` drains it into ``handler``.
    ///
    /// Buffered rather than forwarded immediately because `willRestoreState` is the one
    /// delegate callback that can arrive **during `CBCentralManager.init` itself** —
    /// before `Central` has installed ``handler`` at all (Phase 0 verified constraint:
    /// `willRestoreState` precedes `centralManagerDidUpdateState`). A `Mutex` (not
    /// queue-confinement assumptions) guards the buffer precisely because of that unusual
    /// delivery timing; the conversion from the raw `[String: Any]` dictionary to the
    /// `Sendable` ``RestoredState`` happens eagerly, right here in the proxy — the only
    /// place BLESwift touches restoration dictionaries, same as advertisement dictionaries.
    private let bufferedRestoredState = Mutex<RestoredState?>(nil)
    #endif

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        #if os(iOS)
        // Drain a buffered `willRestoreState` into the handler *before* the state event,
        // so the eventual consumer observes CoreBluetooth's own ordering (restore first,
        // then state). If `handler` still isn't installed (not expected by the time a
        // state update arrives, but not provably impossible), leave the buffer intact for
        // the next state update rather than dropping the restoration payload.
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
    /// Unlike the pre-split combined proxy, this no longer eagerly attaches itself as each
    /// restored peripheral's event target — this proxy no longer conforms to
    /// `CBPeripheralDelegate` at all. `Central.handle(_: CentralEvent)`'s
    /// `.willRestoreState` case wires each restored peripheral's `eventHandler` instead,
    /// once it actually runs (at the first `didUpdateState` drain, above) — a `Central`
    /// instance to route events into is guaranteed to exist by that point, unlike here.
    /// This narrows (but does not close) the same real-CoreBluetooth race window the
    /// pre-split design covered: a notification arriving between the raw `willRestoreState`
    /// callback and the buffered drain at first `didUpdateState` is not yet covered by an
    /// attached event target. That gap is not exercised by BLESwift's fake-driven test
    /// suite (`FakeCentral.simulateRestoration`'s delivery ordering makes the drain run
    /// before any subsequently-simulated peripheral event), and is disclosed as a known,
    /// narrow limitation of this split rather than silently preserved or silently dropped.
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
