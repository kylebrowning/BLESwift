//
//  Provider.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import Synchronization

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
/// the handshake; a `.central` client gets a `CentralSession` driving a
/// ``VirtualCentralBackend``, and a `.peripheral` client gets a `HostSession` driving a
/// ``VirtualPeripheralManagerBackend`` — each optionally composed with the host's real
/// CoreBluetooth, when ``ProviderConfiguration/passthrough`` is set — on a serial queue
/// created for that session alone. Sessions share only the radio, which is exactly what makes
/// sim-to-sim work: one simulator's `PeripheralHost` is hosted there as a device, and another
/// simulator's `Central` scans and connects to it. Nothing else leaks between sessions.
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

    /// Connections that have been accepted but have not completed a handshake.
    ///
    /// Deliberately *not* actor-isolated. A connection's handlers fire on the listener queue
    /// and reach the actor through unstructured `Task`s, between which Swift guarantees no
    /// ordering — so a table only the actor could write would let a `clientHello` land before
    /// its own connection was known (swallowing the handshake), or let a termination
    /// resurrect a dead connection. This table is instead populated *synchronously*, on the
    /// listener queue, before either handler is installed: by the time anything can fire, the
    /// connection is already here. Entries are held strongly — the listener does not retain
    /// what it accepts — and a terminated entry keeps its connection alive until the actor has
    /// released it, so no `ObjectIdentifier` can be recycled underneath a pending key.
    private nonisolated let pending = Mutex(PendingConnections())

    /// The live sessions of both roles, keyed by their connection.
    private var sessions: [ObjectIdentifier: any ProviderSession] = [:]

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
    ///   `LinkListenerError.alreadyStarted` if the provider is already
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
            // Registered synchronously, before either handler is installed, so no handler can
            // fire against an unknown connection.
            self.register(connection)
            // Both captures are weak — a handler holding its own connection would be a cycle
            // nothing breaks for a connection that never reaches a session.
            connection.onMessage = { [weak self, weak connection] message in
                guard let connection else { return }
                Task { await self?.handle(message, from: connection) }
            }
            connection.onStateChange = { [weak self, weak connection] state in
                switch state {
                case .failed, .cancelled:
                    guard let self, let connection else { return }
                    self.terminate(connection)
                case .idle, .connecting, .ready:
                    break
                }
            }
            // A connection that ended between being accepted and being wired up published its
            // one terminal transition to a handler that did not exist yet; catch it here
            // rather than leave the entry pending forever.
            switch connection.state {
            case .failed, .cancelled:
                self.terminate(connection)
            case .idle, .connecting, .ready:
                break
            }
        }
        try await listener.start()
        self.listener = listener
    }

    /// The port the listener is bound to, or `0` before ``start()`` has returned.
    public var port: UInt16 {
        listener?.port ?? 0
    }

    /// How many sessions — of either role — are live.
    public var sessionCount: Int {
        sessions.count
    }

    /// Stops listening and closes every live session, dropping each client's link. Idempotent.
    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in pending.withLock({ $0.drain() }) {
            connection.cancel()
        }
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
    }

    // MARK: - Pending connections

    /// Takes ownership of a freshly accepted connection. Called on the listener queue.
    private nonisolated func register(_ connection: LinkConnection) {
        pending.withLock { $0.register(connection) }
    }

    /// Marks a connection as terminated — synchronously, on the listener queue, so a hello
    /// still on its way to the actor can never claim it — and schedules the actor-side
    /// cleanup of whatever session it had.
    private nonisolated func terminate(_ connection: LinkConnection) {
        pending.withLock { $0.markTerminated(connection) }
        Task { await self.handleTermination(of: connection) }
    }

    // MARK: - Handshake

    /// Handles the one message a connection is allowed to send before it has a session: its
    /// ``BLESwiftLink/ClientHello``.
    ///
    /// - Important: This method must not suspend. Claiming the connection and installing its
    ///   session happen in one uninterrupted actor step, so a termination can only be observed
    ///   entirely before the claim (which then fails) or entirely after the session exists
    ///   (which it then closes).
    private func handle(_ message: LinkMessage, from connection: LinkConnection) {
        // A connection accepted while — or after — `stop()` ran must never open a session:
        // `stop()` drains the pending table, so an acceptance racing it would otherwise leave
        // a live session on a provider that is no longer listening.
        guard listener != nil else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        guard pending.withLock({ $0.isClaimable(connection) }) else {
            // Either the session installed by a completed handshake now owns this
            // connection's messages, or the connection has already terminated.
            return
        }
        // Every rejection below leaves the entry in `pending`, so the connection stays retained
        // until its terminal state releases it — long enough for the rejection to reach the
        // socket, which a claim-then-cancel would have raced.
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
        // Only an accepted handshake takes the connection out of the pending table: from here
        // on its session owns it.
        guard pending.withLock({ $0.claim(connection) }) else { return }
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
                ordinal: sessionOrdinal,
                log: configuration.log
            )
            configuration.log?("opened central session \(sessionOrdinal) for \(hello.clientName)")
        case .peripheral:
            sessionOrdinal += 1
            let queue = DispatchSerialQueue(label: "bleswift-provider.host.\(sessionOrdinal)")
            sessions[key] = HostSession(
                connection: connection,
                backend: makePeripheralBackend(queue: queue, clientName: hello.clientName),
                queue: queue,
                ordinal: sessionOrdinal,
                log: configuration.log
            )
            configuration.log?("opened host session \(sessionOrdinal) for \(hello.clientName)")
        }
    }

    /// Drops a connection that has reached a terminal state, closing its session if it had
    /// one and releasing the strong reference the pending table was holding.
    private func handleTermination(of connection: LinkConnection) {
        let key = ObjectIdentifier(connection)
        pending.withLock { $0.release(connection) }
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.close()
        configuration.log?("closed \(session.label)")
    }

    /// Builds the backend for one central-role session, on that session's own queue.
    private func makeCentralBackend(queue: DispatchSerialQueue) -> any CentralManaging {
        let virtual = queue.sync { VirtualCentralBackend(radio: radio, queue: queue) }
        guard configuration.passthrough else { return virtual }
        // The host's own CoreBluetooth by default; an injected factory overrides it.
        let factory = configuration.centralBackendFactory ?? CoreBluetoothBackends.makeCentral
        let real = queue.sync { factory(queue) }
        return CompositeCentral(backends: [virtual, real], queue: queue)
    }

    /// Builds the backend for one peripheral-role session, on that session's own queue.
    ///
    /// The virtual half registers a device on ``radio`` under a fresh identifier, named after
    /// the client — so a central-role session's scan sees the remote `PeripheralHost` exactly
    /// as it sees a fixture.
    private func makePeripheralBackend(queue: DispatchSerialQueue, clientName: String) -> any PeripheralManaging {
        let virtual = queue.sync {
            VirtualPeripheralManagerBackend(radio: radio, queue: queue, identifier: UUID(), name: clientName)
        }
        guard configuration.passthrough else { return virtual }
        // The host's own CoreBluetooth by default; an injected factory overrides it.
        let factory = configuration.peripheralManagerBackendFactory ?? CoreBluetoothBackends.makePeripheralManager
        let real = queue.sync { factory(queue) }
        return CompositePeripheralManager(backends: [virtual, real], queue: queue)
    }
}

/// The provider's table of accepted-but-not-yet-handed-off connections.
///
/// Guarded by one `Mutex` on ``Provider``, and written from the listener queue *before* a
/// connection's handlers exist, which is what makes the handshake independent of the order
/// unstructured `Task`s happen to reach the actor in.
struct PendingConnections {

    /// One accepted connection, and whether its link has already ended.
    private struct Entry {
        /// The connection, held strongly until ``release(_:)`` — which also keeps its
        /// `ObjectIdentifier` from being recycled while the key is still in the table.
        let connection: LinkConnection
        /// Whether the link ended before the handshake completed.
        var isTerminated = false
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Records a freshly accepted connection.
    mutating func register(_ connection: LinkConnection) {
        entries[ObjectIdentifier(connection)] = Entry(connection: connection)
    }

    /// Whether `connection` is still pending and has not terminated — so a hello that lost the
    /// race to its own connection's teardown is ignored rather than resurrecting it.
    ///
    /// Non-mutating, so a handshake that is about to be *rejected* can be recognized without
    /// releasing the connection the rejection still has to be written to.
    func isClaimable(_ connection: LinkConnection) -> Bool {
        guard let entry = entries[ObjectIdentifier(connection)] else { return false }
        return !entry.isTerminated
    }

    /// Claims `connection` for a completed handshake, removing it from the table.
    ///
    /// - Returns: `true` only if the connection was still pending and had not terminated, as
    ///   ``isClaimable(_:)`` reports.
    mutating func claim(_ connection: LinkConnection) -> Bool {
        let key = ObjectIdentifier(connection)
        guard isClaimable(connection) else { return false }
        entries.removeValue(forKey: key)
        return true
    }

    /// Marks `connection`'s link as ended. A connection that has already been claimed by a
    /// handshake is not in the table and is unaffected: its session owns it now.
    mutating func markTerminated(_ connection: LinkConnection) {
        entries[ObjectIdentifier(connection)]?.isTerminated = true
    }

    /// Drops `connection` from the table, releasing the strong reference it was held by.
    mutating func release(_ connection: LinkConnection) {
        entries.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Empties the table, returning every connection that was in it.
    mutating func drain() -> [LinkConnection] {
        defer { entries.removeAll() }
        return entries.values.map(\.connection)
    }
}
#endif
