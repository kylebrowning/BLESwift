//
//  Peripheral+Chunked.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// Progress for a chunked write: how many bytes have been sent so far, out of the total.
///
/// Emitted by the `AsyncThrowingStream` variant of `Peripheral.writeChunked(...)` after each
/// chunk completes. ``bytesSent`` is monotonically non-decreasing and ends exactly at
/// ``totalBytes``.
public struct WriteProgress: Sendable, Equatable {

    /// Cumulative bytes sent (and confirmed, for `.withResponse`) so far.
    public let bytesSent: Int

    /// The payload's total size in bytes.
    public let totalBytes: Int

    /// Whether every byte has been sent — i.e. `bytesSent == totalBytes`.
    public var isComplete: Bool { bytesSent == totalBytes }

    public init(bytesSent: Int, totalBytes: Int) {
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
    }
}

extension Peripheral {

    /// Writes `value` to `characteristic` split into chunks, sending each only after the
    /// previous one completes — the outbound counterpart to
    /// ``writeAndAssemble(write:to:assembleFrom:expectedLength:timeout:)``. Awaits full
    /// completion.
    ///
    /// The chunk sequence holds `characteristic`'s serialization lane as a single unit, so no
    /// other write can interleave between chunks. Each chunk goes through the same write path
    /// as ``write(_:to:type:timeout:)``: `.withResponse` chunks await their `didWriteValueFor`
    /// confirmation before the next is sent; `.withoutResponse` chunks await CoreBluetooth's
    /// `canSendWriteWithoutResponse` back-pressure signal first.
    ///
    /// - Important: `timeout` applies **per chunk**, not to the whole payload.
    /// - Important: Cancelling the task between chunks stops sending and throws
    ///   ``BLESwiftError/operationCancelled``. A partially-sent payload is the caller's
    ///   problem to reconcile at the protocol level.
    /// - Note: There is no framing hook — BLESwift sends the raw payload bytes, sliced on
    ///   `chunkSize` boundaries. Any per-chunk headers/sequence numbers are the caller's
    ///   responsibility; encode them into `value` yourself.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - characteristic: The characteristic to write to.
    ///   - type: Whether each chunk waits for CoreBluetooth's write confirmation. Defaults to
    ///     `.withResponse`.
    ///   - chunkSize: Bytes per chunk. Defaults to ``maximumWriteValueLength(for:)`` for
    ///     `type`. A `chunkSize` larger than the payload sends it as a single chunk.
    ///   - timeout: Per-chunk timeout. `nil` (the default) waits indefinitely per chunk.
    /// - Throws: ``BLESwiftError/invalidArgument(_:)`` if `chunkSize` is not positive or
    ///   exceeds ``maximumWriteValueLength(for:)`` for `type`; ``BLESwiftError/notConnected``;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``;
    ///   ``BLESwiftError/timedOut``; ``BLESwiftError/operationCancelled``; whatever `value`'s
    ///   `Transmittable` encoding throws; or whatever error CoreBluetooth reports.
    public func writeChunked(
        _ value: some Transmittable,
        to characteristic: CharacteristicIdentifier,
        type: WriteType = .withResponse,
        chunkSize: Int? = nil,
        timeout: Duration? = nil
    ) async throws {
        let central = try resolveCentral()
        let data = try value.toBluetoothData()
        let chunks = try await makeChunks(from: data, type: type, chunkSize: chunkSize)
        try await central.performChunkedWrite(
            peripheral: id,
            characteristic: characteristic,
            chunks: chunks,
            totalBytes: data.count,
            type: type,
            timeout: timeout,
            progress: { _ in }
        )
    }

    /// The progress-reporting variant of the plain `writeChunked(_:to:type:chunkSize:timeout:)`
    /// above — same work, but emits a ``WriteProgress`` after each chunk completes. Intended
    /// for firmware-update UIs and the like.
    ///
    /// The returned stream emits one ``WriteProgress`` per chunk with the cumulative
    /// ``WriteProgress/bytesSent``, then finishes. An empty payload emits exactly one
    /// `WriteProgress(bytesSent: 0, totalBytes: 0)` and finishes. Any error (validation,
    /// timeout, cancellation, CoreBluetooth failure) terminates the stream by throwing.
    /// Cancelling the consuming task cancels the underlying write between chunks.
    ///
    /// The same caveats as the plain variant apply: `timeout` is per chunk, cancellation
    /// between chunks leaves a partially-sent payload for the caller to handle, and there is
    /// no framing hook.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - characteristic: The characteristic to write to.
    ///   - type: Whether each chunk waits for CoreBluetooth's write confirmation. Defaults to
    ///     `.withResponse`.
    ///   - chunkSize: Bytes per chunk. Defaults to ``maximumWriteValueLength(for:)`` for
    ///     `type`.
    ///   - timeout: Per-chunk timeout. `nil` (the default) waits indefinitely per chunk.
    /// - Returns: A stream of ``WriteProgress`` values, one per chunk, ending at the total.
    public func writeChunked(
        _ value: some Transmittable,
        to characteristic: CharacteristicIdentifier,
        type: WriteType = .withResponse,
        chunkSize: Int? = nil,
        timeout: Duration? = nil
    ) -> AsyncThrowingStream<WriteProgress, Error> {
        AsyncThrowingStream { continuation in
            // Encode eagerly here: `Transmittable` isn't `Sendable`, so `value` can't cross
            // into the producing `Task`; the resulting `Data` can.
            let data: Data
            do {
                data = try value.toBluetoothData()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let peripheral = self
            let task = Task {
                do {
                    let central = try peripheral.resolveCentral()
                    let chunks = try await peripheral.makeChunks(from: data, type: type, chunkSize: chunkSize)
                    try await central.performChunkedWrite(
                        peripheral: peripheral.id,
                        characteristic: characteristic,
                        chunks: chunks,
                        totalBytes: data.count,
                        type: type,
                        timeout: timeout,
                        progress: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Validates `chunkSize` against ``maximumWriteValueLength(for:)`` for `type` and slices
    /// `data` into that many-byte chunks. An empty `data` yields no chunks.
    func makeChunks(from data: Data, type: WriteType, chunkSize: Int?) async throws -> [Data] {
        let maxLength = await maximumWriteValueLength(for: type)
        let size: Int
        if let chunkSize {
            guard chunkSize > 0 else {
                throw BLESwiftError.invalidArgument("chunkSize \(chunkSize) must be greater than zero")
            }
            guard chunkSize <= maxLength else {
                throw BLESwiftError.invalidArgument("chunkSize \(chunkSize) exceeds maximum write length \(maxLength) for \(type)")
            }
            size = chunkSize
        } else {
            size = maxLength
        }

        guard !data.isEmpty else { return [] }

        var chunks: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(Data(data[index..<end]))
            index = end
        }
        return chunks
    }
}
