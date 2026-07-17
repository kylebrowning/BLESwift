//
//  ConnectionState.swift
//  BLESwift
//

/// A synchronous snapshot of ``Central``'s connection lifecycle, mirroring its internal
/// `Phase` state machine.
///
/// Unlike ``CentralState`` (the Bluetooth radio's state, readable `nonisolated`),
/// `connectionState` reflects actor-isolated state and so is read via `await`.
public enum ConnectionState: Sendable {

    /// Not connected, and no connection attempt is in progress.
    case disconnected

    /// A connection attempt is in progress.
    case connecting

    /// Connected to `Peripheral`.
    case connected(Peripheral)

    /// Disconnecting — either an explicit ``Central/disconnect()``/
    /// ``Central/disconnect(immediate:)`` call is in flight, or ``Central/cancelAllOperations(error:)``
    /// cancelled a pending connection attempt.
    case disconnecting
}
