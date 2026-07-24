//
//  CentralEvent.swift
//  BLESwiftCore
//

import Foundation

/// A `Sendable` representation of a `CBCentralManagerDelegate` callback, speaking
/// exclusively in BLESwift-owned types. See ``CentralManaging`` for the delivery contract.
///
/// Error payloads are typed `NSError?` rather than `any Error`, since `NSError` is
/// unconditionally `Sendable` and an `any Error` existential is not guaranteed to be.
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
    /// the `Sendable` ``RestoredState`` by the proxy.
    case willRestoreState(RestoredState)
}
