//
//  Peripheral+Composite.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// Composite async helpers: `writeAndAwaitNotification`, `writeAndAssemble`, and `flush`.
/// They use sequential `await` calls in the caller's task.
extension Peripheral {

    /// Writes `value` to one characteristic. Then it returns the first notification that
    /// arrives on another characteristic. The method starts to listen **before** it writes, in
    /// one actor-isolated critical section, so a device that responds immediately cannot
    /// notify too early. The write is always `.withResponse`. If `notifyCharacteristic`
    /// already has subscribers, this call joins their subscription and does not disturb it.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - writeCharacteristic: The characteristic to write to.
    ///   - notifyCharacteristic: The characteristic on which to wait for a notification.
    ///   - timeout: The maximum time for the **whole** sequence (subscribe, write, and wait).
    ///     After this time, the method throws ``BLESwiftError/listenTimedOut``. The default is
    ///     15 seconds. `nil` waits without a limit.
    /// - Returns: The first notification value, decoded as `R`.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/listenTimedOut`` on timeout.
    ///   - The discovery and write errors that ``write(_:to:type:timeout:)`` documents.
    ///   - The error that the `Transmittable` encoding of `value` or the `Receivable`
    ///     decoding of `R` throws.
    ///   - The error that ended the connection.
    public func writeAndAwaitNotification<W: Transmittable, R: Receivable>(
        write value: W,
        to writeCharacteristic: CharacteristicIdentifier,
        awaitOn notifyCharacteristic: CharacteristicIdentifier,
        timeout: Duration? = .seconds(15)
    ) async throws -> R {
        let central = try resolveCentral()
        let data = try value.toBluetoothData()
        let response = try await central.performWriteAndAwaitNotification(
            peripheral: id,
            writeCharacteristic: writeCharacteristic,
            notifyCharacteristic: notifyCharacteristic,
            data: data,
            timeout: timeout
        )
        return try R(bluetoothData: response)
    }

    /// Like ``writeAndAwaitNotification(write:to:awaitOn:timeout:)``, but for replies that
    /// arrive as an unknown number of packets. The method accumulates raw notification
    /// payloads until it has exactly `expectedLength` bytes. Then it decodes them as `R`.
    ///
    /// If more than `expectedLength` bytes arrive, the method throws
    /// ``BLESwiftError/tooMuchData(expected:received:)`` with everything received. `timeout`
    /// covers the **whole assembly**, so a device that sends part of the reply and stops
    /// causes a timeout.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - writeCharacteristic: The characteristic to write to.
    ///   - notifyCharacteristic: The characteristic on which the reply packets arrive.
    ///   - expectedLength: The total size, in bytes, of the assembled reply.
    ///   - timeout: The maximum time for the whole sequence (subscribe, write, and full
    ///     assembly). After this time, the method throws ``BLESwiftError/listenTimedOut``. The
    ///     default is 15 seconds. `nil` waits without a limit.
    /// - Returns: The assembled reply, decoded as `R`.
    /// - Throws: ``BLESwiftError/tooMuchData(expected:received:)`` if more than
    ///   `expectedLength` bytes arrive, and each error that
    ///   ``writeAndAwaitNotification(write:to:awaitOn:timeout:)`` documents.
    public func writeAndAssemble<W: Transmittable, R: Receivable>(
        write value: W,
        to writeCharacteristic: CharacteristicIdentifier,
        assembleFrom notifyCharacteristic: CharacteristicIdentifier,
        expectedLength: Int,
        timeout: Duration? = .seconds(15)
    ) async throws -> R {
        let central = try resolveCentral()
        let data = try value.toBluetoothData()
        let assembled = try await central.performWriteAndAssemble(
            peripheral: id,
            writeCharacteristic: writeCharacteristic,
            notifyCharacteristic: notifyCharacteristic,
            data: data,
            expectedLength: expectedLength,
            timeout: timeout
        )
        return try R(bluetoothData: assembled)
    }

    /// Discards stale notifications on `characteristic`. It returns when a full `quietPeriod`
    /// passes with no data. Each packet that arrives restarts the window. Use it before a
    /// request/response exchange, so a leftover notification cannot be mistaken for the new
    /// reply. The method enables notifications for its duration and releases them afterward.
    /// It joins an existing subscription and does not disturb it. Concurrent subscribers also
    /// see the flushed packets.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic to flush.
    ///   - quietPeriod: How long the characteristic must stay silent before the flush is
    ///     complete. It must be strictly positive. The default is 3 seconds.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/invalidArgument(_:)`` if `quietPeriod` is not strictly positive.
    ///   - ``BLESwiftError/notConnected``.
    ///   - The discovery errors that ``read(from:timeout:)`` documents.
    ///   - The error that ended the connection during the flush.
    public func flush(
        _ characteristic: CharacteristicIdentifier,
        quietPeriod: Duration = .seconds(3)
    ) async throws {
        let central = try resolveCentral()
        try await central.performFlush(peripheral: id, characteristic: characteristic, quietPeriod: quietPeriod)
    }
}
