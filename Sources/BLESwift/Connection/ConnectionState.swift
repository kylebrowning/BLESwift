//
//  ConnectionState.swift
//  BLESwift
//

/// A synchronous snapshot of one peripheral's connection lifecycle, mirroring `Central`'s
/// internal per-peripheral state machine for that identifier.
///
/// Unlike ``CentralState`` (the Bluetooth radio's state, readable `nonisolated`),
/// ``Central/connectionState(of:)`` reflects actor-isolated state and so is read via `await`.
/// Every peripheral `Central` tracks has its own independent `ConnectionState` — connecting or
/// disconnecting one peripheral has no effect on any other's.
public enum ConnectionState: Sendable {

    /// Not connected, and no connection attempt is in progress.
    case disconnected

    /// A connection attempt is in progress.
    case connecting

    /// Connected to `Peripheral`.
    case connected(Peripheral)

    /// Disconnecting — either an explicit ``Central/disconnect(_:)``/
    /// ``Central/disconnect(_:immediate:)``/``Central/disconnectAll()`` call is in flight for
    /// this peripheral, or ``Central/cancelAllOperations(error:)`` cancelled a pending
    /// connection attempt.
    case disconnecting
}
