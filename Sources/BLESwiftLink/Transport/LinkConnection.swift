//
//  LinkConnection.swift
//  BLESwiftLink
//

import Dispatch
import Foundation
import Logging
import Network
import Synchronization

/// A framed message connection over TCP.
///
/// Wraps an `NWConnection` and speaks the ``LinkFraming`` wire format: outgoing messages are
/// encoded with this connection's ``LinkCodec`` and framed; incoming bytes are reassembled and
/// each frame is decoded with the codec named by that frame, so the two ends may use different
/// codecs. Every handler — ``onMessage`` and ``onStateChange`` — is invoked on the `queue`
/// supplied at initialization, never on a caller's thread.
public final class LinkConnection: Sendable {

    /// The lifecycle of a ``LinkConnection``.
    ///
    /// This type is deliberately not `Equatable`: ``failed(_:)`` carries an `NSError`. Match on
    /// it with `if case`.
    public enum State: Sendable {
        /// Created but ``LinkConnection/start()`` has not been called yet.
        case idle
        /// The underlying connection is being established.
        case connecting
        /// The connection is established and messages may be sent and received.
        case ready
        /// The connection ended because of an error: a transport failure, or a framing or
        /// decoding error that makes the byte stream unusable.
        case failed(NSError)
        /// The connection was closed — by ``LinkConnection/cancel()`` or by the remote end.
        case cancelled
    }

    /// Everything mutable, guarded by one lock.
    private struct Storage {
        var state: State = .idle
        var onMessage: (@Sendable (LinkMessage) -> Void)?
        var onStateChange: (@Sendable (State) -> Void)?
        var buffer = Data()
        var isTerminal = false
        var didStart = false
    }

    /// Held across the whole of ``send(_:)`` so frames reach the socket in call order. Separate
    /// from ``storage`` so a send never blocks a state read.
    private struct SendGate {}

    /// Where a message this end refused to frame is reported. Nothing else in the transport
    /// logs: a send that fails locally is the one outcome with no wire event and no completion
    /// of its own, and the size that caused it is what a caller needs to see.
    private static let logger = Logger(label: "BLESwiftLink.LinkConnection")

    private let connection: NWConnection
    private let codec: LinkCodec
    private let queue: DispatchQueue
    private let storage = Mutex(Storage())
    private let sendGate = Mutex(SendGate())

    /// Wraps an existing `NWConnection` — typically one handed to a ``LinkListener``'s
    /// `newConnectionHandler`. Messages and state changes are delivered on `queue`.
    public init(connection: NWConnection, codec: LinkCodec, queue: DispatchQueue) {
        self.connection = connection
        self.codec = codec
        self.queue = queue
    }

    /// Creates an outbound connection to `endpoint`. Call ``start()`` to begin connecting.
    public static func connect(to endpoint: LinkEndpoint, codec: LinkCodec, queue: DispatchQueue) -> LinkConnection {
        let parameters = LinkTransportParameters.tcp()
        let nwEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port) ?? .any
        )
        return LinkConnection(
            connection: NWConnection(to: nwEndpoint, using: parameters),
            codec: codec,
            queue: queue
        )
    }

    /// Called on `queue` for every message decoded from the stream. No message is delivered once
    /// the connection has reached a terminal state.
    public var onMessage: (@Sendable (LinkMessage) -> Void)? {
        get { storage.withLock { $0.onMessage } }
        set { storage.withLock { $0.onMessage = newValue } }
    }

    /// Called on `queue` for every ``State`` transition — including the transitions caused
    /// synchronously by ``start()`` and ``cancel()``, which are dispatched onto `queue` rather
    /// than run on the calling thread. Each transition is published once.
    public var onStateChange: (@Sendable (State) -> Void)? {
        get { storage.withLock { $0.onStateChange } }
        set { storage.withLock { $0.onStateChange = newValue } }
    }

    /// The current lifecycle state.
    public var state: State { storage.withLock { $0.state } }

    /// Starts the underlying connection and, once it is ready, the receive loop. Calling this
    /// more than once has no additional effect.
    public func start() {
        let shouldStart = storage.withLock { storage -> Bool in
            guard !storage.didStart, !storage.isTerminal else { return false }
            storage.didStart = true
            return true
        }
        guard shouldStart else { return }
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(nwState: state)
        }
        transition(to: .connecting)
        connection.start(queue: queue)
    }

    /// Encodes `message` with this connection's codec, frames it, and writes it.
    ///
    /// Frames reach the socket in the order `send` was called: the readiness check, the encode,
    /// and the write are serialized by a dedicated lock, so two callers racing on different
    /// threads still produce a well-ordered stream.
    ///
    /// Messages sent while the connection is not ``State/ready`` are dropped silently: the link
    /// is a best-effort transport and every caller already handles a dropped link.
    ///
    /// A message whose encoded payload is past ``LinkFraming/maximumPayloadLength`` is a
    /// different matter: nothing is written, and this end fails with
    /// ``LinkFramingError/payloadTooLarge(_:)``. The alternative was to write a frame whose
    /// declared length the peer refuses as a protocol violation, which drops the link anyway —
    /// from the far end, with no local record of what caused it. Failing here logs the size.
    public func send(_ message: LinkMessage) {
        let encodeFailure: (any Error)? = sendGate.withLock { _ in
            let isReady = storage.withLock { storage -> Bool in
                if case .ready = storage.state { return true }
                return false
            }
            guard isReady else { return nil }
            do {
                let frame = try LinkFraming.encodeFrame(codec: codec, payload: try codec.encode(message))
                connection.send(content: frame, completion: .contentProcessed { _ in })
                return nil
            } catch {
                return error
            }
        }
        guard let encodeFailure else { return }
        if case LinkFramingError.payloadTooLarge(let size) = encodeFailure {
            Self.logger.error(
                """
                Refusing to send a \(size)-byte payload: the frame cap is \
                \(LinkFraming.maximumPayloadLength) bytes. Failing the connection.
                """
            )
        }
        fail(with: encodeFailure)
    }

    /// Closes the connection. Idempotent; the state becomes ``State/cancelled`` unless the
    /// connection has already ended.
    public func cancel() {
        finish(with: .cancelled)
    }

    // MARK: - Internals

    private func handle(nwState: NWConnection.State) {
        switch nwState {
        case .setup:
            break
        case .preparing:
            transition(to: .connecting)
        case .ready:
            transition(to: .ready)
            receiveNext()
        case .waiting(let error):
            // A link is point-to-point and short-lived: waiting to retry (a refused port, an
            // unreachable host) is a failure, not a state worth sitting in.
            fail(with: error)
        case .failed(let error):
            fail(with: error)
        case .cancelled:
            finish(with: .cancelled)
        @unknown default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.isTerminal else { return }
            if let error {
                self.fail(with: error)
                return
            }
            if let data, !data.isEmpty {
                let frames: [(codec: LinkCodec, payload: Data)]
                do {
                    frames = try self.storage.withLock { storage -> [(codec: LinkCodec, payload: Data)] in
                        storage.buffer.append(data)
                        return try LinkFraming.decodeFrames(from: &storage.buffer)
                    }
                } catch {
                    self.fail(with: error)
                    return
                }
                for frame in frames {
                    let message: LinkMessage
                    do {
                        message = try frame.codec.decode(LinkMessage.self, from: frame.payload)
                    } catch {
                        self.fail(with: error)
                        return
                    }
                    // A cancel racing this receive must win: nothing is delivered after the
                    // connection has ended.
                    let delivery = self.storage.withLock { storage -> (live: Bool, handler: (@Sendable (LinkMessage) -> Void)?) in
                        (!storage.isTerminal, storage.onMessage)
                    }
                    guard delivery.live else { return }
                    if let handler = delivery.handler {
                        self.queue.async { handler(message) }
                    }
                }
            }
            if isComplete {
                // The remote end closed cleanly.
                self.finish(with: .cancelled)
                return
            }
            self.receiveNext()
        }
    }

    /// Whether the connection has already reached ``State/failed(_:)`` or ``State/cancelled``.
    private var isTerminal: Bool { storage.withLock { $0.isTerminal } }

    private func fail(with error: some Error) {
        finish(with: .failed(error as NSError))
    }

    /// Moves to a terminal state exactly once, cancels the underlying connection, and publishes
    /// the transition on `queue`.
    ///
    /// Both handlers are released here, after the one being published has been copied out. A
    /// handler stored into a connection routinely captures that same connection strongly —
    /// `LinkClientSession.dial()` does — which is a retain cycle nothing else breaks, and a
    /// client redialing a dead provider every couple of seconds would leak one
    /// ``LinkConnection`` and its `NWConnection` per attempt.
    private func finish(with terminal: State) {
        let outcome = storage.withLock { storage -> (published: Bool, handler: (@Sendable (State) -> Void)?) in
            guard !storage.isTerminal else { return (false, nil) }
            storage.isTerminal = true
            storage.state = terminal
            storage.buffer = Data()
            let handler = storage.onStateChange
            storage.onMessage = nil
            storage.onStateChange = nil
            return (true, handler)
        }
        guard outcome.published else { return }
        connection.cancel()
        if let handler = outcome.handler {
            queue.async { handler(terminal) }
        }
    }

    /// Publishes a non-terminal transition on `queue`, ignoring it once the connection has ended.
    private func transition(to newState: State) {
        let handler = storage.withLock { storage -> (@Sendable (State) -> Void)? in
            guard !storage.isTerminal else { return nil }
            switch (storage.state, newState) {
            case (.connecting, .connecting), (.ready, .ready):
                return nil
            default:
                break
            }
            storage.state = newState
            return storage.onStateChange
        }
        if let handler {
            queue.async { handler(newState) }
        }
    }
}
