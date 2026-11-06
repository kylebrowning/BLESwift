//
//  ConnectionEvent.swift
//  BLESwift
//

import BLESwiftCore

/// A connection-lifecycle event. ``Central/connectionEvents()`` publishes it.
///
/// The stream is a multicast `AsyncStream`. There is no replay. A subscriber sees only the
/// events that occur after it subscribes.
public enum ConnectionEvent: Sendable {

    /// A connection attempt to `PeripheralIdentifier` started.
    case connecting(PeripheralIdentifier)

    /// A connection attempt to `PeripheralIdentifier` succeeded.
    case connected(PeripheralIdentifier)

    /// `PeripheralIdentifier` disconnected. This occurs if the connection attempt failed, timed
    /// out, or was cancelled, and if an established connection was lost.
    ///
    /// - Parameters:
    ///   - error: The reason for the disconnect, if any. The value is `nil` for a clean,
    ///     expected disconnect.
    ///   - willReconnect: Whether ``Central`` will try again, as the active
    ///     ``ReconnectPolicy`` specifies. It is always `false` after an explicit disconnect.
    case disconnected(PeripheralIdentifier, error: Error?, willReconnect: Bool)

    /// ``Central`` makes reconnect attempt number `attempt` (from 1) to `PeripheralIdentifier`,
    /// as the active ``ReconnectPolicy`` specifies.
    case reconnecting(PeripheralIdentifier, attempt: Int)

    /// BLESwift reconnected to `PeripheralIdentifier` and enabled again the notification
    /// subscriptions that selected `survivesReconnect` (see
    /// ``Peripheral/notifications(for:policy:survivesReconnect:)``).
    ///
    /// - `restored` lists the characteristics that notify again on their original streams,
    ///   sorted by UUID string.
    /// - `failed` maps each characteristic that BLESwift could not enable again to an error.
    ///   A characteristic fails if a GATT change removed it, or if the enable call failed.
    ///   Its surviving streams finish with this error.
    ///
    /// BLESwift emits this event once for each successful reconnect that had at least one
    /// surviving subscription.
    case notificationsRestored(PeripheralIdentifier, restored: [CharacteristicIdentifier], failed: [CharacteristicIdentifier: any Error])
}
