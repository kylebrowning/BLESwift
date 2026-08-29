//
//  LinkClientSession.swift
//  BLESwiftSimulatorLink
//

import BLESwiftLink
import Dispatch
import Foundation
import Synchronization

/// The client half of a link: dials a provider, performs the handshake, and reconnects.
///
/// A session owns one ``LinkConnection`` at a time. ``start()`` dials the endpoint; once the
/// connection is ready the session sends a `ClientHello` and waits for the provider's
/// `ServerHello`, which must be the first message it receives. A hello that is accepted and
/// speaks ``LinkProtocol/version`` makes the session connected — ``onConnected`` fires and
/// subsequent messages are delivered to ``onMessage``. Anything else ends the connection:
///
/// - A transport failure or a refused dial retries after `retryInterval`.
/// - A rejected hello reports `LinkError.handshakeRejected` and retries.
/// - A protocol version mismatch reports `LinkError.protocolVersionMismatch` and never retries:
///   a provider speaking another version will not become compatible by trying again.
///
/// Every handler is invoked on the `queue` supplied at initialization, which is also the queue
/// the underlying connection delivers on, so callbacks arrive in order and never reentrantly.
package final class LinkClientSession: Sendable {

    /// Everything mutable, guarded by one lock.
    private struct State {
        /// The connection currently owned by the session. Held strongly: nothing else retains a
        /// ``LinkConnection``, and its receive loop keeps only a weak reference to itself.
        var connection: LinkConnection?
        var isConnected = false
        var stopped = false
        var didStart = false
        var handshakeComplete = false
        /// Set once a provider answers with a different protocol version; suppresses all retries.
        var versionMismatch = false
        var retryScheduled = false
        var onConnected: (@Sendable () -> Void)?
        var onDisconnected: (@Sendable (NSError?) -> Void)?
        var onMessage: (@Sendable (LinkMessage) -> Void)?
        /// See `LinkClientSession.onDial`.
        var onDial: (@Sendable (LinkConnection) -> Void)?
    }

    /// What a `ServerHello` means for the session, decided under the lock and acted on outside it.
    private enum HandshakeOutcome {
        case accepted
        case rejected(NSError)
        case ignored
    }

    private let endpoint: LinkEndpoint
    private let role: LinkRole
    private let clientName: String
    private let codec: LinkCodec
    private let queue: DispatchSerialQueue
    private let retryInterval: Duration
    private let state = Mutex(State())

    /// Creates a session that will dial `endpoint` and identify itself as `role`.
    ///
    /// - Parameters:
    ///   - endpoint: The provider's host and port.
    ///   - role: Which side of the link this client drives.
    ///   - clientName: A human-readable name sent in the hello, for provider-side logging.
    ///   - codec: The codec used to encode outgoing messages.
    ///   - queue: The serial queue every callback is delivered on — the owning actor's queue.
    ///   - retryInterval: How long to wait before redialing after a failure.
    package init(
        endpoint: LinkEndpoint,
        role: LinkRole,
        clientName: String,
        codec: LinkCodec = .binaryPropertyList,
        queue: DispatchSerialQueue,
        retryInterval: Duration = .seconds(2)
    ) {
        self.endpoint = endpoint
        self.role = role
        self.clientName = clientName
        self.codec = codec
        self.queue = queue
        self.retryInterval = retryInterval
    }

    /// Called on `queue` once a provider has accepted the handshake, for every connection.
    package var onConnected: (@Sendable () -> Void)? {
        get { state.withLock { $0.onConnected } }
        set { state.withLock { $0.onConnected = newValue } }
    }

    /// Called on `queue` when a connected link drops — with `LinkError.providerDisconnected` —
    /// or when a provider refuses the handshake, with the refusal's error. A dial that never
    /// completed a handshake does not report a disconnect; it is simply retried.
    package var onDisconnected: (@Sendable (NSError?) -> Void)? {
        get { state.withLock { $0.onDisconnected } }
        set { state.withLock { $0.onDisconnected = newValue } }
    }

    /// Called on `queue` for every message received after the handshake completed.
    package var onMessage: (@Sendable (LinkMessage) -> Void)? {
        get { state.withLock { $0.onMessage } }
        set { state.withLock { $0.onMessage = newValue } }
    }

    /// Whether a provider has accepted the handshake and the link is live.
    package var isConnected: Bool { state.withLock { $0.isConnected } }

    /// Called on the dialling thread with every connection a dial creates.
    ///
    /// Not API: it exists so a test can take a `weak` reference to what a dial created and
    /// assert that reaching a terminal state actually releases it.
    package var onDial: (@Sendable (LinkConnection) -> Void)? {
        get { state.withLock { $0.onDial } }
        set { state.withLock { $0.onDial = newValue } }
    }

    /// Dials the endpoint and begins the connect-and-retry loop. Calling this more than once has
    /// no additional effect, and it does nothing after ``stop()``.
    package func start() {
        let shouldDial = state.withLock { state -> Bool in
            guard !state.didStart, !state.stopped else { return false }
            state.didStart = true
            return true
        }
        guard shouldDial else { return }
        dial()
    }

    /// Tears the session down: the current connection is cancelled, no retry is scheduled, and no
    /// further callback is delivered. Idempotent.
    package func stop() {
        let connection = state.withLock { state -> LinkConnection? in
            state.stopped = true
            state.isConnected = false
            state.handshakeComplete = false
            defer { state.connection = nil }
            return state.connection
        }
        connection?.cancel()
    }

    /// Sends `message` to the provider.
    ///
    /// Messages sent while the session is not connected are dropped silently: the link is a
    /// best-effort transport, and every caller already handles a dropped link.
    package func send(_ message: LinkMessage) {
        let connection = state.withLock { state -> LinkConnection? in
            guard state.isConnected, !state.stopped else { return nil }
            return state.connection
        }
        connection?.send(message)
    }

    // MARK: - Connecting

    /// Creates, stores, and starts a connection. Called from ``start()`` and from the retry timer.
    private func dial() {
        let connection = LinkConnection.connect(to: endpoint, codec: codec, queue: queue)
        let outcome = state.withLock { state -> (Bool, (@Sendable (LinkConnection) -> Void)?) in
            guard !state.stopped, !state.versionMismatch else { return (false, nil) }
            state.connection = connection
            state.isConnected = false
            state.handshakeComplete = false
            return (true, state.onDial)
        }
        guard outcome.0 else { return }
        outcome.1?(connection)
        connection.onStateChange = { [weak self] connectionState in
            self?.handle(connectionState: connectionState, from: connection)
        }
        connection.onMessage = { [weak self] message in
            self?.handle(message: message, from: connection)
        }
        connection.start()
    }

    private func handle(connectionState: LinkConnection.State, from connection: LinkConnection) {
        switch connectionState {
        case .idle, .connecting:
            break
        case .ready:
            sendHello(over: connection)
        case .failed, .cancelled:
            handleTermination(of: connection)
        }
    }

    private func sendHello(over connection: LinkConnection) {
        let isCurrent = state.withLock { state in !state.stopped && state.connection === connection }
        guard isCurrent else { return }
        connection.send(.clientHello(ClientHello(protocolVersion: LinkProtocol.version, role: role, clientName: clientName)))
    }

    /// Ends the session's interest in `connection`, reporting a disconnect if the link had been
    /// connected, and schedules the next dial unless the session is stopped or incompatible.
    private func handleTermination(of connection: LinkConnection) {
        let report = state.withLock { state -> (@Sendable (NSError?) -> Void)?? in
            guard !state.stopped, state.connection === connection else { return .none }
            let wasConnected = state.isConnected
            state.connection = nil
            state.isConnected = false
            state.handshakeComplete = false
            return .some(wasConnected ? state.onDisconnected : nil)
        }
        guard case .some(let handler) = report else { return }
        if let handler {
            dispatchCallback { handler(LinkError.providerDisconnected.nsError) }
        }
        scheduleRetry()
    }

    // MARK: - Handshake and messages

    private func handle(message: LinkMessage, from connection: LinkConnection) {
        enum Delivery {
            case handshake(ServerHello)
            case deliver((@Sendable (LinkMessage) -> Void)?)
            case protocolViolation
            case ignore
        }
        let delivery = state.withLock { state -> Delivery in
            guard !state.stopped, state.connection === connection else { return .ignore }
            guard state.handshakeComplete else {
                // The provider's hello must come first; anything else makes the stream
                // uninterpretable, which is a transport failure like any other.
                guard case .serverHello(let hello) = message else { return .protocolViolation }
                return .handshake(hello)
            }
            return .deliver(state.onMessage)
        }
        switch delivery {
        case .ignore:
            break
        case .deliver(let handler):
            if let handler {
                dispatchCallback { handler(message) }
            }
        case .protocolViolation:
            connection.cancel()
        case .handshake(let hello):
            complete(handshake: hello, over: connection)
        }
    }

    private func complete(handshake hello: ServerHello, over connection: LinkConnection) {
        let outcome = state.withLock { state -> (HandshakeOutcome, (@Sendable () -> Void)?, (@Sendable (NSError?) -> Void)?) in
            guard !state.stopped, state.connection === connection else { return (.ignored, nil, nil) }
            guard hello.protocolVersion == LinkProtocol.version else {
                state.versionMismatch = true
                let error = LinkError.protocolVersionMismatch(remote: hello.protocolVersion).nsError
                return (.rejected(error), nil, state.onDisconnected)
            }
            guard hello.accepted else {
                let error = LinkError.handshakeRejected(reason: hello.reason ?? "").nsError
                return (.rejected(error), nil, state.onDisconnected)
            }
            state.handshakeComplete = true
            state.isConnected = true
            return (.accepted, state.onConnected, nil)
        }
        switch outcome.0 {
        case .ignored:
            break
        case .accepted:
            if let handler = outcome.1 {
                dispatchCallback { handler() }
            }
        case .rejected(let error):
            if let handler = outcome.2 {
                dispatchCallback { handler(error) }
            }
            // The termination this triggers sees a session that never connected, so it reports no
            // second disconnect; it schedules the retry, unless the version mismatch bars one.
            connection.cancel()
        }
    }

    // MARK: - Retry

    /// Schedules the next dial, at most one at a time.
    private func scheduleRetry() {
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.stopped, !state.versionMismatch, !state.retryScheduled else { return false }
            state.retryScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            let shouldDial = self.state.withLock { state -> Bool in
                state.retryScheduled = false
                return !state.stopped && !state.versionMismatch
            }
            guard shouldDial else { return }
            self.dial()
        }
    }

    /// ``retryInterval`` as a `DispatchTimeInterval`, saturating rather than trapping.
    private var retryDelay: DispatchTimeInterval {
        let components = retryInterval.components
        let nanoseconds = components.seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanoseconds.overflow else { return .nanoseconds(.max) }
        let total = nanoseconds.partialValue
            .addingReportingOverflow(components.attoseconds / 1_000_000_000)
        guard !total.overflow else { return .nanoseconds(.max) }
        return .nanoseconds(Int(clamping: total.partialValue))
    }

    /// Delivers a callback on `queue`, dropping it if the session stopped in the meantime.
    ///
    /// Callers are already on `queue`; hopping again keeps every callback's ordering uniform and
    /// keeps a handler from reentering the session from inside a transport callback.
    private func dispatchCallback(_ body: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self, !self.state.withLock({ $0.stopped }) else { return }
            body()
        }
    }
}
