//
//  PeripheralConnectionState.swift
//  BLESwiftCore
//

/// One peripheral's connection state, as reported by the backend seam and by state
/// restoration. `Central` tracks this independently per peripheral.
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
