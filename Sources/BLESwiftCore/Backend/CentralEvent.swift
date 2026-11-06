//
//  CentralEvent.swift
//  BLESwiftCore
//

import Foundation

/// A `Sendable` representation of a `CBCentralManagerDelegate` callback. It uses only types that
/// BLESwift owns. See ``CentralManaging`` for the delivery contract.
///
/// Error payloads are `NSError?` and not `any Error`, because `NSError` is always `Sendable` and an
/// `any Error` existential is not guaranteed to be.
public enum CentralEvent: Sendable {

    /// The state of the Bluetooth radio changed. Mirrors `centralManagerDidUpdateState(_:)`.
    case didUpdateState(CentralState)

    /// A peripheral was discovered during a scan. Mirrors
    /// `centralManager(_:didDiscover:advertisementData:rssi:)`.
    case didDiscover(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int)

    /// A connection attempt succeeded. Mirrors `centralManager(_:didConnect:)`.
    case didConnect(PeripheralIdentifier)

    /// A connection attempt failed. Mirrors `centralManager(_:didFailToConnect:error:)`.
    case didFailToConnect(PeripheralIdentifier, error: NSError?)

    /// A connected peripheral disconnected. Mirrors
    /// `centralManager(_:didDisconnectPeripheral:error:)`.
    case didDisconnect(PeripheralIdentifier, error: NSError?)

    /// A system-level connection event occurred for a peripheral that an earlier
    /// `registerForConnectionEvents(services:peripherals:)` call matched. Mirrors
    /// `centralManager(_:connectionEventDidOccur:for:)`. This event never occurs on macOS.
    case connectionEventDidOccur(peripheral: UUID, event: SystemConnectionEvent.Kind)

    /// The ANCS authorization status of a connected peripheral changed. Mirrors
    /// `centralManager(_:didUpdateANCSAuthorizationFor:)`. This event occurs only on iOS.
    case didUpdateANCSAuthorization(peripheral: UUID, authorized: Bool)

    /// CoreBluetooth restored preserved state after a background relaunch (iOS). Mirrors
    /// `centralManager(_:willRestoreState:)`. The proxy has already converted the raw dictionary to
    /// the `Sendable` ``RestoredState``.
    case willRestoreState(RestoredState)
}
