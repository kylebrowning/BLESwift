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

    /// Every accepted connection, and where each one's messages currently go.
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
    ///
    /// It is also the connection's *router*, which is what makes the handshake window safe:
    /// the first message goes to ``handle(_:from:)``, everything behind it is held in the
    /// entry until the session installs its handler — and is then replayed to it, in order,
    /// while the entry keeps holding anything newer. A client that puts its first request in
    /// the same write as its `ClientHello` is served rather than dropped.
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
            // fire against an unknown connection. A refusal means the pending table is full of
            // connections that have not handshaken: this one is dropped without ever entering
            // it, so a peer opening sockets in a loop cannot crowd out a real client.
            guard self.register(connection) else {
                self.configuration.log?("refusing a connection: too many are awaiting a handshake")
                connection.cancel()
                return
            }
            self.scheduleHandshakeDeadline(for: connection)
            // Both captures are weak — a handler holding its own connection would be a cycle
            // nothing breaks for a connection that never reaches a session.
            //
            // This stays the connection's only message handler for its whole life: a session
            // registers *its* handler in the table instead of replacing this one, so the
            // routing decision is made synchronously, on the listener queue, in the order the
            // messages were received. Only the very first message takes the actor hop.
            connection.onMessage = { [weak self, weak connection] message in
                guard let self, let connection else { return }
                switch self.pending.withLock({ $0.route(message, from: connection) }) {
                case .drop:
                    break
                case .handshake:
                    Task { await self.handle(message, from: connection) }
                case .deliver(let handler):
                    handler(message)
                }
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
    ///
    /// - Returns: `false` when ``ProviderConfiguration/maximumPendingConnections`` connections
    ///   are already awaiting a handshake, in which case nothing was recorded and the caller
    ///   must cancel this one.
    private nonisolated func register(_ connection: LinkConnection) -> Bool {
        pending.withLock { $0.register(connection, limit: configuration.maximumPendingConnections) }
    }

    /// Cancels `connection` if it has still not handshaken
    /// ``ProviderConfiguration/handshakeTimeout`` from now.
    ///
    /// The deadline lives out here rather than inside ``handle(_:from:)``, which must not
    /// suspend: this is an independent task that only *reads* the connection's claim state
    /// when it fires. A connection whose handshake completed is claimed by then, and one that
    /// already ended is terminated, so either way the deadline finds nothing to do.
    private nonisolated func scheduleHandshakeDeadline(for connection: LinkConnection) {
        let timeout = configuration.handshakeTimeout
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: timeout)
            guard let self, let connection else { return }
            guard self.pending.withLock({ $0.isClaimable(connection) }) else { return }
            self.configuration.log?("releasing a connection that sent no client hello within \(timeout)")
            connection.cancel()
        }
    }

    /// Marks a connection as terminated — synchronously, on the listener queue, so a hello
    /// still on its way to the actor can never claim it — and schedules the actor-side
    /// cleanup of whatever session it had.
    private nonisolated func terminate(_ connection: LinkConnection) {
        pending.withLock { $0.markTerminated(connection) }
        Task { await self.handleTermination(of: connection) }
    }

    // MARK: - Handshake

    /// Handles the first message a connection sends: its ``BLESwiftLink/ClientHello``.
    ///
    /// Everything the client sent behind that hello is already held in the connection's
    /// entry; constructing the session installs the session's own handler in that entry and
    /// replays the backlog to it, and the session then writes the accepted `ServerHello` as
    /// its first frame — so the hello still precedes every event on the wire without leaving
    /// a window in which a request has nowhere to go.
    ///
    /// - Important: This method must not suspend. Claiming the connection, installing its
    ///   session and handing over its messages happen in one uninterrupted actor step, so a
    ///   termination can only be observed entirely before the claim (which then fails) or
    ///   entirely after the session exists (which it then closes).
    private func handle(_ message: LinkMessage, from connection: LinkConnection) {
        // A connection accepted while — or after — `stop()` ran must never open a session:
        // `stop()` empties the connection table, so an acceptance racing it would otherwise
        // leave a live session on a provider that is no longer listening.
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
        // Only an accepted handshake claims the connection: from here on its session owns the
        // messages, and the entry routes them there rather than back to this method.
        guard pending.withLock({ $0.claim(connection) }) else { return }
        let accepted = ServerHello(
            protocolVersion: LinkProtocol.version,
            accepted: true,
            reason: nil,
            providerName: configuration.providerName
        )
        // Installs the session's handler in the connection's entry and replays whatever
        // arrived behind the hello, in order, before any newer message can be delivered.
        //
        // The replay runs *outside* the table's lock, one batch at a time: the entry holds
        // anything that arrives meanwhile — the listener queue keeps routing into it — and the
        // next turn of this loop picks it up, so ordering is kept without ever calling a
        // session's handler under the lock. Suspension-free, as this method requires.
        let install: (@escaping @Sendable (LinkMessage) -> Void) -> Void = { handler in
            var batch = self.pending.withLock { $0.beginReplay(handler, for: connection) }
            while let messages = batch {
                for message in messages { handler(message) }
                batch = self.pending.withLock { $0.finishReplay(for: connection) }
            }
        }
        switch hello.role {
        case .central:
            sessionOrdinal += 1
            let queue = DispatchSerialQueue(label: "bleswift-provider.central.\(sessionOrdinal)")
            sessions[key] = CentralSession(
                connection: connection,
                backend: makeCentralBackend(queue: queue),
                queue: queue,
                ordinal: sessionOrdinal,
                hello: accepted,
                install: install,
                log: configuration.log,
                maximumRemotes: configuration.maximumRemotesPerCentralSession
            )
            configuration.log?("opened central session \(sessionOrdinal) for \(hello.clientName)")
        case .peripheral:
            sessionOrdinal += 1
            let queue = DispatchSerialQueue(label: "bleswift-provider.host.\(sessionOrdinal)")
            sessions[key] = HostSession(
                connection: connection,
                backend: makePeripheralBackend(
                    queue: queue,
                    clientName: hello.clientName,
                    // The client's own identity when it sent one, so its reconnect re-registers
                    // the device it had rather than a new one; a fresh identifier otherwise.
                    identifier: hello.hostIdentifier ?? UUID()
                ),
                queue: queue,
                ordinal: sessionOrdinal,
                hello: accepted,
                install: install,
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
        guard configuration.passthrough else {
            return queue.sync { VirtualCentralBackend(radio: radio, queue: queue) }
        }
        // The host's own CoreBluetooth by default; an injected factory overrides it.
        let factory = configuration.centralBackendFactory ?? CoreBluetoothBackends.makeCentral
        // One hop, not three: a real `CBCentralManager` delivers its opening `didUpdateState`
        // as soon as the queue yields, so the composite must be wired onto it before this
        // block returns — see ``CoreBluetoothBackends``.
        return queue.sync {
            let virtual = VirtualCentralBackend(radio: radio, queue: queue)
            let real = factory(queue)
            return CompositeCentral(backends: [virtual, real], onQueue: queue)
        }
    }

    /// Builds the backend for one peripheral-role session, on that session's own queue.
    ///
    /// The virtual half registers a device on ``radio`` under `identifier`, named after the
    /// client — so a central-role session's scan sees the remote `PeripheralHost` exactly as it
    /// sees a fixture.
    ///
    /// - Parameters:
    ///   - queue: The session's own serial queue.
    ///   - clientName: The name the hosted device advertises itself under.
    ///   - identifier: The identity to host the device under — the one the client asked for in
    ///     its ``BLESwiftLink/ClientHello``, so its reconnect is the same device to every
    ///     central that had seen it.
    private func makePeripheralBackend(
        queue: DispatchSerialQueue,
        clientName: String,
        identifier: UUID
    ) -> any PeripheralManaging {
        guard configuration.passthrough else {
            return queue.sync {
                VirtualPeripheralManagerBackend(radio: radio, queue: queue, identifier: identifier, name: clientName)
            }
        }
        // The host's own CoreBluetooth by default; an injected factory overrides it.
        let factory = configuration.peripheralManagerBackendFactory ?? CoreBluetoothBackends.makePeripheralManager
        // Built and attached in one hop, for the reason `makeCentralBackend` gives.
        return queue.sync {
            let virtual = VirtualPeripheralManagerBackend(
                radio: radio, queue: queue, identifier: identifier, name: clientName
            )
            let real = factory(queue)
            return CompositePeripheralManager(backends: [virtual, real], onQueue: queue, log: configuration.log)
        }
    }
}

/// The provider's table of accepted connections, and the router for their messages.
///
/// Guarded by one `Mutex` on ``Provider``, and written from the listener queue *before* a
/// connection's handlers exist, which is what makes the handshake independent of the order
/// unstructured `Task`s happen to reach the actor in.
///
/// An entry lives from the moment its connection is accepted until the link ends, and it is
/// what every message is routed through: the first goes to the actor's handshake, the ones
/// behind it are held until a session installs its handler and the replay has drained them,
/// and everything after that is delivered straight to the session on the listener queue.
/// Nothing between the hello and the session is dropped, and no message can overtake one that
/// arrived before it.
///
/// **Nothing is called while the lock is held.** Routing and installing both only *decide*;
/// the caller delivers afterwards, on its own. That is what lets a session's handler do
/// whatever it likes — including reaching back into this table — without deadlocking against
/// the one `Mutex` every connection shares.
struct PendingConnections {

    /// Where one message goes, decided synchronously on the listener queue.
    enum Routing {
        /// Nowhere: the link has ended, the connection is unknown, or the message was held
        /// for a session that has not installed its handler yet.
        case drop
        /// To ``Provider/handle(_:from:)`` — the connection's first message, its hello.
        case handshake
        /// To the session that owns this connection.
        case deliver(@Sendable (LinkMessage) -> Void)
    }

    /// One accepted connection: whether its link has ended, how far its handshake has got,
    /// and either its session's handler or the messages waiting for one.
    private struct Entry {
        /// The connection, held strongly until ``release(_:)`` — which also keeps its
        /// `ObjectIdentifier` from being recycled while the key is still in the table.
        let connection: LinkConnection
        /// Whether the link ended.
        var isTerminated = false
        /// Whether the first message has already been routed to the handshake, so a second
        /// hello cannot open a second session.
        var didRouteHello = false
        /// Whether an accepted handshake has claimed this connection.
        var isClaimed = false
        /// The session's message handler, once it has one.
        var handler: (@Sendable (LinkMessage) -> Void)?
        /// Whether the backlog is being replayed to ``handler`` right now. A message that
        /// arrives during the replay joins ``queued`` instead of being delivered, so it
        /// cannot overtake the backlog it arrived behind; the replaying caller picks it up.
        var isReplaying = false
        /// Messages that arrived behind the hello — or during the replay — held in order
        /// until ``handler`` has been given them.
        var queued: [LinkMessage] = []
    }

    /// How many messages one entry holds before it starts dropping them. Only a connection
    /// whose handshake is in flight — or one that was rejected and is about to be cancelled —
    /// ever queues at all, so this is a ceiling on a misbehaving client, not a flow-control
    /// window.
    private static let maximumQueued = 256

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Records a freshly accepted connection, unless `limit` connections are already awaiting
    /// a handshake.
    ///
    /// Only unclaimed, unterminated entries count against `limit`: a connection a session owns
    /// is no longer pending, and one whose link has ended is on its way out.
    ///
    /// - Returns: `true` if the connection was recorded.
    mutating func register(_ connection: LinkConnection, limit: Int) -> Bool {
        let awaiting = entries.values.count { !$0.isClaimed && !$0.isTerminated }
        guard awaiting < limit else { return false }
        entries[ObjectIdentifier(connection)] = Entry(connection: connection)
        return true
    }

    /// Decides where `message` goes, and holds it if the answer is "nowhere yet".
    ///
    /// - Returns: The routing to apply, on the listener queue, before the next message is
    ///   routed.
    mutating func route(_ message: LinkMessage, from connection: LinkConnection) -> Routing {
        let key = ObjectIdentifier(connection)
        guard var entry = entries[key], !entry.isTerminated else { return .drop }
        if let handler = entry.handler, !entry.isReplaying { return .deliver(handler) }
        defer { entries[key] = entry }
        guard entry.didRouteHello else {
            entry.didRouteHello = true
            return .handshake
        }
        if entry.queued.count < Self.maximumQueued { entry.queued.append(message) }
        return .drop
    }

    /// Installs `handler` as `connection`'s destination and takes the backlog held for it.
    ///
    /// The backlog is *returned*, not delivered: nothing is called while the table is locked,
    /// which is what keeps a session's handler — and anything it in turn calls — off this
    /// lock's critical section. Ordering is preserved by the entry's replaying flag instead of
    /// by the lock's duration: from here until ``finishReplay(for:)`` says otherwise, a
    /// message arriving on the listener queue joins the queue rather than being delivered, so
    /// it cannot overtake the backlog it arrived behind. The caller must drain to completion —
    /// see ``Provider/handle(_:from:)``'s installer.
    ///
    /// - Returns: The messages to replay, oldest first, or `nil` for a connection whose link
    ///   has already ended — its session is about to be closed, and nothing is installed.
    mutating func beginReplay(_ handler: @escaping @Sendable (LinkMessage) -> Void, for connection: LinkConnection) -> [LinkMessage]? {
        let key = ObjectIdentifier(connection)
        guard var entry = entries[key], !entry.isTerminated else { return nil }
        entry.handler = handler
        entry.isReplaying = true
        let queued = entry.queued
        entry.queued = []
        entries[key] = entry
        return queued
    }

    /// Takes whatever arrived while the previous batch was being replayed.
    ///
    /// - Returns: The next batch to replay, oldest first, or `nil` when there is none left —
    ///   at which point the entry stops holding messages and routes them to its handler
    ///   directly. `nil` is also the answer for a connection whose link ended mid-replay:
    ///   nothing more is delivered to a session that is about to be closed.
    mutating func finishReplay(for connection: LinkConnection) -> [LinkMessage]? {
        let key = ObjectIdentifier(connection)
        guard var entry = entries[key], !entry.isTerminated else { return nil }
        guard !entry.queued.isEmpty else {
            entry.isReplaying = false
            entries[key] = entry
            return nil
        }
        let queued = entry.queued
        entry.queued = []
        entries[key] = entry
        return queued
    }

    /// Whether `connection` is still awaiting a handshake and has not terminated — so a hello
    /// that lost the race to its own connection's teardown is ignored rather than
    /// resurrecting it.
    ///
    /// Non-mutating, so a handshake that is about to be *rejected* can be recognized without
    /// releasing the connection the rejection still has to be written to.
    func isClaimable(_ connection: LinkConnection) -> Bool {
        guard let entry = entries[ObjectIdentifier(connection)] else { return false }
        return !entry.isTerminated && !entry.isClaimed
    }

    /// Claims `connection` for a completed handshake.
    ///
    /// The entry stays in the table — it is what routes the connection's messages to the
    /// session about to ``install(_:for:)`` its handler, and what holds the ones that arrive
    /// in between.
    ///
    /// - Returns: `true` only if the connection was unclaimed and had not terminated, as
    ///   ``isClaimable(_:)`` reports.
    mutating func claim(_ connection: LinkConnection) -> Bool {
        let key = ObjectIdentifier(connection)
        guard isClaimable(connection) else { return false }
        entries[key]?.isClaimed = true
        return true
    }

    /// Marks `connection`'s link as ended, and drops both its handler and anything still
    /// held for it: nothing is delivered to a session whose link is gone.
    mutating func markTerminated(_ connection: LinkConnection) {
        let key = ObjectIdentifier(connection)
        entries[key]?.isTerminated = true
        entries[key]?.handler = nil
        entries[key]?.queued = []
    }

    /// Drops `connection` from the table, releasing the strong reference it was held by.
    mutating func release(_ connection: LinkConnection) {
        entries.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Empties the table, returning every connection that was in it — those still
    /// handshaking and those a session already owns alike. `stop()` cancels them all.
    mutating func drain() -> [LinkConnection] {
        defer { entries.removeAll() }
        return entries.values.map(\.connection)
    }
}
#endif
