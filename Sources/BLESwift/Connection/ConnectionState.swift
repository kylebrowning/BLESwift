//
//  ConnectionState.swift
//  BLESwift
//

/// A snapshot of one peripheral's connection lifecycle. Unlike ``CentralState`` (the radio's
/// state, readable `nonisolated`), ``Central/connectionState(of:)`` reflects actor-isolated
/// state and so is read via `await`. Every peripheral has its own independent state.
public enum ConnectionState: Sendable {

    /// Not connected, and no connection attempt is in progress.
    case disconnected

    /// A connection attempt is in progress.
    case connecting

    /// Connected to `Peripheral`.
    case connected(Peripheral)

    /// Disconnecting — either an explicit disconnect call is in flight, or
    /// ``Central/cancelAllOperations(error:)`` cancelled a pending connection attempt.
    case disconnecting
}
