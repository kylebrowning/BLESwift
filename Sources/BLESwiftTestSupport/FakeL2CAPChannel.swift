//
//  FakeL2CAPChannel.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation

/// An in-memory `L2CAPChannelRemote` for tests — models an open L2CAP channel as a pair of
/// queue-confined pipes, with **no** CoreBluetooth `InputStream`/`OutputStream` (or hardware)
/// involved. This is what lets inbound delivery, the write path, and teardown all be
/// exercised without a device or CB streams.
///
/// **Concurrency — queue-confined, not lock-protected.** Exactly like ``FakePeripheral``:
/// every stored property is `nonisolated(unsafe)`, safe only because every entry point
/// asserts `dispatchPrecondition(condition: .onQueue(queue))` and touches state inline —
/// off-queue code goes through the single sanctioned door, ``onQueue(_:)``. Inbound delivery
/// (``simulateInbound(_:)``) and teardown are always `queue.async`, never inline from a
/// caller's thread.
public final class FakeL2CAPChannel: L2CAPChannelRemote, Sendable {

    public let psm: L2CAPPSM

    /// The queue every method and delivery is confined to. A `FakePeripheral` hands its own
    /// queue down when it vends a channel, so the channel shares the peripheral's serial
    /// event ordering.
    public let queue: DispatchSerialQueue

    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation

    nonisolated(unsafe) private var _writtenData: [Data] = []
    nonisolated(unsafe) private var _closed = false
    nonisolated(unsafe) private var _closeError: Error?

    /// Creates a `FakeL2CAPChannel` for `psm`, confined to `queue`.
    public init(psm: L2CAPPSM, queue: DispatchSerialQueue) {
        self.psm = psm
        self.queue = queue
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.inboundStream = stream
        self.inboundContinuation = continuation
    }

    /// Hops onto ``queue`` (via `queue.async` + a continuation) to run `body`, then returns
    /// its result — the only sanctioned way for off-queue code to inspect this fake's state.
    /// Because `queue` is serial, this also flushes every previously-scheduled `.async`
    /// delivery first.
    ///
    /// This is `async` and **never blocks the calling thread** — it does *not* use
    /// `queue.sync`, whose cooperative-thread parking under the parallel test runner is the
    /// deadlock fixed in issue #13 (see ``FakeCentral/onQueue(_:)`` for the full rationale).
    ///
    /// - Warning: Never `await` from within code already on ``queue`` (a deadlock) — in
    ///   particular, not from the peripheral's event handler, since a `FakeL2CAPChannel`
    ///   shares its peripheral's queue.
    public func onQueue<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - L2CAPChannelRemote

    public func inbound() -> AsyncThrowingStream<Data, Error> {
        inboundStream
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                if _closed {
                    continuation.resume(throwing: BLESwiftError.l2capChannelClosed)
                } else {
                    _writtenData.append(data)
                    continuation.resume()
                }
            }
        }
    }

    public func close(error: Error?) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !_closed else { return }
            _closed = true
            _closeError = error
            if let error {
                inboundContinuation.finish(throwing: error)
            } else {
                inboundContinuation.finish()
            }
        }
    }

    // MARK: - Scripting / inspection

    /// Every `Data` written outbound via ``write(_:)``, in order. Read via ``onQueue(_:)``.
    public var writtenData: [Data] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _writtenData
    }

    /// Whether ``close(error:)`` has run. Read via ``onQueue(_:)``.
    public var isClosed: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _closed
    }

    /// The error ``close(error:)`` was called with, if any. Read via ``onQueue(_:)``.
    public var closeError: Error? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _closeError
    }

    /// Simulates the peer sending `data` inbound: asynchronously `yield`s it to the
    /// ``inbound()`` stream on ``queue``. A no-op once closed. Flush with ``onQueue(_:)`` (or
    /// simply consume the stream) before asserting.
    public func simulateInbound(_ data: Data) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !_closed else { return }
            inboundContinuation.yield(data)
        }
    }
}
