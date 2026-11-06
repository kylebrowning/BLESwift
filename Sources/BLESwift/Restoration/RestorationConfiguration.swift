//
//  RestorationConfiguration.swift
//  BLESwift
//

// NOTE: This is a dual-access declaration. The public restoration API exists only on iOS, but
// the logic compiles on every platform so that `swift test` on macOS can test it through
// `@testable import`. Swift cannot make an access modifier conditional. So each restoration
// type has two declarations: a public one for iOS and an internal mirror for other platforms.
// Keep the two in sync.

#if os(iOS)

/// Enables CoreBluetooth **state restoration**. The system relaunches the app in the
/// background and hands back the Bluetooth state that CoreBluetooth preserved while the app
/// was suspended or terminated.
///
/// Pass one of these as ``Configuration/restoration`` when you create a ``Central``.
/// `Central.init` registers the `identifier` synchronously. The restoration results arrive on
/// ``Central/restorationEvents()``.
///
/// - Important: Restoration does not happen after the user force-quits the app. This is a
///   CoreBluetooth platform rule. Create your `Central` as early as possible at launch.
public struct RestorationConfiguration: Sendable {

    /// The restore identifier to register with CoreBluetooth. It must be unique to this app
    /// and stable across launches.
    public let identifier: String

    /// How long the manual reconnect of a restored-*connecting* peripheral can take before it
    /// fails with ``RestorationEvent/failedToRestoreConnection(_:error:)``. CoreBluetooth does
    /// not complete a restored-connecting attempt on its own.
    public let connectingTimeout: Duration

    /// Creates a `RestorationConfiguration`.
    ///
    /// - Parameters:
    ///   - identifier: The restore identifier to register with CoreBluetooth. It must be
    ///     unique to this app and stable across launches.
    ///   - connectingTimeout: The timeout for the manual reconnect of a restored-*connecting*
    ///     peripheral. The default is 15 seconds.
    public init(identifier: String, connectingTimeout: Duration = .seconds(15)) {
        self.identifier = identifier
        self.connectingTimeout = connectingTimeout
    }
}

#else

/// Internal mirror of the public `RestorationConfiguration`, which is iOS-only. See the
/// dual-access note at the top of this file.
struct RestorationConfiguration: Sendable {

    /// See the iOS declaration.
    let identifier: String

    /// See the iOS declaration.
    let connectingTimeout: Duration

    /// See the iOS declaration.
    init(identifier: String, connectingTimeout: Duration = .seconds(15)) {
        self.identifier = identifier
        self.connectingTimeout = connectingTimeout
    }
}

#endif
