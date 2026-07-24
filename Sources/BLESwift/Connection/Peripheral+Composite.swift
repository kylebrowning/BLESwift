//
//  Peripheral+Composite.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// Composite async helpers — `writeAndAwaitNotification`, `writeAndAssemble`, and `flush`
/// — built on plain sequential `await`s in the caller's task rather than a semaphore-based
/// background-task subsystem.
extension Peripheral {

    /// Writes `value` to one characteristic, then returns the first notification
    /// subsequently received on another — with the listen installed **before** the write
    /// is issued (inside one actor-isolated critical section), so a device that responds
    /// instantly cannot slip its notification into the gap. The write is always
    /// `.withResponse`. If `notifyCharacteristic` already has active subscribers, this call
    /// transparently joins their shared subscription without disturbing it.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - writeCharacteristic: The characteristic to write to.
    ///   - notifyCharacteristic: The characteristic to await a notification on.
    ///   - timeout: How long the **whole** sequence (subscribe + write + wait) may take
    ///     before throwing ``BLESwiftError/listenTimedOut``. Defaults to 15 seconds; `nil`
    ///     waits indefinitely.
    /// - Returns: The first notification value, decoded as `R`.
    /// - Throws: ``BLESwiftError/notConnected``; ``BLESwiftError/listenTimedOut`` on timeout;
    ///   discovery/write errors as documented on ``write(_:to:type:timeout:)``; whatever
    ///   `value`'s `Transmittable` encoding or `R`'s `Receivable` decoding throws; or the
    ///   error the connection tore down with.
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
    /// arrive as an unknown number of packets: raw notification payloads are accumulated
    /// until exactly `expectedLength` bytes have been received, then decoded as `R`.
    ///
    /// Accumulation past `expectedLength` throws
    /// ``BLESwiftError/tooMuchData(expected:received:)`` (carrying everything received), and
    /// `timeout` covers the **whole assembly** — a device that sends part of the reply and
    /// then goes silent still times out.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - writeCharacteristic: The characteristic to write to.
    ///   - notifyCharacteristic: The characteristic the reply packets arrive on.
    ///   - expectedLength: The total size, in bytes, of the assembled reply.
    ///   - timeout: How long the whole sequence (subscribe + write + full assembly) may
    ///     take before throwing ``BLESwiftError/listenTimedOut``. Defaults to 15 seconds;
    ///     `nil` waits indefinitely.
    /// - Returns: The assembled reply, decoded as `R`.
    /// - Throws: ``BLESwiftError/tooMuchData(expected:received:)`` if more than
    ///   `expectedLength` bytes arrive; otherwise everything documented on
    ///   ``writeAndAwaitNotification(write:to:awaitOn:timeout:)``.
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

    /// Drains and discards any stale, buffered notifications on `characteristic`,
    /// returning once a full `quietPeriod` passes with no data — every packet that does
    /// arrive restarts the window. Useful before a request/response exchange so a leftover
    /// notification from an abandoned exchange can't be mistaken for the fresh reply.
    /// Notifications are enabled for the duration and released afterward (refcounted — an
    /// existing subscription is joined, not disturbed; concurrent subscribers also observe
    /// the flushed packets).
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic to flush.
    ///   - quietPeriod: How long the characteristic must stay silent before the flush is
    ///     considered complete. Must be strictly positive. Defaults to 3 seconds.
    /// - Throws: ``BLESwiftError/invalidArgument(_:)`` if `quietPeriod` is not strictly
    ///   positive (BLESwift never crashes on argument validation); ``BLESwiftError/notConnected``; discovery errors as
    ///   documented on ``read(from:timeout:)``; or the error the connection tore down
    ///   with mid-flush.
    public func flush(
        _ characteristic: CharacteristicIdentifier,
        quietPeriod: Duration = .seconds(3)
    ) async throws {
        let central = try resolveCentral()
        try await central.performFlush(peripheral: id, characteristic: characteristic, quietPeriod: quietPeriod)
    }
}
