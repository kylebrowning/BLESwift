//
//  PeripheralRestorationConfiguration.swift
//  BLESwift
//

// NOTE — dual-access declaration: see the note in `RestorationConfiguration.swift`.
// Peripheral-role restoration is iOS-only in its *public API surface*, but its logic compiles
// on every platform so it stays testable under `swift test` on macOS (via `@testable import`).
// Swift cannot conditionally-compile just an access modifier, so this type is declared twice —
// a public iOS version and an internal mirror elsewhere. **Keep the two in sync.**

#if os(iOS)

/// Enables CoreBluetooth **peripheral-role state restoration**: relaunching the app in the
/// background to hand back the GATT database and advertising state that CoreBluetooth
/// preserved on the app's behalf while it was suspended or terminated by the system.
///
/// Pass one of these as ``Configuration/peripheralRestoration`` when creating a
/// ``PeripheralHost``; the `identifier` is registered with CoreBluetooth at manager creation
/// (`CBPeripheralManagerOptionRestoreIdentifierKey`), which is why manager creation happens
/// synchronously inside `PeripheralHost.init(configuration:)`. Restoration results arrive on
/// ``PeripheralHost/restorationEvents()``.
///
/// - Important: This identifier is the **peripheral manager's** restore identifier and must be
///   *distinct* from any ``RestorationConfiguration/identifier`` used for a ``Central`` —
///   CoreBluetooth requires a unique restore identifier per manager. Reusing one identifier
///   across both roles is a CoreBluetooth misuse, not a BLESwift constraint.
///
/// - Important: Restoration never fires after the user force-quits the app — that is a
///   CoreBluetooth platform rule. Create your `PeripheralHost` as early as possible in the
///   app's launch so the restore identifier is registered before CoreBluetooth gives up on the
///   relaunch.
public struct PeripheralRestorationConfiguration: Sendable {

    /// The restore identifier registered with CoreBluetooth
    /// (`CBPeripheralManagerOptionRestoreIdentifierKey`). Must be unique to this app, stable
    /// across launches, and **distinct** from any ``Central`` restore identifier.
    public let identifier: String

    /// Creates a `PeripheralRestorationConfiguration`.
    ///
    /// - Parameter identifier: The restore identifier registered with CoreBluetooth. Must be
    ///   unique to this app, stable across launches, and distinct from any ``Central`` restore
    ///   identifier.
    public init(identifier: String) {
        self.identifier = identifier
    }
}

#else

/// Internal mirror of the iOS-only public `PeripheralRestorationConfiguration` — see the
/// dual-access note at the top of this file. Kept compiled on every platform so peripheral-role
/// restoration logic (and its tests, which run under `swift test` on macOS via
/// `@testable import`) type-checks everywhere, without widening the non-iOS public API surface.
struct PeripheralRestorationConfiguration: Sendable {

    /// See the iOS declaration.
    let identifier: String

    /// See the iOS declaration.
    init(identifier: String) {
        self.identifier = identifier
    }
}

#endif
