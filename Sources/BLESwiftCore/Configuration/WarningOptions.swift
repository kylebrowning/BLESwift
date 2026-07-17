//
//  WarningOptions.swift
//  BLESwiftCore
//

/// Controls whether iOS shows a system alert when the app is suspended and a connection
/// event occurs.
///
/// Three independent alert toggles, each corresponding to one of
/// `CBConnectPeripheralOptionNotifyOnConnectionKey`,
/// `CBConnectPeripheralOptionNotifyOnDisconnectionKey`, and
/// `CBConnectPeripheralOptionNotifyOnNotificationKey`.
public struct WarningOptions: Sendable {

    /// Whether iOS should show a system alert when the suspended app connects to a
    /// peripheral.
    public let notifyOnConnection: Bool

    /// Whether iOS should show a system alert when the suspended app disconnects from a
    /// peripheral.
    public let notifyOnDisconnection: Bool

    /// Whether iOS should show a system alert when the suspended app receives a
    /// notification from a peripheral.
    public let notifyOnNotification: Bool

    /// Creates a `WarningOptions`, specifying whether iOS can display a system alert when
    /// certain connection-related events occur while the app is suspended.
    ///
    /// - Parameters:
    ///   - notifyOnConnection: Whether iOS should show a system alert when the suspended
    ///     app connects to a peripheral.
    ///   - notifyOnDisconnection: Whether iOS should show a system alert when the
    ///     suspended app disconnects from a peripheral.
    ///   - notifyOnNotification: Whether iOS should show a system alert when the suspended
    ///     app receives a notification from a peripheral.
    public init(notifyOnConnection: Bool, notifyOnDisconnection: Bool, notifyOnNotification: Bool) {
        self.notifyOnConnection = notifyOnConnection
        self.notifyOnDisconnection = notifyOnDisconnection
        self.notifyOnNotification = notifyOnNotification
    }

    /// Sensible defaults: all alerts off, in favor of not aggressively notifying the user
    /// of changes while the app is backgrounded.
    public static let `default` = WarningOptions(
        notifyOnConnection: false,
        notifyOnDisconnection: false,
        notifyOnNotification: false
    )
}
