//
//  PeripheralConnectionState.swift
//  BLESwiftCore
//

/// The connection state of one peripheral, as the backend seam and state restoration report it.
/// `Central` tracks this state for each peripheral independently.
public enum PeripheralConnectionState: Sendable, Hashable {

    /// Not connected, and no connection attempt is in progress.
    case disconnected

    /// A connection attempt is in progress.
    case connecting

    /// Connected.
    case connected

    /// A disconnection is in progress.
    case disconnecting
}
