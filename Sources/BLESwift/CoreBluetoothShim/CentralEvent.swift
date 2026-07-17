//
//  CentralEvent.swift
//  BLESwift
//

import CoreBluetooth
import Foundation

/// A `Sendable` representation of a `CBCentralManagerDelegate` callback.
///
/// The delegate proxy that will bridge real CoreBluetooth callbacks into these events is
/// deferred to a later phase (it must hold the concrete `Central` actor to use
/// `assumeIsolated`). `CentralEvent` is defined now so the shim protocols, fakes, and the
/// actor's eventual handling code all share one Sendable vocabulary. Error payloads are
/// typed `NSError?` rather than `any Error` — `NSError` is unconditionally `Sendable`,
/// while an `any Error` existential is not guaranteed to be; CoreBluetooth's delegate
/// errors are bridged with `as NSError?` at the point they are emitted.
enum CentralEvent: Sendable {

    /// The Bluetooth radio's state changed. Mirrors
    /// `centralManagerDidUpdateState(_:)`.
    case didUpdateState(CBManagerState)

    /// A peripheral was discovered during a scan. Mirrors
    /// `centralManager(_:didDiscover:advertisementData:rssi:)`.
    case didDiscover(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int)

    /// A connection attempt succeeded. Mirrors `centralManager(_:didConnect:)`.
    case didConnect(PeripheralIdentifier)

    /// A connection attempt failed. Mirrors
    /// `centralManager(_:didFailToConnect:error:)`.
    case didFailToConnect(PeripheralIdentifier, error: NSError?)

    /// A connected peripheral disconnected. Mirrors
    /// `centralManager(_:didDisconnectPeripheral:error:)`.
    case didDisconnect(PeripheralIdentifier, error: NSError?)

    /// CoreBluetooth restored preserved state after a background relaunch (iOS). Mirrors
    /// `centralManager(_:willRestoreState:)`, with the raw dictionary already converted to
    /// the `Sendable` ``RestoredState`` by the proxy (which buffers the callback behind a
    /// `Mutex` and forwards this event just before the first `didUpdateState` — see
    /// `CentralDelegateProxy` — because CoreBluetooth can deliver `willRestoreState`
    /// during `CBCentralManager.init`, before the actor is wired to the proxy).
    ///
    /// The case itself is compiled on every platform (`RestoredState` has an internal
    /// mirror off-iOS — dual-access note in `RestorationConfiguration.swift`) so `Central`'s
    /// restoration routing stays testable under `swift test` on macOS; only the iOS proxy
    /// ever produces it from a real CoreBluetooth callback.
    case willRestoreState(RestoredState)
}
