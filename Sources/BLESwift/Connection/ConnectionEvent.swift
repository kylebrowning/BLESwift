//
//  ConnectionEvent.swift
//  BLESwift
//

import BLESwiftCore

/// A connection-lifecycle event, published by ``Central/connectionEvents()``.
///
/// Published as a multicast `AsyncStream` — every subscriber sees every event from the
/// point it starts consuming (no replay: a late subscriber does not see events that
/// happened before it subscribed).
public enum ConnectionEvent: Sendable {

    /// A connection attempt to `PeripheralIdentifier` has started.
    case connecting(PeripheralIdentifier)

    /// A connection attempt to `PeripheralIdentifier` succeeded.
    case connected(PeripheralIdentifier)

    /// `PeripheralIdentifier` disconnected — whether the connection attempt failed, timed
    /// out, was cancelled, or an established connection was lost.
    ///
    /// - Parameters:
    ///   - error: The reason for the disconnect, if any. `nil` for a clean, expected
    ///     disconnect.
    ///   - willReconnect: Whether ``Central`` will retry per the active ``ReconnectPolicy``.
    ///     Always `false` for an explicit disconnect call.
    case disconnected(PeripheralIdentifier, error: Error?, willReconnect: Bool)

    /// ``Central`` is attempting reconnect attempt number `attempt` (1-indexed) to
    /// `PeripheralIdentifier`, per an active ``ReconnectPolicy``.
    case reconnecting(PeripheralIdentifier, attempt: Int)
}
