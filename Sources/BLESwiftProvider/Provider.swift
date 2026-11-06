//
//  Provider.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import BLESwiftCompat17

/// The host-side half of the simulator link. It hosts virtual devices on a ``VirtualRadio`` and
/// listens on a TCP port. It serves each client that connects from a backend of its own.
///
/// ```swift
/// var configuration = ProviderConfiguration()
/// configuration.fixtures = try FixtureDocument.load(from: url).devices
/// let provider = Provider(configuration: configuration)
/// try await provider.start()
/// ```
///
/// **One session for each connection, and one backend for each session.** A client states its
/// role in the handshake.
///
/// - A `.central` client gets a `CentralSession`. The session drives a
///   ``VirtualCentralBackend``.
/// - A `.peripheral` client gets a `HostSession`. The session drives a
///   ``VirtualPeripheralManagerBackend``.
///
/// If ``ProviderConfiguration/passthrough`` is set, the provider combines each backend with the
/// host's real CoreBluetooth. Each session runs on a serial queue that the provider creates for
/// that session alone. Sessions share only the radio. This is how sim-to-sim works: one
/// simulator's `PeripheralHost` is hosted there as a device, and another simulator's `Central`
/// scans for it and connects to it.
public actor Provider {

    /// The radio that hosts every virtual device that this provider serves. It is `nonisolated`
    /// because the radio is an actor of its own. Callers await the radio directly, not through
    /// the provider.
    public nonisolated let radio = VirtualRadio()

    /// The configuration of this provider.
    private let configuration: ProviderConfiguration

    /// The queue on which the listener and each accepted connection deliver their callbacks.
    private let listenerQueue = DispatchQueue(label: "bleswift-provider.listener")

    /// The listener, after ``start()`` has bound it.
    private var listener: LinkListener?

    /// Every accepted connection, and the destination of its messages.
    ///
    /// This table is not actor-isolated on purpose. Handlers fire on the listener queue and reach
    /// the actor through `Task`s that have no fixed order. So the provider fills the table
    /// synchronously on that queue, before it installs a handler. Otherwise a `clientHello` could
    /// arrive before its connection is known, or a termination could resurrect a dead connection.
    ///
    /// The table holds entries strongly, because the listener does not retain connections. It also
    /// routes messages. The first message goes to ``handle(_:from:)``. The entry holds later
    /// messages until the session installs its handler, and then replays them in order.
    private nonisolated let pending = Mutex(PendingConnections())

    /// The live sessions of both roles, keyed by their connection.
    private var sessions: [ObjectIdentifier: any ProviderSession] = [:]

    /// The handles of the fixture devices that ``start()`` registered, keyed by device id.
    private var fixtures: [UUID: VirtualDeviceHandle] = [:]

    /// The handles of the devices that ``addVirtualDevice(_:advertising:)`` registered, keyed by
    /// device id. The provider keeps them so that ``stop()`` also takes them off the radio.
    ///
    /// This table is separate from ``fixtures``. ``handle(for:)`` gives out only a *fixture's*
    /// handle, because the caller of `addVirtualDevice` already has the handle that the call
    /// returned.
    private var addedDevices: [UUID: VirtualDeviceHandle] = [:]

    /// The identifiers of the devices that the *provider itself* put on the radio: its fixtures
    /// and all devices that ``addVirtualDevice(_:advertising:)`` registered.
    ///
    /// ``hostedIdentifier(for:)`` refuses a client's chosen identity if it is in this set. The
    /// set is deliberately not ``VirtualRadio/knownDeviceIDs``, which also holds the devices
    /// hosted for *clients*. A client that redials faster than the asynchronous removal of its
    /// old session completes would find its own identifier still in that set. The provider would
    /// then host the client under a new `UUID`, and every central that had seen the client would
    /// silently see a new device.
    ///
    /// The provider defends only its own devices. A peripheral-role client can register its
    /// *own* identifier again. This is the reconnect for which the stable `hostIdentifier`
    /// exists. The generation guard of ``VirtualDeviceHandle`` keeps the old session's teardown
    /// off the new registration.
    private var providerOwnedIdentifiers: Set<UUID> = []

    /// The number for the next session's queue label.
    private var sessionOrdinal = 0

    /// Each ``stop()`` increases this value. Work that suspended before a stop can then see,
    /// when it resumes, that a stop tore down the provider with which it was registering. See
    /// ``addVirtualDevice(_:advertising:)``.
    private var stopGeneration: UInt64 = 0

    /// The number of ``stop()`` calls that are in progress. Each call suspends in the radio
    /// several times, and this actor serves other calls meanwhile. A registration that begins and
    /// finishes inside that window carries the *same* ``stopGeneration`` on both sides of its
    /// own suspension, and a stop would still empty it out of the tables behind it.
    ///
    /// This is a depth and not a flag, because two stops can overlap and the `handle.remove()`
    /// calls of one stop can return in any order. The exit of the *inner* stop must not report
    /// that the outer stop's window is closed.
    private var stopDepth = 0

    /// Whether any ``stop()`` is in progress. See ``stopDepth``.
    private var isStopping: Bool { stopDepth > 0 }

    /// Creates a provider. The provider registers nothing and binds no port until ``start()``.
    ///
    /// - Parameter configuration: The settings that set where to listen, what to host, and how
    ///   to log.
    public init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    /// Registers `device` on ``radio``.
    ///
    /// From this point, the device belongs to the provider. The provider refuses its identifier
    /// to any peripheral-role client that asks to be hosted under it. ``stop()`` takes the
    /// device off the radio together with the configured fixtures.
    ///
    /// - Parameters:
    ///   - device: The device to host.
    ///   - advertising: Whether the device starts to advertise. The default is `true`.
    /// - Returns: The handle that you use to push notifications and to change the device later.
    ///   The handle is stale after ``stop()`` removes the device, as for a fixture's handle. This
    ///   includes a ``stop()`` that ran *during* this call, which takes the device off the radio
    ///   immediately. Thus no device stays on the radio with nothing to remove it.
    @discardableResult
    public func addVirtualDevice(_ device: VirtualDevice, advertising: Bool = true) async -> VirtualDeviceHandle {
        let identifier = device.descriptor.identifier
        // Registration suspends, and this actor serves a `stop()` meanwhile. The stop can begin
        // before this call, or it can be suspended in the radio itself. In either case it
        // empties both tables and the identifier set. If this method then recorded the device
        // after it resumed, the device would stay on a shared radio with nothing to hold its
        // handle or defend its identifier. `stop()` promises that this does not happen, so the
        // method takes the device off the radio instead.
        //
        // Read the state on both sides of the suspension. An add that began inside one stop's
        // window and resumed after a shorter, overlapping stop had returned would see depth zero
        // and an unchanged generation, and would still record an orphan.
        let generation = stopGeneration
        let wasStopping = isStopping
        providerOwnedIdentifiers.insert(identifier)
        let handle = await radio.register(device, advertising: advertising)
        guard !wasStopping, generation == stopGeneration, !isStopping else {
            await handle.remove()
            return handle
        }
        addedDevices[identifier] = handle
        return handle
    }

    /// The handle of the fixture device that is registered under `identifier`, or `nil` if
    /// ``ProviderConfiguration/fixtures`` declared no such device.
    ///
    /// - Parameter identifier: The `id` of the fixture device.
    /// - Returns: Its handle, which you use to push notifications and to change the device.
    public func handle(for identifier: UUID) -> VirtualDeviceHandle? {
        fixtures[identifier]
    }

    /// Registers every configured fixture on ``radio``, then binds the listener.
    ///
    /// This method returns after it binds the port, so ``port`` is valid on return.
    ///
    /// **A start that throws leaves the radio as it found the radio.** The fixtures go on the
    /// radio before the listener binds, so no client can use a radio that is still filling up.
    /// If the bind fails, the fixtures come straight off the radio. Otherwise a retry would
    /// register each fixture a second time under a new generation, and the radio's generation
    /// guard would refuse every handle that ``handle(for:)`` gave out for the first attempt.
    ///
    /// - Throws:
    ///   - ``ProviderFixtureError/duplicateIdentifier(_:)`` if two configured fixtures declare
    ///     the same `id`.
    ///   - The `NWError` with which the listener failed to bind. A port that is in use fails
    ///     here. The provider does not retry.
    ///   - `LinkListenerError.alreadyStarted` if the provider is already listening.
    public func start() async throws {
        guard listener == nil else { throw LinkListenerError.alreadyStarted }
        // Check before registering anything, so a document that names one device twice is a
        // startup failure and not a silent half-registration. Otherwise the second registration
        // would replace the first on the radio and make stale the handle that
        // ``handle(for:)`` would give out for the first.
        var declared: Set<UUID> = []
        for fixture in configuration.fixtures where !declared.insert(fixture.id).inserted {
            throw ProviderFixtureError.duplicateIdentifier(fixture.id)
        }
        for fixture in configuration.fixtures {
            let (device, handler) = VirtualDevice.fixture(fixture)
            let handle = await radio.register(device)
            await handler.attach(handle)
            fixtures[fixture.id] = handle
            providerOwnedIdentifiers.insert(fixture.id)
        }
        let listener: LinkListener
        do {
            listener = try LinkListener(
                endpoint: configuration.endpoint,
                codec: configuration.codec,
                queue: listenerQueue
            )
        } catch {
            await unregisterFixtures()
            throw error
        }
        listener.onConnection = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            // Register synchronously, before installing either handler, so no handler can fire
            // for an unknown connection. If the registration is refused, the pending table is
            // full of connections that have not done the handshake. Drop this connection without
            // putting it in the table, so a peer that opens sockets in a loop cannot crowd out a
            // real client.
            guard self.register(connection) else {
                self.configuration.log?("refusing a connection: too many are awaiting a handshake")
                connection.cancel()
                return
            }
            self.scheduleHandshakeDeadline(for: connection)
            // Both captures are weak. A handler that holds its own connection would be a cycle,
            // and nothing breaks the cycle for a connection that never reaches a session.
            //
            // This stays the connection's only message handler for its whole life. A session
            // registers *its* handler in the table and does not replace this one. Thus the
            // routing decision is synchronous, on the listener queue, in message order. Only the
            // first message takes the actor hop.
            connection.onMessage = { [weak self, weak connection] message in
                guard let self, let connection else { return }
                switch self.pending.withLock({ $0.route(message, from: connection) }) {
                case .drop:
                    break
                case .exceededBacklog:
                    self.configuration.log?(
                        "dropping a connection holding more than "
                            + "\(PendingConnections.maximumQueuedBytes) bytes behind its handshake"
                    )
                    connection.cancel()
                case .exceededQueueDepth:
                    self.configuration.log?(
                        "dropping a connection holding more than "
                            + "\(PendingConnections.maximumQueued) messages behind its handshake"
                    )
                    connection.cancel()
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
            // A connection can end between its acceptance and its wiring, and then it published
            // its one terminal transition to a handler that did not exist yet. Catch that
            // transition here. Otherwise the entry stays pending forever.
            switch connection.state {
            case .failed, .cancelled:
                self.terminate(connection)
            case .idle, .connecting, .ready:
                break
            }
        }
        do {
            try await listener.start()
        } catch {
            await unregisterFixtures()
            throw error
        }
        self.listener = listener
    }

    /// Takes the fixtures that this ``start()`` registered off ``radio``, and stops defending
    /// their identifiers. This is the rollback for a listener that never bound. It leaves the
    /// devices that ``addVirtualDevice(_:advertising:)`` registered, because this start did not
    /// register them.
    private func unregisterFixtures() async {
        let registered = fixtures
        fixtures.removeAll()
        for (identifier, handle) in registered {
            await handle.remove()
            providerOwnedIdentifiers.remove(identifier)
        }
    }

    /// The bound port. The value is `0` before ``start()`` returns.
    public var port: UInt16 {
        listener?.port ?? 0
    }

    /// The number of live sessions of both roles.
    public var sessionCount: Int {
        sessions.count
    }

    /// Every live session, in no particular order. This property is internal, for the tests that
    /// drive one session's off-queue completions directly.
    var liveSessions: [any ProviderSession] {
        Array(sessions.values)
    }

    /// Stops the listener, closes every live session, and takes the provider's devices off the
    /// radio. Repeated calls are safe.
    ///
    /// The devices are the configured fixtures and all devices that
    /// ``addVirtualDevice(_:advertising:)`` registered. A call to
    /// ``addVirtualDevice(_:advertising:)`` that overlaps this method takes its device off the
    /// radio when it resumes.
    ///
    /// - Note: A ``start()`` after a ``stop()`` registers the fixtures again as new registrations
    ///   under the same id. Use ``handle(for:)`` to get the new ``VirtualDeviceHandle``. A handle
    ///   that you took before the stop is stale for good. The radio's generation guard refuses
    ///   every call on it.
    public func stop() async {
        stopGeneration &+= 1
        stopDepth += 1
        defer { stopDepth -= 1 }
        listener?.cancel()
        listener = nil
        for connection in pending.withLock({ $0.drain() }) {
            connection.cancel()
        }
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
        for handle in fixtures.values {
            await handle.remove()
        }
        fixtures.removeAll()
        // Everything that ``addVirtualDevice(_:advertising:)`` registered goes with them, off the
        // radio before the set below stops defending its identifier.
        for handle in addedDevices.values {
            await handle.remove()
        }
        addedDevices.removeAll()
        // This provider defends no identifier for a device that it no longer hosts.
        providerOwnedIdentifiers.removeAll()
    }

    // MARK: - Pending connections

    /// Takes ownership of a connection that the listener just accepted. The caller runs on the
    /// listener queue.
    ///
    /// - Returns: `false` when ``ProviderConfiguration/maximumPendingConnections`` connections
    ///   already wait for a handshake. In that case the method recorded nothing, and the caller
    ///   must cancel this connection.
    private nonisolated func register(_ connection: LinkConnection) -> Bool {
        pending.withLock { $0.register(connection, limit: configuration.maximumPendingConnections) }
    }

    /// Cancels `connection` if it has not done the handshake after
    /// ``ProviderConfiguration/handshakeTimeout``, counted from now.
    ///
    /// The deadline lives here and not inside ``handle(_:from:)``, because ``handle(_:from:)``
    /// must not suspend. The deadline is an independent task that only *reads* the connection's
    /// claim state when it fires. A connection with a completed handshake is claimed by then, and
    /// a connection that already ended is terminated. In both cases the deadline does nothing.
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

    /// Marks a connection as terminated, synchronously on the listener queue. Thus a hello that
    /// is still on its way to the actor can never claim the connection. The method also
    /// schedules the cleanup of the connection's session on the actor, if it had one.
    private nonisolated func terminate(_ connection: LinkConnection) {
        pending.withLock { $0.markTerminated(connection) }
        Task { await self.handleTermination(of: connection) }
    }

    // MARK: - Handshake

    /// Handles the first message that a connection sends: its ``BLESwiftLink/ClientHello``.
    ///
    /// The connection's entry already holds everything that the client sent behind that hello.
    /// The method constructs the session. The construction installs the session's handler in
    /// that entry and replays the backlog to it. The session then writes the accepted
    /// `ServerHello` as its first frame. Thus the hello still comes before every event on the
    /// wire, and no window exists in which a request has no destination.
    ///
    /// - Important: This method must not suspend. It claims the connection, installs its
    ///   session, and hands over its messages in one uninterrupted actor step. Thus a
    ///   termination is seen in only two ways: entirely before the claim, which then fails, or
    ///   entirely after the session exists, which the method then closes.
    private func handle(_ message: LinkMessage, from connection: LinkConnection) {
        // Do not open a session for a connection that the provider accepted while or after
        // `stop()` ran. `stop()` empties the connection table, so an acceptance that raced it
        // would leave a live session on a provider that no longer listens.
        guard listener != nil else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        guard pending.withLock({ $0.isClaimable(connection) }) else {
            // Either the session that a completed handshake installed now owns this connection's
            // messages, or the connection has already terminated.
            return
        }
        // Every rejection below leaves the entry in `pending`, so the provider retains the
        // connection until its terminal state releases it. This gives the rejection time to
        // reach the socket. A claim followed by a cancel would race with the rejection.
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
        // Only an accepted handshake claims the connection. From here, its session owns the
        // messages, and the entry routes them to the session, not back to this method.
        guard pending.withLock({ $0.claim(connection) }) else { return }
        let accepted = ServerHello(
            protocolVersion: LinkProtocol.version,
            accepted: true,
            reason: nil,
            providerName: configuration.providerName
        )
        // Install the session's handler in the connection's entry. Replay what arrived behind
        // the hello, in order, before delivering any newer message.
        //
        // The replay runs *outside* the table's lock, one batch at a time. The entry holds
        // anything that arrives meanwhile, because the listener queue keeps routing into it, and
        // the next turn of this loop takes it. Thus the order is kept, the code never calls a
        // session's handler under the lock, and this method stays free of suspension.
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
            let queue = DispatchQueue(label: "bleswift-provider.central.\(sessionOrdinal)")
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
            let queue = DispatchQueue(label: "bleswift-provider.host.\(sessionOrdinal)")
            // Report the identity back in the hello. The client asked to be hosted under an
            // identity, and only the provider knows whether it got it.
            let identifier = hostedIdentifier(for: hello)
            var hosted = accepted
            hosted.assignedHostIdentifier = identifier
            sessions[key] = HostSession(
                connection: connection,
                backend: makePeripheralBackend(
                    queue: queue,
                    clientName: hello.clientName,
                    identifier: identifier
                ),
                queue: queue,
                ordinal: sessionOrdinal,
                hello: hosted,
                install: install,
                log: configuration.log
            )
            configuration.log?("opened host session \(sessionOrdinal) for \(hello.clientName)")
        }
    }

    /// The identity under which to host a peripheral client's device. It is the identity in the
    /// client's ``BLESwiftLink/ClientHello``, or a new `UUID` if the client asked for none.
    ///
    /// The provider refuses an identifier that one of its own devices holds, such as a fixture.
    /// Registering over it would replace the fixture's database and make the provider's handle
    /// stale. The provider uses a new identifier, and the client is still hosted.
    ///
    /// The test is ``providerOwnedIdentifiers``, not ``VirtualRadio/knownDeviceIDs``. A client that
    /// redials before the removal of its old device has run must keep its identity. Registering
    /// again is safe, because the radio's generation guard ignores the old session's teardown.
    private func hostedIdentifier(for hello: ClientHello) -> UUID {
        guard let requested = hello.hostIdentifier else { return UUID() }
        guard providerOwnedIdentifiers.contains(requested) else { return requested }
        let replacement = UUID()
        configuration.log?(
            "\(hello.clientName) asked to be hosted as \(requested), which the provider hosts "
                + "itself; hosting it as \(replacement)"
        )
        return replacement
    }

    /// Drops a connection that reached a terminal state. It closes the connection's session, if
    /// there was one, and releases the strong reference that the pending table held.
    private func handleTermination(of connection: LinkConnection) {
        let key = ObjectIdentifier(connection)
        pending.withLock { $0.release(connection) }
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.close()
        configuration.log?("closed \(session.label)")
    }

    /// Builds the backend for one central-role session, on the session's queue.
    private func makeCentralBackend(queue: DispatchQueue) -> any CentralManaging {
        guard configuration.passthrough else {
            return queue.sync { VirtualCentralBackend(radio: radio, queue: queue) }
        }
        // Use the host's CoreBluetooth by default. An injected factory overrides it.
        let factory = configuration.centralBackendFactory ?? CoreBluetoothBackends.makeCentral
        // Use one hop and not three. A real `CBCentralManager` delivers its first
        // `didUpdateState` when the queue yields, so the composite must be wired onto it before
        // this block returns. See ``CoreBluetoothBackends``.
        return queue.sync {
            let virtual = VirtualCentralBackend(radio: radio, queue: queue)
            let real = factory(queue)
            return CompositeCentral(backends: [virtual, real], onQueue: queue, log: configuration.log)
        }
    }

    /// Builds the backend for one peripheral-role session, on the session's queue.
    ///
    /// The virtual half registers a device on ``radio`` under `identifier`, with the client's
    /// name. Thus a central-role session's scan sees the remote `PeripheralHost` as it sees a
    /// fixture.
    ///
    /// - Parameters:
    ///   - queue: The session's own serial queue.
    ///   - clientName: The name under which the hosted device advertises itself.
    ///   - identifier: The identity under which to host the device. It is the identity that the
    ///     client asked for in its ``BLESwiftLink/ClientHello``, so its reconnect is the same
    ///     device to every central that had seen it.
    private func makePeripheralBackend(
        queue: DispatchQueue,
        clientName: String,
        identifier: UUID
    ) -> any PeripheralManaging {
        guard configuration.passthrough else {
            return queue.sync {
                VirtualPeripheralManagerBackend(radio: radio, queue: queue, identifier: identifier, name: clientName)
            }
        }
        // Use the host's CoreBluetooth by default. An injected factory overrides it.
        let factory = configuration.peripheralManagerBackendFactory ?? CoreBluetoothBackends.makePeripheralManager
        // Build and attach in one hop, for the reason that `makeCentralBackend` gives.
        return queue.sync {
            let virtual = VirtualPeripheralManagerBackend(
                radio: radio, queue: queue, identifier: identifier, name: clientName
            )
            let real = factory(queue)
            return CompositePeripheralManager(backends: [virtual, real], onQueue: queue, log: configuration.log)
        }
    }
}

/// The errors for the fixtures with which ``Provider/start()`` was configured.
public enum ProviderFixtureError: Error, Equatable, Sendable, CustomStringConvertible {

    /// Two configured fixtures declare the same `FixtureDevice/id`.
    case duplicateIdentifier(UUID)

    public var description: String {
        switch self {
        case .duplicateIdentifier(let identifier):
            "two fixture devices declare the same id \(identifier)"
        }
    }
}

/// The provider's table of accepted connections, and the router for their messages.
///
/// One `Mutex` on ``Provider`` guards this table. The code writes to it from the listener queue
/// *before* a connection's handlers exist, so the handshake does not depend on the order in
/// which unstructured `Task`s reach the actor.
///
/// An entry lives from the time the provider accepts its connection until the link ends. Every
/// message goes through the entry:
///
/// - The first message goes to the handshake on the actor.
/// - The entry holds the messages behind it until a session installs its handler and the replay
///   has drained them.
/// - The entry delivers every later message straight to the session on the listener queue.
///
/// The provider drops nothing between the hello and the session, and no message can overtake an
/// earlier one.
///
/// **Nothing is called while the lock is held.** Routing and installing only *decide*, and the
/// caller delivers afterwards. Thus a session's handler can do anything, including a call back
/// into this table, without a deadlock against the one `Mutex` that every connection shares.
struct PendingConnections {

    /// Where one message goes. The decision is synchronous, on the listener queue.
    enum Routing {
        /// Nowhere. The link has ended, the connection is unknown, or the table held the message
        /// for a session that has not installed its handler yet.
        case drop
        /// Nowhere, and the connection goes with it. If the table held this message, the
        /// backlog of the entry would exceed ``PendingConnections/maximumQueuedBytes``.
        case exceededBacklog
        /// Nowhere, and the connection goes with it. If the table held this message, the
        /// backlog of the entry would exceed ``PendingConnections/maximumQueued`` messages.
        case exceededQueueDepth
        /// To ``Provider/handle(_:from:)``. This is the connection's first message, its hello.
        case handshake
        /// To the session that owns this connection.
        case deliver(@Sendable (LinkMessage) -> Void)
    }

    /// One accepted connection. The entry records whether its link has ended and how far its
    /// handshake has progressed. It holds either its session's handler or the messages that wait
    /// for a handler.
    private struct Entry {
        /// The connection. The entry holds it strongly until ``release(_:)``, which also keeps
        /// its `ObjectIdentifier` from recycling while the key is in the table.
        let connection: LinkConnection
        /// Whether the link ended.
        var isTerminated = false
        /// Whether the code already routed the first message to the handshake. Thus a second
        /// hello cannot open a second session.
        var didRouteHello = false
        /// Whether an accepted handshake has claimed this connection.
        var isClaimed = false
        /// The session's message handler, once the session has one.
        var handler: (@Sendable (LinkMessage) -> Void)?
        /// Whether the code is replaying the backlog to ``handler``. A message that arrives
        /// during the replay joins ``queued`` and is not delivered, so it cannot overtake the
        /// backlog behind which it arrived. The caller that replays takes it.
        var isReplaying = false
        /// Messages that arrived behind the hello or during the replay. The entry holds them in
        /// order until the code has given them to ``handler``.
        var queued: [LinkMessage] = []
        /// The cost of ``queued``, by ``BLESwiftLink/LinkMessage/heldByteCount``. Thus the
        /// backlog has a size limit and not only a count limit.
        var queuedBytes = 0
    }

    /// The number of messages that one entry holds before the provider drops its connection.
    /// Only a connection with a handshake in progress, or one that the provider rejected and
    /// will cancel, queues messages. Thus this number is a ceiling for a misbehaving client and
    /// not a flow-control window.
    ///
    /// The provider answers this limit as it answers the byte cap: it drops the connection and
    /// not the message. A dropped message would leave a silent hole in an ordered stream. The
    /// client would believe that the provider accepted a request that it sent behind its own
    /// hello, and the session that opened a moment later would serve every neighboring message
    /// but not that one. A client that has put 256 messages behind an incomplete handshake is
    /// not a client whose session is only slow to open.
    static let maximumQueued = 256

    /// The number of bytes of held messages that one entry collects before the provider drops
    /// its connection.
    ///
    /// A count alone does not bound this backlog, because a frame carries up to
    /// ``BLESwiftLink/LinkFraming/maximumPayloadLength`` (1 MiB). A few hundred frames are
    /// hundreds of megabytes. This limit applies to each entry, in addition to the one partial
    /// frame that each of the ``ProviderConfiguration/maximumPendingConnections`` connections
    /// can buffer at the transport. A client with a megabyte outstanding behind its own hello
    /// fills the provider's memory before the provider has served it at all. As for the count,
    /// the provider drops the connection and not the message.
    static let maximumQueuedBytes = 1024 * 1024

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Records a connection that the provider just accepted, unless `limit` connections
    /// already wait for a handshake.
    ///
    /// Only unclaimed and unterminated entries count against `limit`. A connection that a
    /// session owns is no longer pending. A connection whose link has ended is on its way out.
    ///
    /// - Returns: `true` if the method recorded the connection.
    mutating func register(_ connection: LinkConnection, limit: Int) -> Bool {
        let awaiting = entries.values.count { !$0.isClaimed && !$0.isTerminated }
        guard awaiting < limit else { return false }
        entries[ObjectIdentifier(connection)] = Entry(connection: connection)
        return true
    }

    /// Decides where `message` goes. If the answer is "nowhere yet", the method holds the
    /// message.
    ///
    /// - Returns: The routing to apply, on the listener queue, before routing the next message.
    ///
    /// - Returns: The routing to apply, on the listener queue, before the code routes the next
    ///   message.
    mutating func route(_ message: LinkMessage, from connection: LinkConnection) -> Routing {
        let key = ObjectIdentifier(connection)
        guard var entry = entries[key], !entry.isTerminated else { return .drop }
        if let handler = entry.handler, !entry.isReplaying { return .deliver(handler) }
        defer { entries[key] = entry }
        guard entry.didRouteHello else {
            entry.didRouteHello = true
            return .handshake
        }
        // Both caps release the backlog here and not at the termination that follows. The
        // caller cancels the connection when either cap returns, and nothing is served from a
        // backlog whose connection is on its way out.
        guard entry.queued.count < Self.maximumQueued else {
            entry.queued = []
            entry.queuedBytes = 0
            return .exceededQueueDepth
        }
        let cost = message.heldByteCount
        guard entry.queuedBytes + cost <= Self.maximumQueuedBytes else {
            entry.queued = []
            entry.queuedBytes = 0
            return .exceededBacklog
        }
        entry.queued.append(message)
        entry.queuedBytes += cost
        return .drop
    }

    /// Installs `handler` as the destination of `connection`, and takes the backlog that the
    /// entry held for it.
    ///
    /// The method *returns* the backlog and does not deliver it, because nothing is called while
    /// the table is locked. Thus a session's handler, and anything that it calls, stays out of
    /// the lock's critical section. The entry's replaying flag keeps the order, whatever the
    /// lock hold time. From here until ``finishReplay(for:)`` says otherwise, a message that
    /// arrives on the listener queue joins the queue and is not delivered, so it cannot overtake
    /// the backlog behind which it arrived. The caller must drain the backlog to completion. See
    /// the installer in ``Provider/handle(_:from:)``.
    ///
    /// - Returns: The messages to replay, oldest first, or `nil` for a connection whose link has
    ///   already ended. Its session will close soon, and the method installs nothing.
    mutating func beginReplay(_ handler: @escaping @Sendable (LinkMessage) -> Void, for connection: LinkConnection) -> [LinkMessage]? {
        let key = ObjectIdentifier(connection)
        guard var entry = entries[key], !entry.isTerminated else { return nil }
        entry.handler = handler
        entry.isReplaying = true
        let queued = entry.queued
        entry.queued = []
        entry.queuedBytes = 0
        entries[key] = entry
        return queued
    }

    /// Takes what arrived while the code replayed the previous batch.
    ///
    /// - Returns: The next batch to replay, oldest first. The value is `nil` when no batch is
    ///   left. Then the entry stops holding messages and routes them to its handler directly.
    ///   The value is also `nil` for a connection whose link ended during the replay, because
    ///   the code delivers nothing more to a session that will close soon.
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
        entry.queuedBytes = 0
        entries[key] = entry
        return queued
    }

    /// Whether `connection` still waits for a handshake and has not terminated. Thus the
    /// provider ignores a hello that lost the race to its own connection's teardown, and the
    /// hello does not resurrect the connection.
    ///
    /// This method does not mutate, so the code can recognize a handshake that it will *reject*
    /// without releasing the connection. The rejection must still be written to that connection.
    func isClaimable(_ connection: LinkConnection) -> Bool {
        guard let entry = entries[ObjectIdentifier(connection)] else { return false }
        return !entry.isTerminated && !entry.isClaimed
    }

    /// Claims `connection` for a completed handshake.
    ///
    /// The entry stays in the table. It routes the connection's messages to the session that
    /// will ``install(_:for:)`` its handler, and it holds the messages that arrive in between.
    ///
    /// - Returns: `true` only if the connection was unclaimed and had not terminated, as
    ///   ``isClaimable(_:)`` reports.
    mutating func claim(_ connection: LinkConnection) -> Bool {
        let key = ObjectIdentifier(connection)
        guard isClaimable(connection) else { return false }
        entries[key]?.isClaimed = true
        return true
    }

    /// Marks the link of `connection` as ended. The method drops its handler and everything
    /// that the entry still holds for it, because nothing is delivered to a session whose link
    /// is gone.
    mutating func markTerminated(_ connection: LinkConnection) {
        let key = ObjectIdentifier(connection)
        entries[key]?.isTerminated = true
        entries[key]?.handler = nil
        entries[key]?.queued = []
        entries[key]?.queuedBytes = 0
    }

    /// Drops `connection` from the table and releases the strong reference that held it.
    mutating func release(_ connection: LinkConnection) {
        entries.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Empties the table and returns every connection that was in it, including the connections
    /// that are still in the handshake and the connections that a session already owns.
    /// `stop()` cancels all of them.
    mutating func drain() -> [LinkConnection] {
        defer { entries.removeAll() }
        return entries.values.map(\.connection)
    }
}
#endif
