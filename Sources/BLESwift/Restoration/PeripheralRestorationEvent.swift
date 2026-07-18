//
//  PeripheralRestorationEvent.swift
//  BLESwift
//

// NOTE — dual-access declaration: see the note in `RestorationConfiguration.swift`.
// Public on iOS, internal mirror elsewhere. **Keep the two in sync.**

import BLESwiftCore

#if os(iOS)

/// A peripheral-role background-restoration event, published by
/// ``PeripheralHost/restorationEvents()``.
///
/// Surfaced as a **buffered, replayed** event stream, mirroring the central-side
/// ``RestorationEvent``: every event is buffered from `PeripheralHost`'s creation and replayed,
/// in order, to the first ``PeripheralHost/restorationEvents()`` consumer — so state restored
/// during launch (which typically happens before any consumer task has started) is never lost.
///
/// Peripheral-role restoration has a single event because CoreBluetooth itself re-establishes
/// the preserved GATT database and resumes the preserved advertisement on the app's behalf —
/// unlike the central role, there is no connection to re-drive, so there is no
/// success/failure follow-up to report.
public enum PeripheralRestorationEvent: Sendable {

    /// CoreBluetooth restored preserved peripheral-role state — the eager, `Sendable` capture
    /// of its `peripheralManager(_:willRestoreState:)` delegate callback. Carries the services
    /// CoreBluetooth re-published and the advertisement it resumed (if any). See
    /// ``RestoredPeripheralState``.
    case willRestore(RestoredPeripheralState)
}

#else

/// Internal mirror of the iOS-only public `PeripheralRestorationEvent` — see the dual-access
/// note in `RestorationConfiguration.swift`.
enum PeripheralRestorationEvent: Sendable {
    case willRestore(RestoredPeripheralState)
}

#endif
