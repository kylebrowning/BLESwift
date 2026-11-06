//
//  RestorationEvent.swift
//  BLESwift
//

// NOTE: This is a dual-access declaration. See the note in `RestorationConfiguration.swift`.
// It is public on iOS and an internal mirror on other platforms. **Keep the two in sync.**

import BLESwiftCore
import Foundation

#if os(iOS)

/// A background-restoration event. ``Central/restorationEvents()`` publishes it.
///
/// The stream is **buffered and replayed**. It buffers every event from the creation of
/// `Central` and replays them in order to the first consumer, even if the consumer starts
/// late.
public enum RestorationEvent: Sendable {

    /// CoreBluetooth restored preserved state. It is a `Sendable` capture of the
    /// `willRestoreState` delegate callback, and it is always the first event of a restored
    /// launch. ``restoredConnection(_:)`` or ``failedToRestoreConnection(_:error:)`` follow
    /// when the radio reports powered-on and `Central` finishes the routing.
    case willRestore(RestoredState)

    /// A restored connection is live again. There are two cases:
    ///
    /// - The peripheral was restored already connected. Its `Peripheral` handle is available
    ///   through ``Central/connectionState(of:)``.
    /// - The manual reconnect of a restored-*connecting* peripheral succeeded.
    ///
    /// Each restored peripheral produces its own event.
    case restoredConnection(PeripheralIdentifier)

    /// The connection restoration failed. The error depends on the cause:
    ///
    /// - ``BLESwiftError/notConnected`` for a peripheral restored in the `disconnecting` or
    ///   `disconnected` state.
    /// - The error of the manual reconnect of a restored-*connecting* peripheral. For a
    ///   timeout, it is ``BLESwiftError/connectionTimedOut``.
    /// - ``BLESwiftError/startupBackgroundTaskExpired`` if iOS's startup background time ran
    ///   out during the restoration.
    /// - ``BLESwiftError/bluetoothUnavailable`` if the radio never reached powered-on.
    case failedToRestoreConnection(PeripheralIdentifier, error: Error)

    /// A characteristic value arrived with no notification subscriber and no pending read. The
    /// restored peripheral still notifies from a subscription of the previous app launch.
    ///
    /// To receive values, subscribe with `Peripheral.notifications(for:policy:)`. To stop the
    /// notifications, subscribe and then cancel. The last unsubscribe turns notifications off.
    case unhandledNotification(PeripheralIdentifier, CharacteristicIdentifier, Data?)
}

#else

/// Internal mirror of the public `RestorationEvent`, which is iOS-only. See the dual-access
/// note in `RestorationConfiguration.swift`.
enum RestorationEvent: Sendable {
    case willRestore(RestoredState)
    case restoredConnection(PeripheralIdentifier)
    case failedToRestoreConnection(PeripheralIdentifier, error: Error)
    case unhandledNotification(PeripheralIdentifier, CharacteristicIdentifier, Data?)
}

#endif
