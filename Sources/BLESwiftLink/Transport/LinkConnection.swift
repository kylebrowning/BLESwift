//
//  LinkConnection.swift
//  BLESwiftLink
//

import Dispatch
import Foundation
import Logging
import Network
import BLESwiftCompat17

/// A framed message connection over TCP.
///
/// The connection wraps an `NWConnection` and uses the ``LinkFraming`` wire format.
///
/// - The connection encodes each outgoing message with its own ``LinkCodec`` and frames it.
/// - The connection reassembles incoming bytes and decodes each frame with the codec that the
///   frame names, so the two ends can use different codecs.
///
/// The connection calls ``onMessage`` and ``onStateChange`` on the `queue` from the initializer,
/// never on a caller's thread.
public final class LinkConnection: Sendable {

    /// The lifecycle of a ``LinkConnection``.
    ///
    /// This type is not `Equatable` on purpose, because ``failed(_:)`` carries an `NSError`. Use
    /// `if case` to match on it.
    public enum State: Sendable {
        /// The connection exists but the caller did not yet call ``LinkConnection/start()``.
        case idle
        /// The underlying connection is connecting.
        case connecting
        /// The connection can send and receive messages.
        case ready
        /// The connection ended because of an error: a transport failure, or a framing or decoding
        /// error that makes the byte stream unusable.
        case failed(NSError)
        /// The connection closed. ``LinkConnection/cancel()`` or the remote end closed it.
        case cancelled
    }

    /// All mutable state. One lock guards it.
    private struct Storage {
        var state: State = .idle
        var onMessage: (@Sendable (LinkMessage) -> Void)?
        var onStateChange: (@Sendable (State) -> Void)?
        var buffer = Data()
        var isTerminal = false
        var didStart = false
    }

    /// Held for the whole of ``send(_:)``, so frames reach the socket in call order. Separate from
    /// ``storage``, so a send never blocks a state read.
    private struct SendGate {}

    /// Reports a message that this end refused to frame. Nothing else in the transport logs. A
    /// send that fails locally has no wire event, so the size that caused the failure needs a
    /// log line.
    private static let logger = Logger(label: "BLESwiftLink.LinkConnection")

    private let connection: NWConnection
    private let codec: LinkCodec
    private let queue: DispatchQueue
    private let storage = Mutex(Storage())
    private let sendGate = Mutex(SendGate())

    /// Wraps an existing `NWConnection`, typically one that a ``LinkListener`` accepted. The
    /// connection delivers messages and state changes on `queue`.
    public init(connection: NWConnection, codec: LinkCodec, queue: DispatchQueue) {
        self.connection = connection
        self.codec = codec
        self.queue = queue
    }

    /// Creates an outbound connection to `endpoint`. Call ``start()`` to begin it.
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

    /// Called on `queue` for every message decoded from the stream. After the connection reaches
    /// a terminal state, it delivers no message.
    public var onMessage: (@Sendable (LinkMessage) -> Void)? {
        get { storage.withLock { $0.onMessage } }
        set { storage.withLock { $0.onMessage = newValue } }
    }

    /// Called on `queue` for every ``State`` transition, including the transitions that
    /// ``start()`` and ``cancel()`` cause. The connection dispatches each transition onto `queue`
    /// and publishes it once.
    public var onStateChange: (@Sendable (State) -> Void)? {
        get { storage.withLock { $0.onStateChange } }
        set { storage.withLock { $0.onStateChange = newValue } }
    }

    /// The current lifecycle state.
    public var state: State { storage.withLock { $0.state } }

    /// Starts the underlying connection. When the connection is ready, it starts the receive
    /// loop. Calls after the first have no effect.
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
    /// Frames reach the socket in the order of the `send` calls. A dedicated lock serializes the
    /// readiness check, the encode, and the write, so callers on different threads still produce
    /// an ordered stream.
    ///
    /// If the connection is not ``State/ready``, it drops the message silently. The link is a
    /// best-effort transport, and every caller already handles a dropped link.
    ///
    /// If the encoded payload is larger than ``LinkFraming/maximumPayloadLength``, the connection
    /// writes nothing, logs the size, and fails with ``LinkFramingError/payloadTooLarge(_:)``.
    /// This keeps a local record of the cause. A frame with an illegal length would make the peer
    /// drop the link as a protocol violation, with no local record.
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

    /// Closes the connection. The state becomes ``State/cancelled`` unless the connection already
    /// ended. Repeated calls have no effect.
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
            // A link is point-to-point and short-lived. A connection that must wait to retry, for
            // example after a refused port or an unreachable host, counts as a failure.
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
                    // A cancel that races this receive must win: deliver nothing after the end.
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
                // The remote end closed the connection cleanly.
                self.finish(with: .cancelled)
                return
            }
            self.receiveNext()
        }
    }

    /// Whether the connection reached ``State/failed(_:)`` or ``State/cancelled``.
    private var isTerminal: Bool { storage.withLock { $0.isTerminal } }

    private func fail(with error: some Error) {
        finish(with: .failed(error as NSError))
    }

    /// Moves to a terminal state once, cancels the underlying connection, and publishes the
    /// transition on `queue`.
    ///
    /// The function releases both handlers here, after it copies out the handler that it
    /// publishes. A stored handler usually captures its connection strongly (as
    /// `LinkClientSession.dial()` does), which is a retain cycle that nothing else breaks. A
    /// client that redials a dead provider every few seconds would leak one ``LinkConnection``
    /// and its `NWConnection` for each attempt.
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

    /// Publishes a non-terminal transition on `queue`. After the connection ends, it ignores the
    /// transition.
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
