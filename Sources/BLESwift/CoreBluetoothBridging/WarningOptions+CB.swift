//
//  WarningOptions+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

extension WarningOptions {

    /// These options as the `[String: Bool]` dictionary that CoreBluetooth's
    /// `connect(_:options:)` expects.
    var cbConnectOptions: [String: Bool] {
        [
            CBConnectPeripheralOptionNotifyOnConnectionKey: notifyOnConnection,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: notifyOnDisconnection,
            CBConnectPeripheralOptionNotifyOnNotificationKey: notifyOnNotification
        ]
    }
}
