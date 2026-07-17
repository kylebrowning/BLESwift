//
//  PeripheralConnectionState.swift
//  BLESwiftCore
//

/// One peripheral's connection state, as reported by the backend seam and by state
/// restoration. `Central` tracks this independently per peripheral — see
/// `Central.connectionState(of:)` in the `BLESwift` module.
///
/// BLESwift-owned; the backend's native connection-state mapping (`init(_:)`) lives in the
/// `BLESwift` module — this type never exposes a CoreBluetooth type in its own public API.
public enum PeripheralConnectionState: Sendable, Hashable {

    /// Not connected, and no connection attempt is in progress.
    case disconnected

    /// A connection attempt is in progress.
    case connecting

    /// Connected.
    case connected

    /// Disconnecting.
    case disconnecting
}
