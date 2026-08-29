//
//  Provider.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// The host-side half of the simulator link: it hosts virtual devices on a
/// ``VirtualRadio``, listens on a TCP port, and serves each client that connects from a
/// backend of its own.
///
/// ```swift
/// var configuration = ProviderConfiguration()
/// configuration.fixtures = try FixtureDocument.load(from: url).devices
/// let provider = Provider(configuration: configuration)
/// try await provider.start()
/// ```
///
/// **One session per connection, one backend per session.** A client identifies its role in
/// the handshake; a `.central` client gets a ``CentralSession`` driving a
/// ``VirtualCentralBackend`` — optionally composed with the host's real CoreBluetooth, when
/// ``ProviderConfiguration/passthrough`` is set — on a serial queue created for that session
/// alone. Sessions share only the radio, so one client's scans and connections never leak
/// into another's.
public actor Provider {

    /// The radio hosting every virtual device this provider serves. `nonisolated` because
    /// the radio is an actor of its own: callers await it directly rather than through the
    /// provider.
    public nonisolated let radio = VirtualRadio()

    /// What this provider was configured with.
    private let configuration: ProviderConfiguration

    /// The queue the listener and every accepted connection deliver their callbacks on.
    private let listenerQueue = DispatchQueue(label: "bleswift-provider.listener")

    /// The listener, once ``start()`` has bound it.
    private var listener: LinkListener?

    /// Connections that have been accepted but have not completed a handshake, held
    /// strongly: the listener does not retain what it accepts.
    private var pending: [ObjectIdentifier: LinkConnection] = [:]

    /// The live central-role sessions, keyed by their connection.
    private var sessions: [ObjectIdentifier: CentralSession] = [:]

    /// The handles of the fixture devices ``start()`` registered, keyed by device id.
    private var fixtures: [UUID: VirtualDeviceHandle] = [:]

    /// Numbers the per-session queue labels.
    private var sessionOrdinal = 0

    /// Creates a provider. Nothing is registered and no port is bound until ``start()``.
    ///
    /// - Parameter configuration: Where to listen, what to host, and how to log.
    public init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    /// Registers `device` on ``radio``.
    ///
    /// - Parameters:
    ///   - device: The device to host.
    ///   - advertising: Whether it starts out advertising. Defaults to `true`.
    /// - Returns: The handle for pushing notifications and mutating the device afterwards.
    @discardableResult
    public func addVirtualDevice(_ device: VirtualDevice, advertising: Bool = true) async -> VirtualDeviceHandle {
        await radio.register(device, advertising: advertising)
    }

    /// The handle of the fixture device registered under `identifier`, or `nil` if
    /// ``ProviderConfiguration/fixtures`` declared no such device.
    ///
    /// - Parameter identifier: The fixture device's `id`.
    /// - Returns: Its handle, for pushing notifications and mutating it.
    public func handle(for identifier: UUID) -> VirtualDeviceHandle? {
        fixtures[identifier]
    }

    /// Registers every configured fixture on ``radio``, then binds the listener.
    ///
    /// Returns once the port is bound, so ``port`` is valid on return.
    ///
    /// - Throws: The `NWError` the listener failed to bind with — a port already in use
    ///   fails here rather than being retried — or
    ///   ``BLESwiftLink/LinkListenerError/alreadyStarted`` if the provider is already
    ///   listening.
    public func start() async throws {
        guard listener == nil else { throw LinkListenerError.alreadyStarted }
        for fixture in configuration.fixtures {
            let (device, handler) = VirtualDevice.fixture(fixture)
            let handle = await radio.register(device)
            await handler.attach(handle)
            fixtures[fixture.id] = handle
        }
        let listener = try LinkListener(
            endpoint: configuration.endpoint,
            codec: configuration.codec,
            queue: listenerQueue
        )
        listener.onConnection = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            // Installed synchronously, on the listener queue, before this callback returns:
            // the first message may already be on its way. Both captures are weak — a
            // handler holding its own connection would be a cycle nothing breaks for a
            // connection that never reaches a session.
            connection.onMessage = { [weak self, weak connection] message in
                guard let connection else { return }
                Task { await self?.handle(message, from: connection) }
            }
            connection.onStateChange = { [weak self, weak connection] state in
                switch state {
                case .failed, .cancelled:
                    guard let connection else { return }
                    Task { await self?.handleTermination(of: connection) }
                case .idle, .connecting, .ready:
                    break
                }
            }
            Task { await self.retain(connection) }
        }
        try await listener.start()
        self.listener = listener
    }

    /// The port the listener is bound to, or `0` before ``start()`` has returned.
    public var port: UInt16 {
        listener?.port ?? 0
    }

    /// How many central-role sessions are live.
    public var sessionCount: Int {
        sessions.count
    }

    /// Stops listening and closes every live session, dropping each client's link. Idempotent.
    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in pending.values {
            connection.cancel()
        }
        pending.removeAll()
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
    }

    // MARK: - Handshake

    /// Takes ownership of a freshly accepted connection.
    private func retain(_ connection: LinkConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        pending[ObjectIdentifier(connection)] = connection
    }

    /// Handles the one message a connection is allowed to send before it has a session: its
    /// ``BLESwiftLink/ClientHello``.
    private func handle(_ message: LinkMessage, from connection: LinkConnection) {
        let key = ObjectIdentifier(connection)
        guard pending.removeValue(forKey: key) != nil else {
            // The session installed by a completed handshake owns the connection's messages
            // from that point on; anything reaching here belongs to a connection that has
            // already been handed off or torn down.
            return
        }
        guard case .clientHello(let hello) = message else {
            configuration.log?("rejecting a connection whose first message was not a client hello")
            connection.cancel()
            return
        }
        guard hello.protocolVersion == LinkProtocol.version else {
            let reason = "protocol version \(hello.protocolVersion) is not \(LinkProtocol.version)"
            configuration.log?("rejecting \(hello.clientName): \(reason)")
            connection.send(.serverHello(ServerHello(
                protocolVersion: LinkProtocol.version,
                accepted: false,
                reason: reason,
                providerName: configuration.providerName
            )))
            connection.cancel()
            return
        }
        connection.send(.serverHello(ServerHello(
            protocolVersion: LinkProtocol.version,
            accepted: true,
            reason: nil,
            providerName: configuration.providerName
        )))
        switch hello.role {
        case .central:
            sessionOrdinal += 1
            let queue = DispatchSerialQueue(label: "bleswift-provider.central.\(sessionOrdinal)")
            sessions[key] = CentralSession(
                connection: connection,
                backend: makeCentralBackend(queue: queue),
                queue: queue,
                log: configuration.log
            )
            configuration.log?("opened central session \(sessionOrdinal) for \(hello.clientName)")
        case .peripheral:
            // Task 13 replaces this.
            configuration.log?("peripheral role not yet available")
            connection.cancel()
        }
    }

    /// Drops a connection that has reached a terminal state, closing its session if it had
    /// one.
    private func handleTermination(of connection: LinkConnection) {
        let key = ObjectIdentifier(connection)
        pending.removeValue(forKey: key)
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.close()
        configuration.log?("closed a central session")
    }

    /// Builds the backend for one central-role session, on that session's own queue.
    private func makeCentralBackend(queue: DispatchSerialQueue) -> any CentralManaging {
        let virtual = queue.sync { VirtualCentralBackend(radio: radio, queue: queue) }
        guard configuration.passthrough else { return virtual }
        guard let factory = configuration.centralBackendFactory else {
            // Task 15 replaces this: `CoreBluetoothBackends` — the real central backend a
            // passthrough provider composes with — does not exist yet, so a passthrough
            // session with no injected factory is served by the virtual radio alone.
            configuration.log?("passthrough has no central backend factory; CoreBluetoothBackends arrives in Task 15")
            return virtual
        }
        let real = queue.sync { factory(queue) }
        return CompositeCentral(backends: [virtual, real], queue: queue)
    }
}
#endif
