//
//  ConnectionEvent.swift
//  BLESwift
//

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

    /// `PeripheralIdentifier` disconnected — whether because a connection attempt failed,
    /// timed out, was cancelled, or an established connection was lost (expectedly, via
    /// ``Central/disconnect()``/``Central/disconnect(immediate:)``, or unexpectedly).
    ///
    /// - Parameters:
    ///   - error: The reason for the disconnect, if any. `nil` for a clean, expected
    ///     disconnect that CoreBluetooth reported no error for.
    ///   - willReconnect: Whether ``Central`` will attempt to reconnect per the
    ///     ``ReconnectPolicy`` given to the `connect` call that established (or was
    ///     attempting to establish) this connection. Always `false` for a disconnect
    ///     triggered by an explicit ``Central/disconnect()``/``Central/disconnect(immediate:)``/
    ///     ``Central/cancelAllOperations(error:)`` call.
    case disconnected(PeripheralIdentifier, error: Error?, willReconnect: Bool)

    /// ``Central`` is attempting reconnect attempt number `attempt` (1-indexed) to
    /// `PeripheralIdentifier`, per an active ``ReconnectPolicy``.
    case reconnecting(PeripheralIdentifier, attempt: Int)
}
