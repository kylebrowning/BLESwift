//
//  LinkListener.swift
//  BLESwiftLink
//

import Dispatch
import Foundation
import Network
import Synchronization

/// TCP parameters shared by ``LinkConnection`` and ``LinkListener``.
enum LinkTransportParameters {
    /// TCP with Nagle disabled — a link carries small, latency-sensitive notifications.
    static func tcp() -> NWParameters {
        let parameters = NWParameters.tcp
        if let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            options.noDelay = true
        }
        return parameters
    }

    /// `true` when `host` names the loopback interface, in which case a listener binds only there.
    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost"
    }
}

/// Why a ``LinkListener`` refused to do something.
public enum LinkListenerError: Error, Equatable, Sendable {
    /// ``LinkListener/start()`` was called more than once on the same listener.
    case alreadyStarted
}

/// Accepts framed message connections on a TCP port.
///
/// Each accepted connection is wrapped in a ``LinkConnection``, started, and handed to
/// ``onConnection`` on the `queue` supplied at initialization. Binding to `127.0.0.1` or
/// `localhost` restricts the listener to the loopback interface; any other host binds every
/// interface on the port.
public final class LinkListener: Sendable {

    /// Everything mutable, guarded by one lock.
    private struct Storage {
        var onConnection: (@Sendable (LinkConnection) -> Void)?
        var port: UInt16 = 0
        var startContinuation: CheckedContinuation<Void, any Error>?
        var didStart = false
        /// Set once the awaiting task is cancelled, so a `start()` that has not yet stored its
        /// continuation fails immediately rather than waiting on a listener already cancelled.
        var isCancelled = false
    }

    private let listener: NWListener
    private let codec: LinkCodec
    private let queue: DispatchQueue
    private let storage = Mutex(Storage())

    /// Creates a listener for `endpoint`. Use port `0` to have the system pick a free port, then
    /// read ``port`` after ``start()`` returns. Throws if the parameters or port are rejected.
    public init(endpoint: LinkEndpoint, codec: LinkCodec, queue: DispatchQueue) throws {
        let parameters = LinkTransportParameters.tcp()
        let port = NWEndpoint.Port(rawValue: endpoint.port) ?? .any
        if LinkTransportParameters.isLoopback(endpoint.host) {
            // `requiredLocalEndpoint` already names the port; passing it to `on:` as well is
            // rejected as EINVAL, so the loopback path binds through the parameters alone.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            self.listener = try NWListener(using: parameters)
        } else {
            self.listener = try NWListener(using: parameters, on: port)
        }
        self.codec = codec
        self.queue = queue
    }

    /// Called on `queue` with each accepted connection, already started.
    public var onConnection: (@Sendable (LinkConnection) -> Void)? {
        get { storage.withLock { $0.onConnection } }
        set { storage.withLock { $0.onConnection = newValue } }
    }

    /// The port the listener is bound to. Valid only after ``start()`` has returned; `0` before
    /// that.
    public var port: UInt16 { storage.withLock { $0.port } }

    /// Starts listening and returns once the port is bound, so ``port`` is valid on return.
    ///
    /// **Cancellable.** Cancelling the awaiting task cancels the listener and fails this call
    /// with `CancellationError`, including when the task was already cancelled on the way in —
    /// binding is otherwise the one step of provider startup with nothing to interrupt it, and
    /// a caller racing a bind against a timeout would be left holding a listener it never
    /// learned about. The resumption is one-shot, so a cancellation landing alongside the
    /// listener's own `.ready` or `.failed` is harmless.
    ///
    /// - Throws: ``LinkListenerError/alreadyStarted`` if the listener was already started,
    ///   `CancellationError` if the awaiting task is cancelled, or the `NWError` reported by
    ///   the listener if it fails or has to wait to bind — a port already in use is a failure
    ///   here, never something to sit and retry.
    public func start() async throws {
        try storage.withLock { storage in
            guard !storage.didStart else { throw LinkListenerError.alreadyStarted }
            storage.didStart = true
        }
        try await withTaskCancellationHandler {
            try await bind()
        } onCancel: {
            cancelStart()
        }
    }

    /// Binds the listener and suspends until it is ready, fails, or is cancelled.
    private func bind() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // A task cancelled before this ran already had `onCancel` fire against an empty
            // continuation slot; nothing would ever resume this one, so it is failed here
            // instead — and the listener is not started at all.
            let wasCancelled = storage.withLock { storage -> Bool in
                guard !storage.isCancelled else { return true }
                storage.startContinuation = continuation
                return false
            }
            guard !wasCancelled else {
                listener.cancel()
                continuation.resume(throwing: CancellationError())
                return
            }
            listener.newConnectionHandler = { [weak self] nwConnection in
                guard let self else {
                    nwConnection.cancel()
                    return
                }
                let connection = LinkConnection(connection: nwConnection, codec: self.codec, queue: self.queue)
                let handler = self.storage.withLock { $0.onConnection }
                connection.start()
                handler?(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let boundPort = self.listener.port?.rawValue ?? 0
                    self.storage.withLock { storage -> CheckedContinuation<Void, any Error>? in
                        storage.port = boundPort
                        defer { storage.startContinuation = nil }
                        return storage.startContinuation
                    }?.resume()
                case .waiting(let error):
                    // Binding is one-shot: a port already in use must fail `start()` rather than
                    // leave the caller awaiting a retry that may never succeed.
                    self.resumeStart(throwing: error as NSError)
                case .failed(let error):
                    self.resumeStart(throwing: error as NSError)
                case .cancelled:
                    self.resumeStart(throwing: NWError.posix(.ECANCELED))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Cancels the listener and fails a pending ``start()`` with `CancellationError`. Safe
    /// before the continuation exists: the flag makes ``bind()`` fail on sight.
    private func cancelStart() {
        storage.withLock { $0.isCancelled = true }
        resumeStart(throwing: CancellationError())
    }

    /// Stops listening. Already-accepted connections are unaffected. Idempotent.
    public func cancel() {
        listener.cancel()
    }

    // MARK: - Internals

    /// Fails a pending ``start()``, if one is still waiting, and tears the listener down.
    private func resumeStart(throwing error: some Error) {
        listener.cancel()
        storage.withLock { storage -> CheckedContinuation<Void, any Error>? in
            defer { storage.startContinuation = nil }
            return storage.startContinuation
        }?.resume(throwing: error)
    }
}
