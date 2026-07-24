//
//  PeripheralRestorationConfiguration.swift
//  BLESwift
//

// NOTE — dual-access declaration: see the note in `RestorationConfiguration.swift`.

#if os(iOS)

/// Enables CoreBluetooth **peripheral-role state restoration**: relaunching the app in the
/// background to hand back the GATT database and advertising state CoreBluetooth preserved.
///
/// Pass one of these as ``Configuration/peripheralRestoration`` when creating a
/// ``PeripheralHost``; the `identifier` is registered at manager creation, which is why
/// that happens synchronously inside `PeripheralHost.init`.
///
/// - Important: This identifier must be *distinct* from any ``RestorationConfiguration``
///   used for a ``Central`` — CoreBluetooth requires a unique restore identifier per manager.
///
/// - Important: Restoration never fires after the user force-quits the app. Create your
///   `PeripheralHost` as early as possible in the app's launch.
public struct PeripheralRestorationConfiguration: Sendable {

    /// The restore identifier registered with CoreBluetooth. Must be unique to this app,
    /// stable across launches, and **distinct** from any ``Central`` restore identifier.
    public let identifier: String

    /// Creates a `PeripheralRestorationConfiguration`.
    public init(identifier: String) {
        self.identifier = identifier
    }
}

#else

/// Internal mirror of the iOS-only public `PeripheralRestorationConfiguration` — see the
/// dual-access note at the top of this file.
struct PeripheralRestorationConfiguration: Sendable {

    /// See the iOS declaration.
    let identifier: String

    /// See the iOS declaration.
    init(identifier: String) {
        self.identifier = identifier
    }
}

#endif
