//
//  Configuration.swift
//  BLESwift
//

import BLESwiftCore
import Logging

/// Configures a ``Central`` at creation time. Every start-time option is captured here up
/// front because `CBCentralManager` is created synchronously inside `Central.init`.
public struct Configuration: Sendable {

    /// Whether iOS should show a system alert when Bluetooth is turned off while the app
    /// is still running in the background.
    public let showPowerAlert: Bool

    /// The default ``WarningOptions`` applied to connections that don't specify their own.
    public let warningOptions: WarningOptions

    /// The `swift-log` logger `Central` writes every internal log line to, tagged with a
    /// `"category"` metadata key per subsystem area.
    public var logger: Logger

    #if os(iOS)
    /// Enables CoreBluetooth **background state restoration** (iOS only). `nil` (the
    /// default) disables restoration. Has no effect with `Central(adopting:)` — a restore
    /// identifier cannot be applied retroactively to an already-created manager.
    public var restoration: RestorationConfiguration?
    #else
    /// Internal on non-iOS platforms — see the dual-access note in
    /// `RestorationConfiguration.swift`.
    var restoration: RestorationConfiguration?
    #endif

    #if os(iOS)
    /// Enables CoreBluetooth **peripheral-role background state restoration** (iOS only).
    /// `nil` (the default) disables it. A separate setting from ``restoration``: CoreBluetooth
    /// requires a distinct restore identifier per manager.
    public var peripheralRestoration: PeripheralRestorationConfiguration?
    #else
    /// Internal on non-iOS platforms — see the dual-access note in
    /// `RestorationConfiguration.swift`.
    var peripheralRestoration: PeripheralRestorationConfiguration?
    #endif

    #if os(iOS)
    /// Creates a `Configuration`.
    ///
    /// - Parameter peripheralRestoration: Must use a restore identifier distinct from
    ///   `restoration`'s.
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
