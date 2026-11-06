//
//  LinkListener.swift
//  BLESwiftLink
//

import Dispatch
import Foundation
import Network
import BLESwiftCompat17

/// TCP parameters that ``LinkConnection`` and ``LinkListener`` share.
enum LinkTransportParameters {
    /// TCP with Nagle disabled. A link carries small notifications that need low latency.
    static func tcp() -> NWParameters {
        let parameters = NWParameters.tcp
        if let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            options.noDelay = true
        }
        return parameters
    }

    /// The family of a loopback address.
    enum Loopback {
        case ipv4
        case ipv6
    }

    /// The loopback address family that `host` names, or `nil` if `host` names something else. In
    /// that case a listener binds every interface.
    ///
    /// These hosts are recognized:
    ///
    /// - `localhost`. A ``LinkEndpoint`` normalizes it before a listener sees it, so this case
    ///   matters only for a host string that arrived by another route.
    /// - Anything in `127.0.0.0/8`, not only `127.0.0.1`.
    /// - The IPv6 loopback `::1`, with or without brackets.
    static func loopback(_ host: String) -> Loopback? {
        switch host {
        case "localhost":
            return .ipv4
        case "::1", "[::1]":
            return .ipv6
        default:
            return isIPv4Loopback(host) ? .ipv4 : nil
        }
    }

    /// Whether `host` names the loopback interface. In that case a listener binds only there.
    static func isLoopback(_ host: String) -> Bool {
        loopback(host) != nil
    }

    /// Whether `host` is a dotted quad inside `127.0.0.0/8`.
    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        // `UInt8.init` alone would accept a signed `"+1"`, so also check the digits.
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && UInt8(part) != nil
        }
    }
}

/// The reason why a ``LinkListener`` refused an action.
public enum LinkListenerError: Error, Equatable, Sendable {
    /// The caller called ``LinkListener/start()`` more than once on the same listener.
    case alreadyStarted
}

/// Accepts framed message connections on a TCP port.
///
/// The listener wraps each accepted connection in a ``LinkConnection``, starts it, and gives it to
/// ``onConnection`` on the `queue` from the initializer.
///
/// If the host is a loopback host, the listener binds to the loopback interface only. A loopback
/// host is any `127.x.y.z` or `::1`, with or without brackets. `::1` binds the IPv6 loopback.
/// Any other host binds every interface on the port.
///
/// A ``LinkEndpoint`` stores `localhost` as `127.0.0.1`, so a listener and a client that get the
/// same host string always use the same loopback family.
public final class LinkListener: Sendable {

    /// All mutable state. One lock guards it.
    private struct Storage {
        var onConnection: (@Sendable (LinkConnection) -> Void)?
        var port: UInt16 = 0
        var startContinuation: CheckedContinuation<Void, any Error>?
        var didStart = false
        /// Set when the awaiting task is cancelled. A `start()` that has not yet stored its
        /// continuation then fails at once.
        var isCancelled = false
    }

    private let listener: NWListener
    private let codec: LinkCodec
    private let queue: DispatchQueue
    private let storage = Mutex(Storage())

    /// Creates a listener for `endpoint`. For a system-chosen free port, use port `0` and read
    /// ``port`` after ``start()`` returns. Throws if the system rejects the parameters or the
    /// port.
    public init(endpoint: LinkEndpoint, codec: LinkCodec, queue: DispatchQueue) throws {
        let parameters = LinkTransportParameters.tcp()
        let port = NWEndpoint.Port(rawValue: endpoint.port) ?? .any
        switch LinkTransportParameters.loopback(endpoint.host) {
        case .some(let family):
            // `requiredLocalEndpoint` already names the port. A port that is also passed to `on:`
            // gives EINVAL, so the loopback path binds through the parameters only.
            let host: NWEndpoint.Host = family == .ipv6 ? .ipv6(.loopback) : .ipv4(.loopback)
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
            self.listener = try NWListener(using: parameters)
        case .none:
            self.listener = try NWListener(using: parameters, on: port)
        }
        self.codec = codec
        self.queue = queue
    }

    /// Called on `queue` with each accepted connection. The connection is already started.
    public var onConnection: (@Sendable (LinkConnection) -> Void)? {
        get { storage.withLock { $0.onConnection } }
        set { storage.withLock { $0.onConnection = newValue } }
    }

    /// The bound port. The value is `0` until ``start()`` returns.
    public var port: UInt16 { storage.withLock { $0.port } }

    /// Starts to listen. Returns when the port is bound, so ``port`` is valid on return.
    ///
    /// **This function is cancellable.** If the awaiting task is cancelled, including a task that
    /// was already cancelled when it called, the listener is cancelled and this call fails with
    /// `CancellationError`. Without this, a caller that races the bind against a timeout would
    /// keep a listener that it does not know about. The resumption is one-shot, so a cancellation
    /// that arrives with the listener's `.ready` or `.failed` does no harm.
    ///
    /// - Throws:
    ///   - ``LinkListenerError/alreadyStarted`` if the listener was already started.
    ///   - `CancellationError` if the awaiting task is cancelled.
    ///   - The `NWError` that the listener reports if it fails or must wait to bind. A port that
    ///     is in use is a failure. The function does not wait and retry.
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
            // If the task was cancelled before this code ran, `onCancel` already fired against an
            // empty continuation slot and nothing would resume this continuation. Fail it here.
            // The listener does not start.
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
                    // The bind is one-shot. If the port is in use, `start()` must fail and not wait
                    // for a retry that may never succeed.
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

    /// Cancels the listener and fails a pending ``start()`` with `CancellationError`. It is safe
    /// to call before the continuation exists, because the flag makes ``bind()`` fail at once.
    private func cancelStart() {
        storage.withLock { $0.isCancelled = true }
        resumeStart(throwing: CancellationError())
    }

    /// Stops the listener. Connections that it already accepted stay open. Repeated calls have no
    /// effect.
    public func cancel() {
        listener.cancel()
    }

    // MARK: - Internals

    /// Fails a pending ``start()``, if one is waiting, and tears down the listener.
    private func resumeStart(throwing error: some Error) {
        listener.cancel()
        storage.withLock { storage -> CheckedContinuation<Void, any Error>? in
            defer { storage.startContinuation = nil }
            return storage.startContinuation
        }?.resume(throwing: error)
    }
}
