//
//  Configuration.swift
//  BLESwift
//

import BLESwiftCore
import Logging

/// Configures a ``Central`` at creation time.
///
/// BLESwift's `CBCentralManager` is created synchronously inside
/// `Central.init(configuration:)` (required so background restoration can register its
/// restore identifier at manager creation), so every start-time option is captured here up
/// front.
public struct Configuration: Sendable {

    /// Whether iOS should show a system alert when Bluetooth is turned off while the app
    /// is still running in the background. Passed to CoreBluetooth via
    /// `CBCentralManagerOptionShowPowerAlertKey`.
    public let showPowerAlert: Bool

    /// The default ``WarningOptions`` applied to connections that don't specify their own.
    public let warningOptions: WarningOptions

    /// The `swift-log` logger `Central` writes every internal log line to, tagged with a
    /// `"category"` metadata key per subsystem area (e.g. `"scan"`, `"connection"`,
    /// `"gatt"`, `"restore"`). Install a custom `LogHandler` (via `LoggingSystem.bootstrap`,
    /// or by constructing this `Logger` with one directly) to observe BLESwift's log
    /// output.
    public var logger: Logger

    #if os(iOS)
    /// Enables CoreBluetooth **background state restoration** (iOS only), registering
    /// ``RestorationConfiguration/identifier`` with CoreBluetooth
    /// (`CBCentralManagerOptionRestoreIdentifierKey`) when the `CBCentralManager` is
    /// created inside `Central.init(configuration:)`. `nil` (the default) disables
    /// restoration. Restoration results arrive on ``Central/restorationEvents()``.
    ///
    /// Has no effect with `Central(adopting:)` — a restore identifier cannot be applied
    /// retroactively to an already-created manager.
    public var restoration: RestorationConfiguration?
    #else
    /// Internal on non-iOS platforms: restoration is an iOS-only feature, but its logic is
    /// compiled everywhere for test parity — see the dual-access note in
    /// `RestorationConfiguration.swift`. Always `nil` in production on these platforms
    /// (only tests, via `@testable`, ever set it).
    var restoration: RestorationConfiguration?
    #endif

    #if os(iOS)
    /// Enables CoreBluetooth **peripheral-role background state restoration** (iOS only),
    /// registering ``PeripheralRestorationConfiguration/identifier`` with CoreBluetooth
    /// (`CBPeripheralManagerOptionRestoreIdentifierKey`) when the `CBPeripheralManager` is
    /// created inside `PeripheralHost.init(configuration:)`. `nil` (the default) disables
    /// peripheral-role restoration. Restoration results arrive on
    /// ``PeripheralHost/restorationEvents()``.
    ///
    /// This is a **separate** setting from ``restoration`` (which governs the central role):
    /// CoreBluetooth requires a distinct restore identifier per manager, so a
    /// ``Central`` and a ``PeripheralHost`` in the same app must use different identifiers.
    public var peripheralRestoration: PeripheralRestorationConfiguration?
    #else
    /// Internal on non-iOS platforms: peripheral-role restoration is an iOS-only feature, but
    /// its logic is compiled everywhere for test parity — see the dual-access note in
    /// `RestorationConfiguration.swift`. Always `nil` in production on these platforms (only
    /// tests, via `@testable`, ever set it).
    var peripheralRestoration: PeripheralRestorationConfiguration?
    #endif

    #if os(iOS)
    /// Creates a `Configuration`.
    ///
    /// - Parameters:
    ///   - showPowerAlert: Whether iOS should show a system alert when Bluetooth is turned
    ///     off while the app is still running in the background. Defaults to `false`.
    ///   - warningOptions: The default ``WarningOptions`` applied to connections that
    ///     don't specify their own. Defaults to ``WarningOptions/default``.
    ///   - logger: The `swift-log` logger `Central` writes to. Defaults to a
    ///     `Logger(label: "BLESwift")` using whatever `LogHandler` the app has bootstrapped
    ///     (or the default console handler, if none).
    ///   - restoration: Enables CoreBluetooth background state restoration for the *central*
    ///     role — see ``restoration``. Defaults to `nil` (disabled).
    ///   - peripheralRestoration: Enables CoreBluetooth background state restoration for the
    ///     *peripheral* role — see ``peripheralRestoration``. Must use a restore identifier
    ///     distinct from `restoration`'s. Defaults to `nil` (disabled).
    public init(
        showPowerAlert: Bool = false,
        warningOptions: WarningOptions = .default,
        logger: Logger = Logger(label: "BLESwift"),
        restoration: RestorationConfiguration? = nil,
        peripheralRestoration: PeripheralRestorationConfiguration? = nil
    ) {
        self.showPowerAlert = showPowerAlert
        self.warningOptions = warningOptions
        self.logger = logger
        self.restoration = restoration
        self.peripheralRestoration = peripheralRestoration
    }
    #else
    /// Creates a `Configuration`.
    ///
    /// - Parameters:
    ///   - showPowerAlert: Whether iOS should show a system alert when Bluetooth is turned
    ///     off while the app is still running in the background. Defaults to `false`.
    ///   - warningOptions: The default ``WarningOptions`` applied to connections that
    ///     don't specify their own. Defaults to ``WarningOptions/default``.
    ///   - logger: The `swift-log` logger `Central` writes to. Defaults to a
    ///     `Logger(label: "BLESwift")` using whatever `LogHandler` the app has bootstrapped
    ///     (or the default console handler, if none).
    public init(
        showPowerAlert: Bool = false,
        warningOptions: WarningOptions = .default,
        logger: Logger = Logger(label: "BLESwift")
    ) {
        self.showPowerAlert = showPowerAlert
        self.warningOptions = warningOptions
        self.logger = logger
        self.restoration = nil
        self.peripheralRestoration = nil
    }
    #endif
}
