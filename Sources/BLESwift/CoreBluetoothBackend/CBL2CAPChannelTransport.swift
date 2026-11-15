//
//  CBL2CAPChannelTransport.swift
//  BLESwift
//

import BLESwiftCompat17
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
/// ## Sendable by queue confinement (no `@unchecked`)
/// Every mutable stored property is `nonisolated(unsafe)` and code touches it **only** on
/// ``pumpQueue``. `deinit` only reads it and hands copies to ``pumpQueue``. The one exception
/// is the stream that ``inbound()`` gives out,
/// which a `Mutex` guards. A `dispatchPrecondition` guards each entry point, and ``write(_:)`` and
/// ``close(error:)`` hop on with `pumpQueue.async`. This is a narrow confinement and not a
/// type-wide `@unchecked Sendable`, which a grep check forbids.
///
/// ## Deterministic teardown
/// ``close(error:)`` hops onto ``pumpQueue``, closes and unschedules both streams, finishes
/// the inbound stream, and fails any queued write. It is idempotent. If the owner releases the
/// transport and its inbound stream without a close, `deinit` does the same work.
final class CBL2CAPChannelTransport: NSObject, L2CAPChannelRemote, StreamDelegate {

    let psm: L2CAPPSM

    /// The dedicated serial queue that confines each stream event, read, and write. It is
    /// never the actor's executor and never a RunLoop.
    private let pumpQueue: DispatchQueue

    /// `InputStream` and `OutputStream` are not `Sendable`, but code touches them only on
    /// ``pumpQueue``, like every other stored property here.
    nonisolated(unsafe) private let inputStream: InputStream
    nonisolated(unsafe) private let outputStream: OutputStream

    /// The single inbound stream, until ``inbound()`` gives it out. After that, only the
    /// consumer holds the stream, so a consumer that releases the stream also releases this
    /// transport. A consumer calls ``inbound()`` from any isolation domain, so a `Mutex` guards
    /// this one value. Every other property stays confined to the pump.
    private let vendableStream: Mutex<AsyncThrowingStream<Data, Error>?>

    /// The continuation of the inbound stream. Code calls `yield` and `finish` on it only from
    /// ``pumpQueue``. `deinit` hands it to a block on ``pumpQueue``.
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
        self.vendableStream = Mutex(stream)
        self.inboundContinuation = continuation
        super.init()
        start()
    }

    /// Makes the streams safe when the last reference to the transport goes, so a dropped
    /// channel neither hangs its peer nor leaks the `CBL2CAPChannel`.
    ///
    /// No pump block of this transport can run now, because each block holds the transport. The
    /// CF callbacks of the two streams are different: they run on ``pumpQueue`` and hold the
    /// streams, not the transport. So the work on the streams must run on ``pumpQueue`` too.
    /// `deinit` copies the streams, the continuations, and the `CBL2CAPChannel`, and hops onto
    /// ``pumpQueue`` without the transport. The block releases the `CBL2CAPChannel` last.
    deinit {
        guard !closed else { return }
        nonisolated(unsafe) let input = inputStream
        nonisolated(unsafe) let output = outputStream
        nonisolated(unsafe) let channel = underlyingChannel
        let wasOpened = opened
        let inbound = inboundContinuation
        let writers = writeQueue.map(\.continuation)
        pumpQueue.async {
            input.delegate = nil
            output.delegate = nil
            CFReadStreamSetDispatchQueue(input as CFReadStream, nil)
            CFWriteStreamSetDispatchQueue(output as CFWriteStream, nil)
            if wasOpened {
                input.close()
                output.close()
            }
            inbound.finish()
            for writer in writers {
                writer.resume(throwing: BLESwiftError.l2capChannelClosed)
            }
            // Releasing the `CBL2CAPChannel` closes the OS-level channel.
            withExtendedLifetime(channel) {}
        }
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

    /// The inbound stream. The first call gives out the one stream. Every later call returns a
    /// stream that finishes at once, as for the other transports.
    ///
    /// The stream holds this transport until the stream terminates: it finishes, or its consumer
    /// releases it. So a consumer that still reads keeps the channel open, and a channel whose
    /// stream and handle are both released goes through `deinit`.
    func inbound() -> AsyncThrowingStream<Data, Error> {
        let stream = vendableStream.withLock { stored -> AsyncThrowingStream<Data, Error>? in
            defer { stored = nil }
            return stored
        }
        guard let stream else {
            return AsyncThrowingStream { $0.finish() }
        }
        inboundContinuation.onTermination = { [self] _ in
            withExtendedLifetime(self) {}
        }
        return stream
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
