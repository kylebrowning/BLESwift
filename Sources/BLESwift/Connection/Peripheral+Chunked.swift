//
//  Peripheral+Chunked.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// Progress of a chunked write: the bytes sent so far, out of the total.
///
/// The stream variant of `Peripheral.writeChunked(...)` emits this value after each chunk.
/// ``bytesSent`` never decreases and ends exactly at ``totalBytes``.
public struct WriteProgress: Sendable, Equatable {

    /// Cumulative bytes sent so far. For `.withResponse`, the peripheral also confirmed them.
    public let bytesSent: Int

    /// The total size of the payload in bytes.
    public let totalBytes: Int

    /// Whether every byte is sent (`bytesSent == totalBytes`).
    public var isComplete: Bool { bytesSent == totalBytes }

    /// Creates a progress value from the bytes sent so far and the total payload size.
    public init(bytesSent: Int, totalBytes: Int) {
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
    }
}

extension Peripheral {

    /// Writes `value` to `characteristic` in chunks. It sends each chunk only after the
    /// previous chunk completes. The whole sequence holds the characteristic, so no other
    /// write can occur between chunks. Each chunk uses the same write path as
    /// ``write(_:to:type:timeout:)``. A `.withoutResponse` chunk first waits for the
    /// `canSendWriteWithoutResponse` signal. See <doc:ReadingWritingNotifications#Chunked-writes>.
    ///
    /// - Important: `timeout` applies **per chunk**, not to the whole payload.
    /// - Important: If the task is cancelled between chunks, the method stops and throws
    ///   ``BLESwiftError/operationCancelled``. The caller must resolve a partially sent payload
    ///   at the protocol level.
    /// - Note: There is no framing hook. BLESwift slices the raw bytes on `chunkSize`
    ///   boundaries. Encode any header or sequence number into `value`.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - characteristic: The characteristic to write to.
    ///   - type: Whether each chunk waits for the write confirmation. The default is
    ///     `.withResponse`.
    ///   - chunkSize: Bytes for each chunk. The default is ``maximumWriteValueLength(for:)``
    ///     for `type`. If `chunkSize` is larger than the payload, the method sends the payload
    ///     as one chunk.
    ///   - timeout: The timeout for each chunk. The default `nil` waits without a limit.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/invalidArgument(_:)`` if `chunkSize` is not positive or is more
    ///     than ``maximumWriteValueLength(for:)`` for `type`.
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/missingService(_:)`` or ``BLESwiftError/missingCharacteristic(_:)``.
    ///   - ``BLESwiftError/timedOut``.
    ///   - ``BLESwiftError/operationCancelled``.
    ///   - The error that the `Transmittable` encoding of `value` throws.
    ///   - The error that CoreBluetooth reports.
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

    /// The progress-reporting variant of `writeChunked(_:to:type:chunkSize:timeout:)`. It
    /// emits a ``WriteProgress`` after each chunk. Use it for firmware-update UIs and similar
    /// tasks.
    ///
    /// The stream emits one ``WriteProgress`` for each chunk, with the cumulative
    /// ``WriteProgress/bytesSent``, and then finishes. An empty payload emits exactly one
    /// `WriteProgress(bytesSent: 0, totalBytes: 0)`. A validation, timeout, cancellation, or
    /// CoreBluetooth error ends the stream with that error. If the consuming task is
    /// cancelled, the write stops between chunks.
    ///
    /// The cautions of the plain variant apply: `timeout` is for each chunk, cancellation
    /// leaves a partially sent payload, and there is no framing hook.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - characteristic: The characteristic to write to.
    ///   - type: Whether each chunk waits for the write confirmation. The default is
    ///     `.withResponse`.
    ///   - chunkSize: Bytes for each chunk. The default is ``maximumWriteValueLength(for:)``
    ///     for `type`.
    ///   - timeout: The timeout for each chunk. The default `nil` waits without a limit.
    /// - Returns: A stream of ``WriteProgress`` values, one for each chunk. The last value
    ///   reaches the total.
    public func writeChunked(
        _ value: some Transmittable,
        to characteristic: CharacteristicIdentifier,
        type: WriteType = .withResponse,
        chunkSize: Int? = nil,
        timeout: Duration? = nil
    ) -> AsyncThrowingStream<WriteProgress, Error> {
        AsyncThrowingStream { continuation in
            // Encode before the task starts. `Transmittable` is not `Sendable`, so `value` cannot
            // enter the `Task`, but the resulting `Data` can.
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
    /// `data` into chunks of that size. An empty `data` gives no chunks.
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
