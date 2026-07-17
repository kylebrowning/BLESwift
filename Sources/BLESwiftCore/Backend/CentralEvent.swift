//
//  CentralEvent.swift
//  BLESwiftCore
//

import Foundation

/// This is part of BLESwift's backend implementation seam (see ``CentralManaging``).
/// Conforming your own backend is possible but unsupported: the semantic contract (event
/// ordering, queue confinement, delivery asynchrony) is documented on ``CentralManaging``
/// on a best-effort basis and may gain requirements in any release.
///
/// A `Sendable` representation of a `CBCentralManagerDelegate` callback, speaking
/// exclusively in BLESwift-owned (never CoreBluetooth) types.
///
/// The delegate proxy that bridges real CoreBluetooth callbacks into these events lives in
/// the `BLESwift` module. Error payloads are typed `NSError?` rather than `any Error` —
/// `NSError` is unconditionally `Sendable`, while an `any Error` existential is not
/// guaranteed to be; CoreBluetooth's delegate errors are bridged with `as NSError?` at the
/// point they are emitted.
public enum CentralEvent: Sendable {

    /// The Bluetooth radio's state changed. Mirrors
    /// `centralManagerDidUpdateState(_:)`.
    case didUpdateState(CentralState)

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
    /// The case itself is compiled on every platform (`RestoredState` has a `package`
    /// mirror off-iOS — dual-access note in `RestorationConfiguration.swift`) so `Central`'s
    /// restoration routing stays testable under `swift test` on macOS; only the iOS proxy
    /// ever produces it from a real CoreBluetooth callback.
    case willRestoreState(RestoredState)
}
