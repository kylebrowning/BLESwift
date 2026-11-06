//
//  PeripheralRestorationEvent.swift
//  BLESwift
//

// NOTE: This is a dual-access declaration. See the note in `RestorationConfiguration.swift`.
// It is public on iOS and an internal mirror on other platforms. **Keep the two in sync.**

import BLESwiftCore

#if os(iOS)

/// A peripheral-role background-restoration event. ``PeripheralHost/restorationEvents()``
/// publishes it on a **buffered, replayed** stream (see ``RestorationEvent``), so the state
/// that the system restores during launch is not lost.
///
/// There is a single event. CoreBluetooth itself restores the preserved GATT database and
/// resumes advertising.
public enum PeripheralRestorationEvent: Sendable {

    /// CoreBluetooth restored peripheral-role state. The event carries the services that it
    /// published again and the advertisement that it resumed, if any.
    case willRestore(RestoredPeripheralState)
}

#else

/// Internal mirror of the public `PeripheralRestorationEvent`, which is iOS-only. See the
/// dual-access note in `RestorationConfiguration.swift`.
enum PeripheralRestorationEvent: Sendable {
    case willRestore(RestoredPeripheralState)
}

#endif
