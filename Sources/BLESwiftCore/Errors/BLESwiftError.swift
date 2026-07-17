//
//  BLESwiftError.swift
//  BLESwiftCore
//

import Foundation

/// Errors thrown by BLESwift.
///
/// `BLESwiftError`'s cases cover connection, GATT, and scanning failures. Cases whose
/// subsystem was deleted in BLESwift's redesign (background-task mode, indefinite flush,
/// multiple-listen trap/replace policy, queued disconnection, and the single-scan-specific
/// error superseded by ``alreadyScanning``) were dropped; new cases were added where
/// BLESwift's async/await and `AsyncSequence`-based API introduces situations a
/// callback-based API wouldn't have.
public enum BLESwiftError: Error, Sendable, Equatable {

    // MARK: - Core Cases

    /// Bluetooth is either turned off or unavailable.
    case bluetoothUnavailable
    /// BLESwift does not support another connection request if already connected or still
    /// connecting.
    case multipleConnectNotSupported
    /// BLESwift does not support another disconnection request if still disconnecting.
    case multipleDisconnectNotSupported
    /// A connection request has timed out.
    case connectionTimedOut
    /// BLESwift is not connected to a peripheral.
    case notConnected
    /// A Bluetooth service was not found.
    case missingService(ServiceIdentifier)
    /// A Bluetooth characteristic was not found.
    case missingCharacteristic(CharacteristicIdentifier)
    /// A Bluetooth operation was cancelled (e.g. via `cancelAllOperations`).
    case cancelled
    /// `disconnect()` was called explicitly.
    case explicitDisconnect
    /// The peripheral disconnected unexpectedly.
    case unexpectedDisconnect
    /// An attempt to listen on a characteristic has timed out.
    case listenTimedOut
    /// An attempt to read a characteristic has failed.
    case readFailed
    /// An attempt to write a characteristic has failed.
    case writeFailed
    /// An attempt to read a value from a characteristic returned no data unexpectedly.
    case missingData
    /// An attempt to extract a range of `Data` failed due to incorrect bounds or an
    /// unexpected length.
    case dataOutOfBounds(start: Int, length: Int, count: Int)
    /// An unexpected peripheral was cached and retrieved from CoreBluetooth.
    case unexpectedPeripheral(PeripheralIdentifier)
    /// iOS will not continue scanning in the background if `allowDuplicates` is `true`.
    case allowDuplicatesInBackgroundNotSupported
    /// iOS will not continue scanning in the background if no service identifiers are
    /// specified.
    case missingServiceIdentifiersInBackground
    /// BLESwift has stopped.
    case stopped
    /// BLESwift cannot perform certain actions while background restoration is still in
    /// progress.
    case backgroundRestorationInProgress
    /// The startup background task expired during state restoration.
    case startupBackgroundTaskExpired
    /// An operation expecting a certain amount of data received more than expected
    /// (e.g. `writeAndAssemble`).
    case tooMuchData(expected: Int, received: Data)

    // MARK: - New in BLESwift

    /// A BLESwift operation timed out. Distinct from ``connectionTimedOut`` and
    /// ``listenTimedOut``, which are specific timeout cases; this case covers other
    /// timeout-bounded operations (e.g. GATT read/write/RSSI) introduced by BLESwift's
    /// `timeout:` parameters.
    case timedOut
    /// A BLESwift operation was cancelled via Swift's structured concurrency (task
    /// cancellation). Bridges naturally to `CancellationError` — call sites that catch
    /// `CancellationError` from a cancelled `Task` should treat it equivalently to this
    /// case.
    case operationCancelled
    /// Data received over Bluetooth could not be decoded using the expected string
    /// encoding. A force-unwrapped `String(bluetoothData:)` would crash on invalid UTF-8;
    /// BLESwift throws this error instead.
    case invalidStringEncoding
    /// BLESwift does not support starting another scan while one is already active. CoreBluetooth
    /// exposes a single physical scanner, so BLESwift enforces single-scan discipline.
    case alreadyScanning
    /// A read was requested on a characteristic that is currently notifying.
    /// CoreBluetooth's `didUpdateValueFor` callback can't disambiguate a read completion
    /// from a notification delivery while a characteristic is actively notifying, so a
    /// concurrent read is rejected instead.
    case readConflictsWithNotification
    /// A BLESwift API was called with an invalid argument; the payload describes which
    /// argument and why (e.g. a non-positive flush timeout). BLESwift throws instead of
    /// crashing on argument validation failures.
    case invalidArgument(String)
}

extension BLESwiftError: LocalizedError {
    /// A human-readable description of the error, suitable for logging or display.
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth unavailable"
        case .multipleConnectNotSupported:
            return "Multiple connect is not supported"
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
        }
    }
}
