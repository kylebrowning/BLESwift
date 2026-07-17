//
//  RestorationConfiguration.swift
//  BLESwift
//

// NOTE — dual-access declaration: background restoration is an iOS-only feature, and its
// *public API surface* is gated `#if os(iOS)` accordingly. The
// restoration *logic*, however, compiles on every platform so that it stays testable under
// `swift test` on macOS (SPM tests have no UIKit/UIApplication; tests drive the internal
// surface via `@testable import`). Swift cannot conditionally-compile just an access
// modifier, so each restoration type is declared twice — a public iOS version and an
// internal mirror for every other platform. **The two declarations must be kept in sync.**

#if os(iOS)

/// Enables CoreBluetooth **state restoration**: relaunching the app in the background to
/// hand back Bluetooth state (connected/connecting peripherals, an in-progress scan) that
/// CoreBluetooth preserved on the app's behalf while the app was suspended or terminated
/// by the system.
///
/// Pass one of these as ``Configuration/restoration`` when creating a ``Central``; the
/// `identifier` is registered with CoreBluetooth at manager creation
/// (`CBCentralManagerOptionRestoreIdentifierKey`), which is why manager creation happens
/// synchronously inside `Central.init`. Restoration results arrive on
/// ``Central/restorationEvents()``.
///
/// No `launchOptions` are needed:
/// CoreBluetooth re-delivers the full restored state via its `willRestoreState` delegate
/// callback, which BLESwift captures and replays — see ``RestorationEvent/willRestore(_:)``.
///
/// - Important: Restoration never fires after the user force-quits the app — that is a
///   CoreBluetooth platform rule, not a BLESwift limitation. Create your `Central` as early as
///   possible in the app's launch (e.g. `App.init` or
///   `application(_:didFinishLaunchingWithOptions:)`) so the restore identifier is
///   registered before CoreBluetooth gives up on the relaunch.
public struct RestorationConfiguration: Sendable {

    /// The restore identifier registered with CoreBluetooth
    /// (`CBCentralManagerOptionRestoreIdentifierKey`). Must be unique to this app and
    /// stable across launches.
    public let identifier: String

    /// How long the manual re-connect issued for a restored-*connecting* peripheral may
    /// take before failing with ``RestorationEvent/failedToRestoreConnection(_:error:)``.
    ///
    /// CoreBluetooth never completes a restored-connecting attempt on its own (verified —
    /// the manual `connect` uses a hardcoded 15-second default; BLESwift makes it
    /// configurable).
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
/// note at the top of this file. Kept compiled on every platform so restoration logic (and
/// its tests, which run under `swift test` on macOS via `@testable import`) type-checks
/// everywhere, without adding restoration to the non-iOS public API surface.
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
