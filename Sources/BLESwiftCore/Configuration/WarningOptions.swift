//
//  WarningOptions.swift
//  BLESwiftCore
//

/// Controls whether iOS shows a system alert when the app is suspended and a connection event
/// occurs.
///
/// There are three independent alert toggles, one for each of these keys:
/// - `CBConnectPeripheralOptionNotifyOnConnectionKey`
/// - `CBConnectPeripheralOptionNotifyOnDisconnectionKey`
/// - `CBConnectPeripheralOptionNotifyOnNotificationKey`
public struct WarningOptions: Sendable {

    /// Whether iOS shows a system alert when the suspended app connects to a peripheral.
    public let notifyOnConnection: Bool

    /// Whether iOS shows a system alert when the suspended app disconnects from a peripheral.
    public let notifyOnDisconnection: Bool

    /// Whether iOS shows a system alert when the suspended app receives a notification from a
    /// peripheral.
    public let notifyOnNotification: Bool

    /// Creates a `WarningOptions` that sets whether iOS shows a system alert for each
    /// connection-related event while the app is suspended.
    public init(notifyOnConnection: Bool, notifyOnDisconnection: Bool, notifyOnNotification: Bool) {
        self.notifyOnConnection = notifyOnConnection
        self.notifyOnDisconnection = notifyOnDisconnection
        self.notifyOnNotification = notifyOnNotification
    }

    /// The defaults: all alerts are off, so the user gets no system alerts for background changes.
    public static let `default` = WarningOptions(
        notifyOnConnection: false,
        notifyOnDisconnection: false,
        notifyOnNotification: false
    )
}
