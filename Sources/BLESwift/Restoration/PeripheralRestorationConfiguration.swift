//
//  PeripheralRestorationConfiguration.swift
//  BLESwift
//

// NOTE: This is a dual-access declaration. See the note in `RestorationConfiguration.swift`.

#if os(iOS)

/// Enables CoreBluetooth **peripheral-role state restoration**. The system relaunches the app
/// in the background and hands back the GATT database and advertising state that CoreBluetooth
/// preserved.
///
/// Pass one of these as ``Configuration/peripheralRestoration`` when you create a
/// ``PeripheralHost``. `PeripheralHost.init` registers the `identifier` synchronously.
///
/// - Important: This identifier must be *different* from the identifier of any
///   ``RestorationConfiguration`` that a ``Central`` uses. CoreBluetooth requires a unique
///   restore identifier for each manager.
///
/// - Important: Restoration does not happen after the user force-quits the app. Create your
///   `PeripheralHost` as early as possible at launch.
public struct PeripheralRestorationConfiguration: Sendable {

    /// The restore identifier to register with CoreBluetooth. It must be unique to this app,
    /// stable across launches, and **different** from any ``Central`` restore identifier.
    public let identifier: String

    /// Creates a `PeripheralRestorationConfiguration`.
    public init(identifier: String) {
        self.identifier = identifier
    }
}

#else

/// Internal mirror of the public `PeripheralRestorationConfiguration`, which is iOS-only. See
/// the dual-access note at the top of this file.
struct PeripheralRestorationConfiguration: Sendable {

    /// See the iOS declaration.
    let identifier: String

    /// See the iOS declaration.
    init(identifier: String) {
        self.identifier = identifier
    }
}

#endif
