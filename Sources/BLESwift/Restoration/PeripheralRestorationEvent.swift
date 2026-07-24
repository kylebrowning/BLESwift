//
//  PeripheralRestorationEvent.swift
//  BLESwift
//

// NOTE — dual-access declaration: see the note in `RestorationConfiguration.swift`.
// Public on iOS, internal mirror elsewhere. **Keep the two in sync.**

import BLESwiftCore

#if os(iOS)

/// A peripheral-role background-restoration event, published by
/// ``PeripheralHost/restorationEvents()``. Surfaced as a **buffered, replayed** event stream
/// (see ``RestorationEvent``), so state restored during launch is never lost.
///
/// A single event, because CoreBluetooth itself re-establishes the preserved GATT database
/// and resumes advertising on the app's behalf — there is no connection to re-drive.
public enum PeripheralRestorationEvent: Sendable {

    /// CoreBluetooth restored preserved peripheral-role state. Carries the services
    /// CoreBluetooth re-published and the advertisement it resumed (if any).
    case willRestore(RestoredPeripheralState)
}

#else

/// Internal mirror of the iOS-only public `PeripheralRestorationEvent` — see the dual-access
/// note in `RestorationConfiguration.swift`.
enum PeripheralRestorationEvent: Sendable {
    case willRestore(RestoredPeripheralState)
}

#endif
