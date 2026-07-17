//
//  RestorationEvent.swift
//  BLESwift
//

// NOTE — dual-access declaration: see the note in `RestorationConfiguration.swift`.
// Public on iOS, internal mirror elsewhere. **Keep the two in sync.**

import BLESwiftCore
import Foundation

#if os(iOS)

/// A background-restoration event, published by ``Central/restorationEvents()``.
///
/// Surfaced as a **buffered, replayed** event stream, rather than a pair of delegate
/// protocols: every event is buffered from `Central`'s creation and replayed in order to
/// the first ``Central/restorationEvents()`` consumer, so nothing restored during launch is
/// lost even if the consumer task starts strictly after CoreBluetooth delivered the state.
public enum RestorationEvent: Sendable {

    /// CoreBluetooth is restoring preserved state — the eager, `Sendable` capture of its
    /// `willRestoreState` delegate callback. Always the first restoration event of a
    /// restored launch; ``restoredConnection(_:)``/``failedToRestoreConnection(_:error:)``
    /// follow once the radio reports powered-on and `Central` finishes routing.
    case willRestore(RestoredState)

    /// A restored connection is live again: either the peripheral was restored already
    /// connected (adopted directly as a live session — its `Peripheral` handle is available
    /// via ``Central/connectionState(of:)``), or a restored-*connecting* peripheral's manual
    /// re-connect succeeded. Every restored peripheral is routed and produces its own event —
    /// none are dropped or treated as extras.
    case restoredConnection(PeripheralIdentifier)

    /// Restoring a connection failed.
    ///
    /// Emitted with ``BLESwiftError/notConnected`` for a peripheral restored in the
    /// `disconnecting`/`disconnected` state (these are paths with no known way to recreate
    /// or test, so this behavior is unverified), with the manual re-connect's error for a
    /// restored-*connecting* peripheral (timeout:
    /// ``BLESwiftError/connectionTimedOut``), with ``BLESwiftError/startupBackgroundTaskExpired``
    /// if iOS's startup background time ran out mid-restoration, or with
    /// ``BLESwiftError/bluetoothUnavailable`` if the radio never reached powered-on.
    case failedToRestoreConnection(PeripheralIdentifier, error: Error)

    /// A characteristic value arrived with no active notification subscriber and no
    /// pending read — the restored peripheral is still notifying from a subscription that
    /// belonged to the previous app life.
    ///
    /// To keep receiving, subscribe normally via `Peripheral.notifications(for:policy:)`;
    /// to stop the peripheral notifying, subscribe and cancel (the last unsubscribe turns
    /// notifications off).
    case unhandledNotification(PeripheralIdentifier, CharacteristicIdentifier, Data?)
}

#else

/// Internal mirror of the iOS-only public `RestorationEvent` — see the dual-access note
/// in `RestorationConfiguration.swift`.
enum RestorationEvent: Sendable {
    case willRestore(RestoredState)
    case restoredConnection(PeripheralIdentifier)
    case failedToRestoreConnection(PeripheralIdentifier, error: Error)
    case unhandledNotification(PeripheralIdentifier, CharacteristicIdentifier, Data?)
}

#endif
