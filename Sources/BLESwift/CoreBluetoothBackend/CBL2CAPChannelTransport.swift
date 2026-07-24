//
//  CBL2CAPChannelTransport.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation

/// The CoreBluetooth ``L2CAPChannelRemote``: wraps a `CBL2CAPChannel`'s Foundation
/// `InputStream`/`OutputStream` and pumps them as async byte I/O.
///
/// ## No RunLoop, and never the actor
/// `InputStream`/`OutputStream` are classically RunLoop-driven, but nothing may schedule a
/// RunLoop on the `Central` actor's executor. This transport instead schedules both streams
/// on its own dedicated serial ``pumpQueue`` via `CFReadStreamSetDispatchQueue`/
/// `CFWriteStreamSetDispatchQueue` — GCD-scheduled, never a RunLoop, and off the actor.
///
/// ## Sendable via queue confinement (not locks, not `@unchecked`)
/// Every mutable stored property is `nonisolated(unsafe)` and touched **only** on
/// ``pumpQueue`` — a `dispatchPrecondition` guards each entry point, and
/// ``write(_:)``/``close(error:)`` hop on via `pumpQueue.async`. A documented, narrow
/// confinement, not a type-wide `@unchecked Sendable` (which stays grep-forbidden).
///
/// ## Deterministic teardown
/// ``close(error:)`` hops onto ``pumpQueue``, closes and unschedules both streams, finishes
/// the inbound stream, and fails any queued write. Idempotent.
final class CBL2CAPChannelTransport: NSObject, L2CAPChannelRemote, StreamDelegate {

    let psm: L2CAPPSM

    /// The dedicated serial queue every stream event, read, and write is confined to —
    /// created per transport, never the actor's executor and never a RunLoop.
    private let pumpQueue: DispatchQueue

    /// `InputStream`/`OutputStream` are not `Sendable`, but touched only on ``pumpQueue`` —
    /// same queue-confinement as every other stored property here.
    nonisolated(unsafe) private let inputStream: InputStream
    nonisolated(unsafe) private let outputStream: OutputStream

    /// The single inbound stream vended to the `L2CAPChannel` handle. The continuation is
    /// only ever `yield`ed/`finish`ed from ``pumpQueue``.
    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation

    /// One queued outbound write awaiting (possibly partial) delivery. Pump-confined.
    private struct WriteJob {
        let bytes: [UInt8]
        var offset: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    /// FIFO of outbound writes not yet fully flushed. Pump-confined.
    nonisolated(unsafe) private var writeQueue: [WriteJob] = []
    /// Whether the output stream currently reports space available. Pump-confined.
    nonisolated(unsafe) private var hasSpace = false
    /// Whether ``teardown(error:)`` has already run. Pump-confined.
    nonisolated(unsafe) private var closed = false
    /// Whether the streams were opened (so ``teardown(error:)`` only closes opened streams).
    /// Pump-confined.
    nonisolated(unsafe) private var opened = false

    /// The `CBL2CAPChannel` these streams belong to. CoreBluetooth tears down the underlying
    /// L2CAP connection when the channel object deallocates, so the transport must keep it
    /// alive; ``teardown(error:)`` releases it. `AnyObject` so the stream-only initializer
    /// (and tests) can pass `nil`. Pump-confined.
    nonisolated(unsafe) private var underlyingChannel: AnyObject?

    /// Creates a transport over an already-open channel's streams. `retaining` keeps the
    /// object that owns the streams (the `CBL2CAPChannel`) alive until teardown.
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

    /// Convenience for the delegate proxy: build a transport straight from a freshly-opened
    /// `CBL2CAPChannel`.
    convenience init(channel: CBL2CAPChannel) {
        self.init(
            psm: L2CAPPSM(channel.psm),
            inputStream: channel.inputStream,
            outputStream: channel.outputStream,
            retaining: channel
        )
    }

    /// Schedules both streams on ``pumpQueue`` and opens them — all on ``pumpQueue``, so the
    /// very first `.hasSpaceAvailable`/`.hasBytesAvailable` callbacks already arrive there.
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

    /// Writes as much of the head-of-queue job(s) as the output stream currently accepts,
    /// resuming each job's continuation once its bytes are fully written. Stops when the
    /// queue drains or the stream reports no more space (awaiting the next
    /// `.hasSpaceAvailable`).
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
                // No capacity right now despite the flag — wait for the next
                // `.hasSpaceAvailable` before trying again.
                hasSpace = false
                break
            }
            job.offset += written
            if job.offset >= job.bytes.count {
                writeQueue.removeFirst()
                job.continuation.resume()
            } else {
                // Partial write: keep the remainder queued; the stream is now full.
                writeQueue[0] = job
                hasSpace = false
                break
            }
        }
    }

    /// Drains every currently-available inbound byte, yielding each chunk to the inbound
    /// stream.
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

        // Releasing the `CBL2CAPChannel` is what closes the OS-level channel.
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
            // Drain any final inbound bytes, then finish the inbound stream cleanly.
            if aStream === inputStream {
                readInbound()
            }
            teardown(error: nil)
        default:
            break
        }
    }
}
