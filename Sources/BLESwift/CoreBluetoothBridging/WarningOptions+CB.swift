//
//  WarningOptions+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension WarningOptions {

    /// This options set expressed as the `[String: Bool]` dictionary CoreBluetooth's
    /// `connect(_:options:)` expects.
    var cbConnectOptions: [String: Bool] {
        [
            CBConnectPeripheralOptionNotifyOnConnectionKey: notifyOnConnection,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: notifyOnDisconnection,
            CBConnectPeripheralOptionNotifyOnNotificationKey: notifyOnNotification
        ]
    }
}
