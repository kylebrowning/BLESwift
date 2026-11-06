//
//  BLESwiftError.swift
//  BLESwiftCore
//

import Foundation

/// Errors that BLESwift throws. They cover connection, GATT, and scanning failures.
/// ``duplicateConnect(_:)`` fires only for a second `connect` to the same peripheral that is
/// already tracked. A `connect` to a *different* peripheral never conflicts.
public enum BLESwiftError: Error, Sendable, Equatable {

    // MARK: - Core Cases

    /// Bluetooth is turned off or is not available.
    case bluetoothUnavailable
    /// `connect` targeted a peripheral that is already tracked: it is connecting, connected, or
    /// disconnecting.
    case duplicateConnect(PeripheralIdentifier)
    /// A second disconnection request arrived for a peripheral that is already disconnecting.
    /// BLESwift does not support this.
    case multipleDisconnectNotSupported
    /// A connection request timed out.
    case connectionTimedOut
    /// BLESwift is not connected to a peripheral.
    case notConnected
    /// A Bluetooth service was not found.
    case missingService(ServiceIdentifier)
    /// A Bluetooth characteristic was not found.
    case missingCharacteristic(CharacteristicIdentifier)
    /// A Bluetooth characteristic descriptor was not found.
    case missingDescriptor(DescriptorIdentifier)
    /// A Bluetooth operation was cancelled (for example, with `cancelAllOperations`).
    case cancelled
    /// The caller called `disconnect()` explicitly.
    case explicitDisconnect
    /// The peripheral disconnected unexpectedly.
    case unexpectedDisconnect
    /// An attempt to listen on a characteristic timed out.
    case listenTimedOut
    /// An attempt to read a characteristic failed.
    case readFailed
    /// An attempt to write a characteristic failed.
    case writeFailed
    /// A read of a characteristic returned no data, which was not expected.
    case missingData
    /// Extracting a range of `Data` failed because the bounds or the length were not valid.
    case dataOutOfBounds(start: Int, length: Int, count: Int)
    /// CoreBluetooth returned a cached peripheral that was not expected.
    case unexpectedPeripheral(PeripheralIdentifier)
    /// iOS does not continue a scan in the background if `allowDuplicates` is `true`.
    case allowDuplicatesInBackgroundNotSupported
    /// iOS does not continue a scan in the background if the scan has no service identifiers.
    case missingServiceIdentifiersInBackground
    /// BLESwift stopped.
    case stopped
    /// BLESwift cannot do some actions while background restoration is in progress.
    case backgroundRestorationInProgress
    /// The startup background task expired during state restoration.
    case startupBackgroundTaskExpired
    /// An operation received more data than it expected (for example, `writeAndAssemble`).
    case tooMuchData(expected: Int, received: Data)

    // MARK: - New in BLESwift

    /// A BLESwift operation timed out (for example, a GATT read, write, or RSSI operation). It
    /// differs from ``connectionTimedOut`` and ``listenTimedOut``.
    case timedOut
    /// Task cancellation cancelled a BLESwift operation. It is equivalent to a caught
    /// `CancellationError`.
    case operationCancelled
    /// Data received over Bluetooth could not be decoded with the expected string encoding.
    case invalidStringEncoding
    /// A scan started while another scan is active. BLESwift does not support this.
    case alreadyScanning
    /// A read targeted a characteristic that is now notifying. CoreBluetooth cannot tell a read
    /// completion from a notification delivery.
    case readConflictsWithNotification
    /// The caller passed an invalid argument to a BLESwift API. The payload says which argument and
    /// why (for example, a flush timeout that is not positive). BLESwift throws this error and does
    /// not trap.
    case invalidArgument(String)
    /// An L2CAP channel open completed with neither a channel nor an error, a malformed
    /// `peripheral(_:didOpen:error:)` callback.
    case l2capOpenFailed
    /// An operation on an L2CAP channel failed because the channel is closed, by a disconnect, an
    /// explicit `close()`, or a transport error.
    case l2capChannelClosed
    /// A GATT operation targeted a characteristic whose advertised `CharacteristicProperties` lack
    /// the required capability, such as notifying a characteristic without `.notify` or
    /// `.indicate`. If the peripheral reports its properties incorrectly, use `GATTCompatibility`
    /// to bypass this check for one connection.
    case unsupportedCharacteristicOperation(CharacteristicIdentifier, required: CharacteristicProperties)
}

extension BLESwiftError: LocalizedError {
    /// A human-readable description of the error, suitable for logs or display.
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth unavailable"
        case let .duplicateConnect(peripheral):
            return "Already connecting, connected, or disconnecting: \(peripheral)"
        case .multipleDisconnectNotSupported:
            return "Multiple disconnect is not supported"
        case .connectionTimedOut:
            return "Connection timed out"
        case .notConnected:
            return "Not connected to a peripheral"
        case let .missingService(service):
            return "Service not found: \(service.uuidString)"
        case let .missingCharacteristic(characteristic):
            return "Characteristic not found: \(characteristic.uuidString)"
        case let .missingDescriptor(descriptor):
            return "Descriptor not found: \(descriptor.uuidString)"
        case .cancelled:
            return "Cancelled"
        case .explicitDisconnect:
            return "Explicit disconnect"
        case .unexpectedDisconnect:
            return "Unexpected disconnect"
        case .listenTimedOut:
            return "Listen timed out"
        case .readFailed:
            return "Read failed"
        case .writeFailed:
            return "Write failed"
        case .missingData:
            return "No data from peripheral"
        case let .dataOutOfBounds(start, length, count):
            return "Cannot extract data with a size of \(count) using start: \(start), length: \(length)"
        case let .unexpectedPeripheral(peripheral):
            return "Unexpected peripheral: \(peripheral.uuid)"
        case .allowDuplicatesInBackgroundNotSupported:
            return "Scanning with allow duplicates while in the background is not supported"
        case .missingServiceIdentifiersInBackground:
            return "Scanning without specifying any service identifiers while in the background is not supported"
        case .stopped:
            return "BLESwift stopped"
        case .backgroundRestorationInProgress:
            return "Background restoration is in progress"
        case .startupBackgroundTaskExpired:
            return "Startup background task expired during state restoration"
        case let .tooMuchData(expected, received):
            return "More data than expected was received from the device (expected: \(expected), got: \(received.count))"
        case .timedOut:
            return "Operation timed out"
        case .operationCancelled:
            return "Operation cancelled"
        case .invalidStringEncoding:
            return "Data could not be decoded using the expected string encoding"
        case .alreadyScanning:
            return "A scan is already in progress"
        case .readConflictsWithNotification:
            return "Cannot read a characteristic that is currently notifying"
        case let .invalidArgument(reason):
            return "Invalid argument: \(reason)"
        case .l2capOpenFailed:
            return "Opening the L2CAP channel failed"
        case .l2capChannelClosed:
            return "The L2CAP channel is closed"
        case let .unsupportedCharacteristicOperation(characteristic, required):
            return "Characteristic \(characteristic.uuidString) does not advertise the required properties: \(required)"
        }
    }
}
