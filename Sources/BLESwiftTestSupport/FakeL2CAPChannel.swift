//
//  FakeL2CAPChannel.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation

/// An in-memory `L2CAPChannelRemote` for tests. It models an open L2CAP channel with queue-confined
/// pipes, and uses no CoreBluetooth streams and no hardware.
///
/// As with ``FakePeripheral``, a queue confines it and no lock protects it. Every stored property
/// is `nonisolated(unsafe)`. This is safe because every entry point runs on `queue` and touches
/// state inline. Off-queue code uses ``onQueue(_:)``.
public final class FakeL2CAPChannel: L2CAPChannelRemote, Sendable {

    /// The PSM that the channel is open on.
    public let psm: L2CAPPSM

    /// The queue that confines every method and delivery. A `FakePeripheral` passes its own queue
    /// to the channel it creates, so the channel has the same serial event order as the peripheral.
    public let queue: DispatchQueue

    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation

    /// What ``write(_:)`` does with the data that it receives.
    public enum WriteBehavior: Sendable {
        /// Records the data and completes immediately.
        case complete
        /// Records the data and never completes. ``close(error:)`` then fails every held write.
        /// This models the back-pressure of a transport that stops draining.
        case hold
    }

    nonisolated(unsafe) private var _writtenData: [Data] = []
    nonisolated(unsafe) private var _closed = false
    nonisolated(unsafe) private var _closeError: Error?
    nonisolated(unsafe) private var _writeBehavior: WriteBehavior = .complete
    nonisolated(unsafe) private var _heldWrites: [CheckedContinuation<Void, Error>] = []

    /// Creates a `FakeL2CAPChannel` for `psm`, confined to `queue`. The queue must be serial
    /// (`DispatchQueue(label:)` makes a serial queue).
    public init(psm: L2CAPPSM, queue: DispatchQueue) {
        self.psm = psm
        self.queue = queue
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.inboundStream = stream
        self.inboundContinuation = continuation
    }

    /// Runs `body` on ``queue`` and returns its result. Off-queue code must use this to inspect
    /// this fake's state. Because `queue` is serial, it also flushes the `.async` deliveries that
    /// are already scheduled. It never blocks (see ``FakeCentral/onQueue(_:)``).
    ///
    /// - Warning: Never `await` this from code that already runs on ``queue``. That deadlocks. It
    ///   includes the peripheral's event handler, because a channel shares its peripheral's queue.
    public func onQueue<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - L2CAPChannelRemote

    /// The stream of data that ``simulateInbound(_:)`` delivers. ``close(error:)`` finishes it.
    public func inbound() -> AsyncThrowingStream<Data, Error> {
        inboundStream
    }

    /// Records `data` in ``writtenData``. The completion depends on ``writeBehavior``.
    ///
    /// - Throws: `BLESwiftError.l2capChannelClosed` if the channel is closed, or when
    ///   ``close(error:)`` runs while the write is held.
    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                if _closed {
                    continuation.resume(throwing: BLESwiftError.l2capChannelClosed)
                } else {
                    _writtenData.append(data)
                    switch _writeBehavior {
                    case .complete: continuation.resume()
                    case .hold: _heldWrites.append(continuation)
                    }
                }
            }
        }
    }

    /// Closes the channel and fails every held write. The first call finishes ``inbound()``, with
    /// `error` if it is not `nil`. Later calls do nothing.
    public func close(error: Error?) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !_closed else { return }
            _closed = true
            _closeError = error
            // Resume every held write. Otherwise its awaiting task outlives the channel.
            let held = _heldWrites
            _heldWrites = []
            for continuation in held { continuation.resume(throwing: BLESwiftError.l2capChannelClosed) }
            if let error {
                inboundContinuation.finish(throwing: error)
            } else {
                inboundContinuation.finish()
            }
        }
    }

    // MARK: - Scripting / inspection

    /// Every `Data` that ``write(_:)`` wrote outbound, in order. Read it with ``onQueue(_:)``.
    public var writtenData: [Data] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _writtenData
    }

    /// Whether ``close(error:)`` has run. Read it with ``onQueue(_:)``.
    public var isClosed: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _closed
    }

    /// The error that ``close(error:)`` received, if any. Read it with ``onQueue(_:)``.
    public var closeError: Error? {
        dispatchPrecondition(condition: .onQueue(queue))
        return _closeError
    }

    /// What ``write(_:)`` does with its data. Get and set it with ``onQueue(_:)``.
    public var writeBehavior: WriteBehavior {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _writeBehavior
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _writeBehavior = newValue
        }
    }

    /// Simulates the peer that sends `data`. It yields the data asynchronously to the ``inbound()``
    /// stream on ``queue``. After the channel is closed, it does nothing. Flush with
    /// ``onQueue(_:)`` (or consume the stream) before you assert.
    public func simulateInbound(_ data: Data) {
        queue.async { [self] in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !_closed else { return }
            inboundContinuation.yield(data)
        }
    }
}
