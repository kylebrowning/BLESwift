//
//  CBL2CAPChannelTransport.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation

/// The CoreBluetooth ``L2CAPChannelRemote``. It wraps the Foundation `InputStream` and
/// `OutputStream` of a `CBL2CAPChannel` and pumps them as async byte I/O.
///
/// ## No RunLoop, and never the actor
/// Foundation streams normally need a RunLoop, and nothing can schedule a RunLoop on the
/// `Central` actor's executor. This transport schedules both streams on its own serial
/// ``pumpQueue`` with `CFReadStreamSetDispatchQueue` and `CFWriteStreamSetDispatchQueue`, so
/// GCD drives them off the actor.
///
/// ## Sendable by queue confinement (no locks, no `@unchecked`)
/// Every mutable stored property is `nonisolated(unsafe)` and code touches it **only** on
/// ``pumpQueue``. A `dispatchPrecondition` guards each entry point, and ``write(_:)`` and
/// ``close(error:)`` hop on with `pumpQueue.async`. This is a narrow confinement and not a
/// type-wide `@unchecked Sendable`, which a grep check forbids.
///
/// ## Deterministic teardown
/// ``close(error:)`` hops onto ``pumpQueue``, closes and unschedules both streams, finishes
/// the inbound stream, and fails any queued write. It is idempotent.
final class CBL2CAPChannelTransport: NSObject, L2CAPChannelRemote, StreamDelegate {

    let psm: L2CAPPSM

    /// The dedicated serial queue that confines each stream event, read, and write. It is
    /// never the actor's executor and never a RunLoop.
    private let pumpQueue: DispatchQueue

    /// `InputStream` and `OutputStream` are not `Sendable`, but code touches them only on
    /// ``pumpQueue``, like every other stored property here.
    nonisolated(unsafe) private let inputStream: InputStream
    nonisolated(unsafe) private let outputStream: OutputStream

    /// The single inbound stream for the `L2CAPChannel` handle. Code calls `yield` and `finish`
    /// on the continuation only from ``pumpQueue``.
    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation

    /// One queued outbound write that waits for delivery, which can be partial. Confined to
    /// the pump.
    private struct WriteJob {
        let bytes: [UInt8]
        var offset: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    /// FIFO of outbound writes that are not fully flushed. Confined to the pump.
    nonisolated(unsafe) private var writeQueue: [WriteJob] = []
    /// Whether the output stream reports available space. Confined to the pump.
    nonisolated(unsafe) private var hasSpace = false
    /// Whether ``teardown(error:)`` already ran. Confined to the pump.
    nonisolated(unsafe) private var closed = false
    /// Whether the streams were opened, so ``teardown(error:)`` closes only opened streams.
    /// Confined to the pump.
    nonisolated(unsafe) private var opened = false

    /// The `CBL2CAPChannel` that owns these streams. CoreBluetooth tears down the L2CAP
    /// connection when the channel deallocates, so the transport keeps it alive until
    /// ``teardown(error:)``. The type is `AnyObject`, so the stream-only initializer and tests
    /// can pass `nil`. Confined to the pump.
    nonisolated(unsafe) private var underlyingChannel: AnyObject?

    /// Creates a transport over the streams of an open channel. `retaining` keeps the streams'
    /// owner (the `CBL2CAPChannel`) alive until teardown.
    init(psm: L2CAPPSM, inputStream: InputStream, outputStream: OutputStream, retaining underlyingChannel: AnyObject? = nil) {
        self.psm = psm
        self.pumpQueue = DispatchQueue(label: "com.bleswift.l2cap.pump.\(psm.rawValue).\(UUID().uuidString)")
        self.inputStream = inputStream
        self.outputStream = outputStream
        self.underlyingChannel = underlyingChannel
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.inboundStream = stream
        self.inboundContinuation = continuation
        super.init()
        start()
    }

    /// Creates a transport from a `CBL2CAPChannel` that just opened. The delegate proxy uses it.
    convenience init(channel: CBL2CAPChannel) {
        self.init(
            psm: L2CAPPSM(channel.psm),
            inputStream: channel.inputStream,
            outputStream: channel.outputStream,
            retaining: channel
        )
    }

    /// Schedules both streams on ``pumpQueue`` and opens them, all on ``pumpQueue``, so the
    /// first `.hasSpaceAvailable` and `.hasBytesAvailable` callbacks already arrive there.
    private func start() {
        pumpQueue.async { [self] in
            dispatchPrecondition(condition: .onQueue(pumpQueue))
            inputStream.delegate = self
            outputStream.delegate = self
            CFReadStreamSetDispatchQueue(inputStream as CFReadStream, pumpQueue)
            CFWriteStreamSetDispatchQueue(outputStream as CFWriteStream, pumpQueue)
            inputStream.open()
            outputStream.open()
            opened = true
        }
    }

    // MARK: - L2CAPChannelRemote

    func inbound() -> AsyncThrowingStream<Data, Error> {
        inboundStream
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pumpQueue.async { [self] in
                dispatchPrecondition(condition: .onQueue(pumpQueue))
                guard !closed else {
                    continuation.resume(throwing: BLESwiftError.l2capChannelClosed)
                    return
                }
                guard !data.isEmpty else {
                    continuation.resume()
                    return
                }
                writeQueue.append(WriteJob(bytes: [UInt8](data), offset: 0, continuation: continuation))
                flushWrites()
            }
        }
    }

    func close(error: Error?) {
        pumpQueue.async { [self] in
            teardown(error: error)
        }
    }

    // MARK: - Pump (``pumpQueue`` only)

    /// Writes the head-of-queue jobs as far as the output stream accepts them. It resumes a
    /// job's continuation when all its bytes are written. It stops when the queue is empty, or
    /// when the stream has no more space, and then waits for the next `.hasSpaceAvailable`.
    private func flushWrites() {
        dispatchPrecondition(condition: .onQueue(pumpQueue))
        while hasSpace, !writeQueue.isEmpty {
            var job = writeQueue[0]
            let remaining = job.bytes.count - job.offset
            let written = job.bytes.withUnsafeBufferPointer { buffer -> Int in
                outputStream.write(buffer.baseAddress! + job.offset, maxLength: remaining)
            }
            if written < 0 {
                teardown(error: outputStream.streamError ?? BLESwiftError.l2capChannelClosed)
                return
            }
            if written == 0 {
                // No capacity, although the flag says there is. Wait for the next
                // `.hasSpaceAvailable`.
                hasSpace = false
                break
            }
            job.offset += written
            if job.offset >= job.bytes.count {
                writeQueue.removeFirst()
                job.continuation.resume()
            } else {
                // Partial write. Keep the remainder queued. The stream is full.
                writeQueue[0] = job
                hasSpace = false
                break
            }
        }
    }

    /// Drains the available inbound bytes and yields each chunk to the inbound stream.
    private func readInbound() {
        dispatchPrecondition(condition: .onQueue(pumpQueue))
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        while inputStream.hasBytesAvailable {
            let read = inputStream.read(&buffer, maxLength: capacity)
            if read > 0 {
                inboundContinuation.yield(Data(buffer[0..<read]))
            } else if read < 0 {
                teardown(error: inputStream.streamError ?? BLESwiftError.l2capChannelClosed)
                return
            } else {
                break
            }
        }
    }

    private func teardown(error: Error?) {
        dispatchPrecondition(condition: .onQueue(pumpQueue))
        guard !closed else { return }
        closed = true

        if opened {
            inputStream.close()
            outputStream.close()
        }
        CFReadStreamSetDispatchQueue(inputStream as CFReadStream, nil)
        CFWriteStreamSetDispatchQueue(outputStream as CFWriteStream, nil)
        inputStream.delegate = nil
        outputStream.delegate = nil

        if let error {
            inboundContinuation.finish(throwing: error)
        } else {
            inboundContinuation.finish()
        }

        let pending = writeQueue
        writeQueue.removeAll()
        for job in pending {
            job.continuation.resume(throwing: error ?? BLESwiftError.l2capChannelClosed)
        }

        // Releasing the `CBL2CAPChannel` closes the OS-level channel.
        underlyingChannel = nil
    }

    // MARK: - StreamDelegate (``pumpQueue`` only)

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        dispatchPrecondition(condition: .onQueue(pumpQueue))
        guard !closed else { return }
        switch eventCode {
        case .hasBytesAvailable:
            readInbound()
        case .hasSpaceAvailable:
            hasSpace = true
            flushWrites()
        case .errorOccurred:
            teardown(error: aStream.streamError ?? BLESwiftError.l2capChannelClosed)
        case .endEncountered:
            // Drain the final inbound bytes, then finish the inbound stream cleanly.
            if aStream === inputStream {
                readInbound()
            }
            teardown(error: nil)
        default:
            break
        }
    }
}
