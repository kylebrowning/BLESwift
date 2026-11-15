//
//  VirtualL2CAPChannel.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import BLESwiftLink
import Foundation
import BLESwiftCompat17

/// One end of an in-memory L2CAP channel on a ``VirtualRadio``. ``pair(psm:)`` makes the two ends.
/// The radio gives the central end to the `Central` that opened the channel, and the host end to
/// the device's ``VirtualL2CAPAccepting`` handler.
///
/// **Concurrency.** One `Mutex` that both ends share holds all the state. The channel uses no
/// queues and no tasks, so you can call it from any isolation domain.
///
/// **Flow control.** Each direction has a FIFO of `Data` chunks. A write suspends while the
/// peer's FIFO holds ``BLESwiftLink/LinkFlowControl/l2capInitialCredit`` bytes or more. The
/// write then adds its whole `Data` to the FIFO. The FIFO shrinks when the consumer of the peer's
/// ``inbound()`` stream takes a chunk. Waiting writers resume in arrival order.
///
/// **Teardown.** The pair closes once. Every later close does nothing. Data that is already in
/// a FIFO reaches the reader before the stream ends.
/// - ``close(error:)`` with `nil` is a graceful close. Both streams finish cleanly.
/// - ``close(error:)`` with an error is an abort. The caller's own stream throws that error. The
///   peer's stream throws ``BLESwiftCore/BLESwiftError/l2capChannelClosed``.
/// - ``fail(_:)`` is a teardown that the radio starts. Both streams throw the error.
///
/// Pending writers on both ends throw ``BLESwiftCore/BLESwiftError/l2capChannelClosed`` after a
/// close, or the error of ``fail(_:)``.
package final class VirtualL2CAPChannel: L2CAPChannelRemote, Sendable {

    /// The PSM that the central opened.
    package let psm: L2CAPPSM

    /// The state that both ends share.
    private let shared: Shared

    /// The index of this end in ``Shared/State/inbounds``. The peer has the other index.
    private let side: Int

    private init(psm: L2CAPPSM, shared: Shared, side: Int) {
        self.psm = psm
        self.shared = shared
        self.side = side
    }

    /// Creates the two connected ends of a new channel on `psm`.
    package static func pair(psm: L2CAPPSM) -> (central: VirtualL2CAPChannel, host: VirtualL2CAPChannel) {
        let shared = Shared()
        return (
            VirtualL2CAPChannel(psm: psm, shared: shared, side: 0),
            VirtualL2CAPChannel(psm: psm, shared: shared, side: 1)
        )
    }

    /// The index of the peer end.
    private var peer: Int { 1 - side }

    /// Whether the pair is closed or failed. This is a snapshot.
    package var isClosed: Bool {
        shared.state.withLock { $0.closed }
    }

    // MARK: - L2CAPChannelRemote

    /// The stream of the data that the peer writes. The first call returns the stream. Data that
    /// the peer wrote before this call is in the FIFO and arrives first. A second call returns a
    /// stream that finishes at once.
    package func inbound() -> AsyncThrowingStream<Data, Error> {
        let first = shared.state.withLock { state -> Bool in
            guard !state.inbounds[side].isTaken else { return false }
            state.inbounds[side].isTaken = true
            return true
        }
        guard first else {
            return AsyncThrowingStream { $0.finish() }
        }
        let shared = self.shared
        let side = self.side
        return AsyncThrowingStream(unfolding: { try await shared.next(side: side) })
    }

    /// Adds `data` to the peer's FIFO. It suspends while the peer's FIFO is full.
    ///
    /// - Throws: ``BLESwiftCore/BLESwiftError/l2capChannelClosed`` if the pair is closed, or
    ///   when a close runs while the write waits. The error of ``fail(_:)`` if the radio fails the
    ///   pair while the write waits. ``BLESwiftCore/BLESwiftError/operationCancelled`` if the
    ///   calling task is cancelled while the write waits.
    package func write(_ data: Data) async throws {
        try await shared.write(data, into: peer)
    }

    /// Closes the pair. See the type's teardown rules. It is idempotent for the pair.
    package func close(error: Error?) {
        let closer = side
        shared.terminate { index in
            if index == closer {
                return error.map { .failed($0) } ?? .finished
            }
            return error == nil ? .finished : .failed(BLESwiftError.l2capChannelClosed)
        } writerError: { BLESwiftError.l2capChannelClosed }
    }

    /// Fails the pair with `error`, as a teardown that the radio starts (for example a
    /// disconnect). Both streams deliver their buffered data and then throw `error`. Pending
    /// writers on both ends throw `error`. It does nothing if the pair is already closed.
    package func fail(_ error: Error) {
        shared.terminate { _ in .failed(error) } writerError: { error }
    }
}

extension VirtualL2CAPChannel {

    /// How a stream ends after its FIFO is empty.
    fileprivate enum Terminal {
        case finished
        case failed(Error)
    }

    /// One writer that waits for space in a FIFO.
    fileprivate struct Writer {
        let token: UInt64
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    /// One direction of the pair: the FIFO that one end reads.
    fileprivate struct Inbound {
        /// The chunks that wait for the reader. The chunks before ``head`` are already taken.
        var chunks: [Data] = []
        var head = 0
        /// The bytes in the chunks that wait for the reader.
        var bufferedBytes = 0
        /// The reader's `next()` that waits for a chunk.
        var reader: CheckedContinuation<Data?, Error>?
        /// The writers that wait for space, in arrival order.
        var writers: [Writer] = []
        /// How the stream ends. It is `nil` while the pair is open.
        var terminal: Terminal?
        /// Whether ``VirtualL2CAPChannel/inbound()`` already returned the stream.
        var isTaken = false

        var hasChunk: Bool { head < chunks.count }

        /// Takes the oldest chunk and lowers ``bufferedBytes``.
        mutating func takeChunk() -> Data {
            let chunk = chunks[head]
            head += 1
            bufferedBytes -= chunk.count
            if head == chunks.count {
                chunks.removeAll(keepingCapacity: true)
                head = 0
            } else if head > 64, head * 2 > chunks.count {
                chunks.removeFirst(head)
                head = 0
            }
            return chunk
        }

        /// Adds `data` to the FIFO.
        mutating func append(_ data: Data) {
            chunks.append(data)
            bufferedBytes += data.count
        }
    }

    /// A resume to run after the lock is released.
    fileprivate enum Resume {
        case reader(CheckedContinuation<Data?, Error>, Result<Data?, Error>)
        case writer(CheckedContinuation<Void, Error>, Result<Void, Error>)

        func run() {
            switch self {
            case let .reader(continuation, result): continuation.resume(with: result)
            case let .writer(continuation, result): continuation.resume(with: result)
            }
        }
    }

    /// The state that both ends share, in one `Mutex`.
    fileprivate final class Shared: Sendable {

        struct State {
            /// Index 0 is what the central end reads. Index 1 is what the host end reads.
            var inbounds = [Inbound(), Inbound()]
            /// Whether a close or a fail already ran.
            var closed = false
            /// The allocator for writer tokens.
            var nextToken: UInt64 = 0
        }

        let state = Mutex(State())

        /// The byte limit of one FIFO.
        private static let limit = LinkFlowControl.l2capInitialCredit

        /// Moves data in `inbound` as far as it can go. It admits waiting writers while the FIFO
        /// is below the limit, and gives a chunk or the end of the stream to a waiting reader.
        private static func settle(_ inbound: inout Inbound, into resumes: inout [Resume]) {
            while true {
                while inbound.terminal == nil, inbound.bufferedBytes < limit, !inbound.writers.isEmpty {
                    let writer = inbound.writers.removeFirst()
                    inbound.append(writer.data)
                    resumes.append(.writer(writer.continuation, .success(())))
                }
                guard let reader = inbound.reader else { return }
                if inbound.hasChunk {
                    inbound.reader = nil
                    resumes.append(.reader(reader, .success(inbound.takeChunk())))
                    continue
                }
                if let terminal = inbound.terminal {
                    inbound.reader = nil
                    switch terminal {
                    case .finished: resumes.append(.reader(reader, .success(nil)))
                    case .failed(let error): resumes.append(.reader(reader, .failure(error)))
                    }
                }
                return
            }
        }

        /// The `next()` of the stream of inbound `side`. It returns `nil` at a clean end, or if
        /// the consuming task is cancelled.
        func next(side: Int) async throws -> Data? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                    var resumes: [Resume] = []
                    state.withLock { state in
                        if Task.isCancelled, !state.inbounds[side].hasChunk {
                            resumes.append(.reader(continuation, .success(nil)))
                            return
                        }
                        state.inbounds[side].reader = continuation
                        Self.settle(&state.inbounds[side], into: &resumes)
                    }
                    resumes.forEach { $0.run() }
                }
            } onCancel: {
                let reader = state.withLock { state -> CheckedContinuation<Data?, Error>? in
                    defer { state.inbounds[side].reader = nil }
                    return state.inbounds[side].reader
                }
                reader?.resume(returning: nil)
            }
        }

        /// Adds `data` to inbound `target`, and waits for space if the FIFO is full or other
        /// writers wait.
        func write(_ data: Data, into target: Int) async throws {
            let token: UInt64? = try state.withLock { state in
                guard !state.closed else { throw BLESwiftError.l2capChannelClosed }
                guard !data.isEmpty else { return nil }
                state.nextToken += 1
                return state.nextToken
            }
            guard let token else { return }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    var resumes: [Resume] = []
                    state.withLock { state in
                        guard !state.closed else {
                            resumes.append(.writer(continuation, .failure(BLESwiftError.l2capChannelClosed)))
                            return
                        }
                        let mustWait = !state.inbounds[target].writers.isEmpty
                            || state.inbounds[target].bufferedBytes >= Self.limit
                        if mustWait, Task.isCancelled {
                            resumes.append(.writer(continuation, .failure(BLESwiftError.operationCancelled)))
                            return
                        }
                        state.inbounds[target].writers.append(Writer(token: token, data: data, continuation: continuation))
                        Self.settle(&state.inbounds[target], into: &resumes)
                    }
                    resumes.forEach { $0.run() }
                }
            } onCancel: {
                let writer = state.withLock { state -> Writer? in
                    guard let index = state.inbounds[target].writers.firstIndex(where: { $0.token == token }) else { return nil }
                    return state.inbounds[target].writers.remove(at: index)
                }
                writer?.continuation.resume(throwing: BLESwiftError.operationCancelled)
            }
        }

        /// Closes the pair once. `terminal` gives the end of each inbound. Every waiting writer
        /// throws `writerError()`. A waiting reader with an empty FIFO receives its end at once.
        func terminate(_ terminal: (Int) -> Terminal, writerError: () -> Error) {
            var resumes: [Resume] = []
            state.withLock { state in
                guard !state.closed else { return }
                state.closed = true
                for index in state.inbounds.indices {
                    state.inbounds[index].terminal = terminal(index)
                    for writer in state.inbounds[index].writers {
                        resumes.append(.writer(writer.continuation, .failure(writerError())))
                    }
                    state.inbounds[index].writers.removeAll()
                    Self.settle(&state.inbounds[index], into: &resumes)
                }
            }
            resumes.forEach { $0.run() }
        }
    }
}
