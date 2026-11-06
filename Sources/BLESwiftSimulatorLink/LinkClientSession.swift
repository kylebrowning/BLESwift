//
//  LinkClientSession.swift
//  BLESwiftSimulatorLink
//

import BLESwiftLink
import Dispatch
import Foundation
import BLESwiftCompat17

/// The client half of a link. It dials a provider, performs the handshake, and reconnects.
///
/// A session owns one ``LinkConnection`` at a time. ``start()`` dials the endpoint. When the
/// connection is ready, the session sends a `ClientHello` and waits for the provider's
/// `ServerHello`, which must be the first message that the session receives.
///
/// If the provider accepts the hello and uses ``LinkProtocol/version``, the session becomes
/// connected. ``onConnected`` fires, and the session delivers later messages to ``onMessage``.
/// Anything else ends the connection:
///
/// - A transport failure or a refused dial causes a retry. The first retries are fast (see
///   ``init(endpoint:role:clientName:codec:queue:retryInterval:)``). Later retries use
///   `retryInterval`.
/// - A rejected hello reports `LinkError.handshakeRejected` and causes a retry.
/// - A protocol version mismatch reports `LinkError.protocolVersionMismatch` and never causes
///   a retry, because a provider that uses another version does not become compatible if the
///   session tries again.
///
/// The session calls every handler on the `queue` from the initializer. The underlying
/// connection delivers on the same queue, so callbacks arrive in order and never reentrantly.
package final class LinkClientSession: Sendable {

    /// All mutable state. One lock guards it.
    private struct State {
        /// The connection that the session owns now. The session holds it strongly, because
        /// nothing else retains a ``LinkConnection`` and its receive loop keeps only a weak
        /// reference to itself.
        var connection: LinkConnection?
        var isConnected = false
        var stopped = false
        var didStart = false
        var handshakeComplete = false
        /// Set when a provider answers with a different protocol version. It stops all retries.
        var versionMismatch = false
        var retryScheduled = false
        /// The dials that the session scheduled since it started or since the last link dropped.
        /// The first `fastRetryAttempts` of them are the fast burst.
        var retriesSinceConnected = 0
        var onConnected: (@Sendable (ServerHello) -> Void)?
        var onDisconnected: (@Sendable (NSError?) -> Void)?
        var onMessage: (@Sendable (LinkMessage) -> Void)?
        /// See `LinkClientSession.onDial`.
        var onDial: (@Sendable (LinkConnection) -> Void)?
    }

    /// The meaning of a `ServerHello` for the session. The session decides it under the lock
    /// and acts on it outside the lock.
    private enum HandshakeOutcome {
        case accepted
        case rejected(NSError)
        case ignored
    }

    private let endpoint: LinkEndpoint
    private let role: LinkRole
    private let clientName: String

    /// The identity under which this client asks the provider to host its device. The client
    /// sends it in every hello, including each reconnect's hello, so a dropped link comes back as
    /// the same device and not as a new device. The value is `nil` for a central-role client,
    /// which hosts nothing.
    private let hostIdentifier: UUID?
    private let codec: LinkCodec
    private let queue: DispatchQueue
    private let retryInterval: Duration
    private let state = Mutex(State())

    /// Creates a session that will dial `endpoint` and identify itself as `role`.
    ///
    /// - Parameters:
    ///   - endpoint: The host and port of the provider.
    ///   - role: The side of the link that this client controls.
    ///   - clientName: A name that people can read, sent in the hello for provider-side logs.
    ///   - hostIdentifier: The identity under which a `.peripheral` client asks the provider to
    ///     host its device. The session keeps it across reconnects. It is `nil` by default and
    ///     always `nil` for a central-role client. Then the provider creates one for each session.
    ///   - codec: The codec that encodes outgoing messages.
    ///   - queue: The serial queue on which the session delivers every callback.
    ///   - retryInterval: The wait before a new dial after a failure, after the opening burst.
    ///
    /// The first `fastRetryAttempts` dials after ``start()`` are fast. So are the first dials
    /// after each drop of an established link. They are `min(retryInterval, 100 ms)` apart. Each
    /// dial after that waits `retryInterval`. A successful handshake resets the counter. The burst
    /// helps a slow provider, and an app that starts before its provider.
    package init(
        endpoint: LinkEndpoint,
        role: LinkRole,
        clientName: String,
        hostIdentifier: UUID? = nil,
        codec: LinkCodec = .binaryPropertyList,
        queue: DispatchQueue,
        retryInterval: Duration = .seconds(2)
    ) {
        self.endpoint = endpoint
        self.role = role
        self.clientName = clientName
        self.hostIdentifier = hostIdentifier
        self.codec = codec
        self.queue = queue
        self.retryInterval = retryInterval
    }

    /// Called on `queue` for every connection after a provider accepts the handshake. It gets
    /// the `ServerHello` that accepted the connection. In this message, the provider reports the
    /// identity under which it actually hosted a `.peripheral` client.
    package var onConnected: (@Sendable (ServerHello) -> Void)? {
        get { state.withLock { $0.onConnected } }
        set { state.withLock { $0.onConnected = newValue } }
    }

    /// Called on `queue` when a connected link drops (the error is
    /// `LinkError.providerDisconnected`) or when a provider refuses the handshake (the error is
    /// the refusal's error). A dial that never completed a handshake does not report a
    /// disconnect. The session retries it.
    package var onDisconnected: (@Sendable (NSError?) -> Void)? {
        get { state.withLock { $0.onDisconnected } }
        set { state.withLock { $0.onDisconnected = newValue } }
    }

    /// Called on `queue` for every message that arrives after the handshake completed.
    package var onMessage: (@Sendable (LinkMessage) -> Void)? {
        get { state.withLock { $0.onMessage } }
        set { state.withLock { $0.onMessage = newValue } }
    }

    /// Whether a provider accepted the handshake and the link is live.
    package var isConnected: Bool { state.withLock { $0.isConnected } }

    /// Called on the dialing thread with every connection that a dial creates.
    ///
    /// This is not API. A test can use it to take a `weak` reference to what a dial created and
    /// assert that a terminal state releases it.
    package var onDial: (@Sendable (LinkConnection) -> Void)? {
        get { state.withLock { $0.onDial } }
        set { state.withLock { $0.onDial = newValue } }
    }

    /// Dials the endpoint and begins the connect-and-retry loop. Calls after the first have no
    /// effect. After ``stop()``, it does nothing.
    package func start() {
        let shouldDial = state.withLock { state -> Bool in
            guard !state.didStart, !state.stopped else { return false }
            state.didStart = true
            return true
        }
        guard shouldDial else { return }
        dial()
    }

    /// Tears down the session. The session cancels the current connection, schedules no retry,
    /// and delivers no more callbacks. Repeated calls are safe.
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
    /// If the session is not connected, it drops the message silently. The link is a best-effort
    /// transport, and every caller already handles a dropped link.
    package func send(_ message: LinkMessage) {
        let connection = state.withLock { state -> LinkConnection? in
            guard state.isConnected, !state.stopped else { return nil }
            return state.connection
        }
        connection?.send(message)
    }

    /// Drops the current connection because the provider sent something that the protocol does
    /// not allow. An example is a malformed identifier.
    ///
    /// The path is the same as for a transport failure. The session cancels the connection,
    /// ``onDisconnected`` reports `LinkError.providerDisconnected`, and the session dials again.
    /// A provider that keeps sending invalid data keeps losing its sessions. This is the loudest
    /// reaction that a client can give to a fault that it cannot repair. If the session is
    /// stopped or has no connection, the function does nothing.
    package func dropConnection() {
        let connection = state.withLock { state -> LinkConnection? in
            guard !state.stopped else { return nil }
            return state.connection
        }
        connection?.cancel()
    }

    // MARK: - Connecting

    /// Creates, stores, and starts a connection. ``start()`` and the retry timer call it.
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
        connection.send(.clientHello(ClientHello(
            protocolVersion: LinkProtocol.version,
            role: role,
            clientName: clientName,
            hostIdentifier: hostIdentifier
        )))
    }

    /// Ends the session's interest in `connection`. If the link was connected, the function
    /// reports a disconnect. It schedules the next dial unless the session is stopped or
    /// incompatible.
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
                // The provider's hello must come first. Anything else makes the stream
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
        let outcome = state.withLock { state -> (HandshakeOutcome, (@Sendable (ServerHello) -> Void)?, (@Sendable (NSError?) -> Void)?) in
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
            // A link that establishes and later drops earns a new burst.
            state.retriesSinceConnected = 0
            return (.accepted, state.onConnected, nil)
        }
        switch outcome.0 {
        case .ignored:
            break
        case .accepted:
            if let handler = outcome.1 {
                dispatchCallback { handler(hello) }
            }
        case .rejected(let error):
            if let handler = outcome.2 {
                dispatchCallback { handler(error) }
            }
            // The termination that this causes sees a session that never connected, so it
            // reports no second disconnect. It schedules the retry unless the version mismatch
            // bars one.
            connection.cancel()
        }
    }

    // MARK: - Retry

    /// The number of dials at the start of a burst that are ``fastRetryInterval`` apart and not
    /// `retryInterval` apart.
    private static let fastRetryAttempts = 20

    /// The spacing of a burst dial. It is 0.1 seconds, or `retryInterval` if that is already
    /// shorter. The burst can never be slower than the configured schedule.
    private var fastRetryInterval: Duration {
        min(retryInterval, .milliseconds(100))
    }

    /// Schedules the next dial. The session has at most one scheduled dial at a time.
    private func scheduleRetry() {
        let delay = state.withLock { state -> DispatchTimeInterval? in
            guard !state.stopped, !state.versionMismatch, !state.retryScheduled else { return nil }
            state.retryScheduled = true
            state.retriesSinceConnected += 1
            let interval = state.retriesSinceConnected <= Self.fastRetryAttempts
                ? fastRetryInterval
                : retryInterval
            return Self.dispatchInterval(for: interval)
        }
        guard let delay else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let shouldDial = self.state.withLock { state -> Bool in
                state.retryScheduled = false
                return !state.stopped && !state.versionMismatch
            }
            guard shouldDial else { return }
            self.dial()
        }
    }

    /// `interval` as a `DispatchTimeInterval`. It saturates and does not trap.
    private static func dispatchInterval(for interval: Duration) -> DispatchTimeInterval {
        let components = interval.components
        let nanoseconds = components.seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanoseconds.overflow else { return .nanoseconds(.max) }
        let total = nanoseconds.partialValue
            .addingReportingOverflow(components.attoseconds / 1_000_000_000)
        guard !total.overflow else { return .nanoseconds(.max) }
        return .nanoseconds(Int(clamping: total.partialValue))
    }

    /// Delivers a callback on `queue`. It drops the callback if the session stopped in the
    /// meantime.
    ///
    /// Callers are already on `queue`. The extra hop keeps the order of every callback uniform
    /// and keeps a handler from reentering the session from inside a transport callback.
    private func dispatchCallback(_ body: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self, !self.state.withLock({ $0.stopped }) else { return }
            body()
        }
    }
}
