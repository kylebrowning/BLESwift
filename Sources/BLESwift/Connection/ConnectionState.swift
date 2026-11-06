//
//  ConnectionState.swift
//  BLESwift
//

/// A snapshot of one peripheral's connection lifecycle. Each peripheral has its own state.
/// Unlike ``CentralState``, you read ``Central/connectionState(of:)`` with `await`, because it
/// is actor-isolated.
public enum ConnectionState: Sendable {

    /// Not connected, and no connection attempt is in progress.
    case disconnected

    /// A connection attempt is in progress.
    case connecting

    /// Connected to `Peripheral`.
    case connected(Peripheral)

    /// Disconnecting. This occurs during an explicit disconnect, and when
    /// ``Central/cancelAllOperations(error:)`` cancels a pending connection attempt.
    case disconnecting
}
