//
//  GATTCompatibility.swift
//  BLESwiftCore
//

/// Per-connection accommodations for peripherals that report their GATT database incorrectly. Cheap
/// modules often notify on characteristics that do not advertise `.notify`. Some modules work only
/// with unfiltered service discovery.
///
/// Pass this to `Central.connect(_:timeout:reconnect:warningOptions:compatibility:)`. Each
/// connection has its own value, so the accommodations for one non-compliant peripheral never
/// affect another peripheral on the same `Central`. Keep ``strict`` (the default) for compliant
/// hardware.
public struct GATTCompatibility: Sendable, Equatable {

    /// How BLESwift discovers services on first use.
    public enum DiscoveryMode: Sendable, Equatable {
        /// Discover only the requested service (the default).
        case filtered
        /// Discover every service (`discoverServices(nil)`) once for each connection, and cache the
        /// result. Use this for modules that fill their GATT table only under unfiltered discovery.
        case all
    }

    /// Skip the `.notify` and `.indicate` property check before subscribing to notifications. If
    /// the peripheral cannot notify, CoreBluetooth reports the error.
    public var allowNotifyWithoutProperty: Bool

    /// Skip the `.read` property check before reading a characteristic.
    public var allowReadWithoutProperty: Bool

    /// Skip the `.write` and `.writeWithoutResponse` property check before writing a
    /// characteristic.
    public var allowWriteWithoutProperty: Bool

    /// How BLESwift discovers services. See ``DiscoveryMode``.
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

    /// Enforce every property. Discover only the requested services. This is the default.
    public static let strict = GATTCompatibility()

    /// Bypass every property check and discover all services. Use this for modules that are known
    /// to be non-compliant.
    public static let lenient = GATTCompatibility(
        allowNotifyWithoutProperty: true,
        allowReadWithoutProperty: true,
        allowWriteWithoutProperty: true,
        discovery: .all
    )
}
