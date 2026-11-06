//
//  Configuration.swift
//  BLESwift
//

import BLESwiftCore
import Logging

/// Configures a ``Central`` when you create it. `Central.init` creates the `CBCentralManager`
/// synchronously, so this type holds every start-time option.
public struct Configuration: Sendable {

    /// Whether iOS shows a system alert when Bluetooth is off and the app is still in the
    /// background.
    public let showPowerAlert: Bool

    /// The default ``WarningOptions`` for connections that do not specify their own.
    public let warningOptions: WarningOptions

    /// The `swift-log` logger for `Central`'s internal log lines. Each line has a `"category"`
    /// metadata key for its subsystem.
    public var logger: Logger

    #if os(iOS)
    /// Enables CoreBluetooth **background state restoration** (iOS only). The default `nil`
    /// disables restoration. It has no effect with `Central(adopting:)`, because a manager
    /// that exists cannot get a restore identifier.
    public var restoration: RestorationConfiguration?
    #else
    /// Internal on non-iOS platforms. See the dual-access note in
    /// `RestorationConfiguration.swift`.
    var restoration: RestorationConfiguration?
    #endif

    #if os(iOS)
    /// Enables CoreBluetooth **peripheral-role background state restoration** (iOS only). The
    /// default `nil` disables it. This setting is separate from ``restoration``, and each
    /// manager needs a different restore identifier.
    public var peripheralRestoration: PeripheralRestorationConfiguration?
    #else
    /// Internal on non-iOS platforms. See the dual-access note in
    /// `RestorationConfiguration.swift`.
    var peripheralRestoration: PeripheralRestorationConfiguration?
    #endif

    /// The clock for every timer in `Central`:
    ///
    /// - `connect(timeout:)` and the other operation timeouts
    /// - the scan timeout and the loss timer
    /// - the reconnect backoff
    ///
    /// The default is `ContinuousClock()`. This property exists for tests. A test passes the
    /// `ManualClock` of `BLESwiftTestSupport` and advances it to, or just before, a deadline
    /// in a deterministic way. Production code does not change it.
    public var clock: any Clock<Duration>

    #if os(iOS)
    /// Creates a `Configuration`.
    ///
    /// - Parameter peripheralRestoration: Must use a restore identifier that differs from
    ///   the identifier of `restoration`.
    public init(
        showPowerAlert: Bool = false,
        warningOptions: WarningOptions = .default,
        logger: Logger = Logger(label: "BLESwift"),
        restoration: RestorationConfiguration? = nil,
        peripheralRestoration: PeripheralRestorationConfiguration? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.showPowerAlert = showPowerAlert
        self.warningOptions = warningOptions
        self.logger = logger
        self.restoration = restoration
        self.peripheralRestoration = peripheralRestoration
        self.clock = clock
    }
    #else
    /// Creates a `Configuration`.
    public init(
        showPowerAlert: Bool = false,
        warningOptions: WarningOptions = .default,
        logger: Logger = Logger(label: "BLESwift"),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.showPowerAlert = showPowerAlert
        self.warningOptions = warningOptions
        self.logger = logger
        self.restoration = nil
        self.peripheralRestoration = nil
        self.clock = clock
    }
    #endif
}
