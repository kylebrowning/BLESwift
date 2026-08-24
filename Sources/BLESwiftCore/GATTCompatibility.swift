//
//  GATTCompatibility.swift
//  BLESwiftCore
//

/// Per-connection accommodations for peripherals that misreport their GATT database —
/// cheap modules routinely notify on characteristics that do not advertise `.notify`, or
/// only behave under unfiltered service discovery.
///
/// Passed to `Central.connect(_:timeout:reconnect:warningOptions:compatibility:)`; each
/// connection carries its own value, so one non-compliant peripheral's accommodations
/// never affect another peripheral on the same `Central`. Keep ``strict`` (the default)
/// for compliant hardware.
public struct GATTCompatibility: Sendable, Equatable {

    /// How services are discovered on first use.
    public enum DiscoveryMode: Sendable, Equatable {
        /// Discover only the requested service (the default).
        case filtered
        /// Discover every service (`discoverServices(nil)`), once per connection, cached.
        /// For modules that only populate their GATT table under unfiltered discovery.
        case all
    }

    /// Skip the `.notify`/`.indicate` property check before subscribing to notifications,
    /// letting CoreBluetooth report the error if the peripheral genuinely cannot notify.
    public var allowNotifyWithoutProperty: Bool

    /// Skip the `.read` property check before reading a characteristic.
    public var allowReadWithoutProperty: Bool

    /// Skip the `.write`/`.writeWithoutResponse` property check before writing a
    /// characteristic.
    public var allowWriteWithoutProperty: Bool

    /// How services are discovered — see ``DiscoveryMode``.
    public var discovery: DiscoveryMode

    /// Creates a `GATTCompatibility`. Every parameter defaults to the strict behavior.
    public init(
        allowNotifyWithoutProperty: Bool = false,
        allowReadWithoutProperty: Bool = false,
        allowWriteWithoutProperty: Bool = false,
        discovery: DiscoveryMode = .filtered
    ) {
        self.allowNotifyWithoutProperty = allowNotifyWithoutProperty
        self.allowReadWithoutProperty = allowReadWithoutProperty
        self.allowWriteWithoutProperty = allowWriteWithoutProperty
        self.discovery = discovery
    }

    /// Enforce every property, discover only requested services. The default.
    public static let strict = GATTCompatibility()

    /// Bypass every property check and discover all services. For known-noncompliant modules.
    public static let lenient = GATTCompatibility(
        allowNotifyWithoutProperty: true,
        allowReadWithoutProperty: true,
        allowWriteWithoutProperty: true,
        discovery: .all
    )
}
