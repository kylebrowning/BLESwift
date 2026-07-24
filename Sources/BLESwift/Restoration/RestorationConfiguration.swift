//
//  RestorationConfiguration.swift
//  BLESwift
//

// NOTE — dual-access declaration: restoration's public API surface is gated `#if os(iOS)`,
// but the logic compiles on every platform so it stays testable under `swift test` on
// macOS (via `@testable import`). Swift can't conditionally-compile just an access
// modifier, so each restoration type is declared twice — public iOS version, internal
// mirror elsewhere. The two declarations must be kept in sync.

#if os(iOS)

/// Enables CoreBluetooth **state restoration**: relaunching the app in the background to
/// hand back Bluetooth state CoreBluetooth preserved while the app was suspended or
/// terminated.
///
/// Pass one of these as ``Configuration/restoration`` when creating a ``Central``; the
/// `identifier` is registered at manager creation, which is why that happens synchronously
/// inside `Central.init`. Restoration results arrive on ``Central/restorationEvents()``.
///
/// - Important: Restoration never fires after the user force-quits the app — a
///   CoreBluetooth platform rule, not a BLESwift limitation. Create your `Central` as early
///   as possible in the app's launch so the restore identifier is registered before
///   CoreBluetooth gives up on the relaunch.
public struct RestorationConfiguration: Sendable {

    /// The restore identifier registered with CoreBluetooth. Must be unique to this app and
    /// stable across launches.
    public let identifier: String

    /// How long the manual re-connect issued for a restored-*connecting* peripheral may
    /// take before failing with ``RestorationEvent/failedToRestoreConnection(_:error:)``.
    /// CoreBluetooth never completes a restored-connecting attempt on its own.
    public let connectingTimeout: Duration

    /// Creates a `RestorationConfiguration`.
    ///
    /// - Parameters:
    ///   - identifier: The restore identifier registered with CoreBluetooth. Must be
    ///     unique to this app and stable across launches.
    ///   - connectingTimeout: The timeout for the manual re-connect issued for a
    ///     restored-*connecting* peripheral. Defaults to 15 seconds.
    public init(identifier: String, connectingTimeout: Duration = .seconds(15)) {
        self.identifier = identifier
        self.connectingTimeout = connectingTimeout
    }
}

#else

/// Internal mirror of the iOS-only public `RestorationConfiguration` — see the dual-access
/// note at the top of this file.
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
