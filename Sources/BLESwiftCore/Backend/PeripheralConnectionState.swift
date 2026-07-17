//
//  PeripheralConnectionState.swift
//  BLESwiftCore
//

/// The connection state of a single peripheral, as reported by the backend seam and by
/// state restoration.
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
