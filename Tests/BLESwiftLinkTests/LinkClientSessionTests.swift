//
//  LinkClientSessionTests.swift
//  BLESwiftLinkTests
//

// Sockets in a CI simulator are not reliable: a wedged simulator network leaves a loopback connect
// in `.connecting` for tens of seconds. So the compiler removes every socket suite from the
// simulator build. The two-simulator E2E covers that path.
#if !targetEnvironment(simulator)
import BLESwiftLink
import BLESwiftSimulatorLink
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// What a stand-in provider recorded. The helpers carry it out by reference.
///
/// A `Mutex` is noncopyable, so it cannot be a tuple element. This box also keeps the accepted
/// server-side connection, because cancelling a `LinkListener` leaves accepted connections alone,
/// while a provider that goes away really closes that connection.
private final class ServerLog: Sendable {
    private let hellos = Mutex<[ClientHello]>([])
    private let connection = Mutex<LinkConnection?>(nil)

    func withLock<T: Sendable>(_ body: (inout [ClientHello]) -> T) -> T {
        hellos.withLock { hellos in body(&hellos) }
    }

    /// The connection that the provider accepted most recently, so a test can drop it the way a
    /// provider would.
    var acceptedConnection: LinkConnection? { connection.withLock { $0 } }

    func record(_ connection: LinkConnection) {
        self.connection.withLock { $0 = connection }
    }
}

@Suite("LinkClientSession")
struct LinkClientSessionTests {

    /// A minimal stand-in for a provider. It accepts or rejects the hello and echoes everything
    /// else.
    private func makeServer(accept: Bool, version: Int = LinkProtocol.version) async throws -> (LinkListener, ServerLog) {
        let hellos = ServerLog()
        let listener = try LinkListener(endpoint: LinkEndpoint(host: "127.0.0.1", port: 0), codec: .json, queue: DispatchQueue(label: "srv"))
        listener.onConnection = { connection in
            hellos.record(connection)
            connection.onMessage = { message in
                if case .clientHello(let hello) = message {
                    hellos.withLock { $0.append(hello) }
                    connection.send(.serverHello(ServerHello(protocolVersion: version, accepted: accept, reason: accept ? nil : "no", providerName: "test")))
                    if !accept { connection.cancel() }
                } else {
                    connection.send(message)
                }
            }
        }
        try await listener.start()
        return (listener, hellos)
    }

    @Test("Handshakes, reports connected, and passes messages")
    func connects() async throws {
        let (listener, hellos) = try await makeServer(accept: true)
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "client")
        let session = LinkClientSession(endpoint: LinkEndpoint(host: "127.0.0.1", port: listener.port), role: .peripheral, clientName: "unit", queue: queue)
        let received = Mutex<[LinkMessage]>([])
        session.onMessage = { message in received.withLock { $0.append(message) } }
        session.start()
        await waitFor { session.isConnected }
        #expect(session.isConnected)
        #expect(hellos.withLock { $0 } == [ClientHello(protocolVersion: LinkProtocol.version, role: .peripheral, clientName: "unit")])
        session.send(.hostRequest(.stopAdvertising))
        await waitFor { received.withLock { $0.count } == 1 }
        #expect(received.withLock { $0 } == [.hostRequest(.stopAdvertising)])
        session.stop()
    }

    @Test("Retries until a provider appears")
    func retries() async throws {
        // Use a port below the ephemeral range, so a parallel test's `port: 0` listener cannot
        // receive it and answer the dial that must be refused. An unrelated process can still take
        // the port between the probe and the bind, so the test makes several attempts.
        for _ in 0..<5 {
            let port = try closedPort()
            let queue = DispatchQueue(label: "client")
            let session = LinkClientSession(endpoint: LinkEndpoint(host: "127.0.0.1", port: port), role: .central, clientName: "unit", queue: queue, retryInterval: .milliseconds(50))
            session.start()
            try await Task.sleep(for: .milliseconds(200))
            #expect(!session.isConnected)
            guard let listener = try? LinkListener(endpoint: LinkEndpoint(host: "127.0.0.1", port: port), codec: .json, queue: DispatchQueue(label: "srv")) else {
                session.stop()
                continue
            }
            listener.onConnection = { connection in
                connection.onMessage = { _ in connection.send(.serverHello(ServerHello(protocolVersion: LinkProtocol.version, accepted: true, reason: nil, providerName: "t"))) }
            }
            do {
                try await listener.start()
            } catch {
                listener.cancel()
                session.stop()
                continue
            }
            defer { listener.cancel() }
            await waitFor(timeout: .seconds(3)) { session.isConnected }
            #expect(session.isConnected)
            session.stop()
            return
        }
        Issue.record("could not hold on to a free port for the retry test")
    }

    @Test("The opening burst reaches a provider that appears late, at the default interval")
    func fastRetryFindsALateProvider() async throws {
        // The DEFAULT two-second retry interval is under test. Without the opening burst, a client
        // would not find a provider that appears half a second in until 1.5 s later.
        for _ in 0..<5 {
            let port = try closedPort()
            let queue = DispatchQueue(label: "client")
            let session = LinkClientSession(
                endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
                role: .central,
                clientName: "unit",
                queue: queue
            )
            session.start()
            try await Task.sleep(for: .milliseconds(500))
            #expect(!session.isConnected)

            guard let listener = try? LinkListener(endpoint: LinkEndpoint(host: "127.0.0.1", port: port), codec: .json, queue: DispatchQueue(label: "srv")) else {
                session.stop()
                continue
            }
            listener.onConnection = { connection in
                connection.onMessage = { _ in
                    connection.send(.serverHello(ServerHello(protocolVersion: LinkProtocol.version, accepted: true, reason: nil, providerName: "t")))
                }
            }
            do {
                try await listener.start()
            } catch {
                listener.cancel()
                session.stop()
                continue
            }
            defer { listener.cancel() }
            await waitFor(timeout: .seconds(1)) { session.isConnected }
            #expect(session.isConnected)
            session.stop()
            return
        }
        Issue.record("could not hold on to a free port for the fast-retry test")
    }

    /// A weak handle on one of the connections that a session dialed.
    private struct WeakConnection: Sendable {
        weak var connection: LinkConnection?
    }

    @Test("A session retrying against a closed port releases every connection it creates", .timeLimit(.minutes(1)))
    func retryingReleasesItsConnections() async throws {
        // Use a port below the ephemeral range. The dials must keep failing, and they would not if
        // a parallel test received this port and bound a listener on it.
        let port = try closedPort()
        let queue = DispatchQueue(label: "client")
        let session = LinkClientSession(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            role: .central,
            clientName: "unit",
            queue: queue,
            retryInterval: .milliseconds(50)
        )
        // `dial()` stores handlers that capture their own connection strongly, so the system can
        // never release a connection whose handlers survive its terminal state.
        let dialled = Mutex<[WeakConnection]>([])
        let (dials, dialSignal) = AsyncStream<Void>.makeStream()
        session.onDial = { connection in
            dialled.withLock { $0.append(WeakConnection(connection: connection)) }
            dialSignal.yield()
        }
        session.start()
        // The test waits for the retry itself (#88), not for a fixed window, because under a loaded
        // bundle 700 ms could close before the second dial. It checks that the client retried and
        // that the test released every connection the client made.
        var nextDial = dials.makeAsyncIterator()
        await nextDial.next()
        await nextDial.next()
        session.stop()
        dialSignal.finish()
        #expect(!session.isConnected)

        let observed = dialled.withLock { $0 }
        #expect(observed.count >= 2, "only \(observed.count) dials observed")
        // The system releases each connection after the session's queue has processed its terminal
        // state. The test waits for this with an upper bound and does not sleep.
        await waitFor(timeout: .seconds(10)) { observed.allSatisfy { $0.connection == nil } }
        let alive = observed.filter { $0.connection != nil }.count
        #expect(alive == 0, "\(alive) of \(observed.count) connections still alive")
    }

    @Test("Reconnects after the provider drops, reporting disconnect first")
    func reconnects() async throws {
        let (listener, server) = try await makeServer(accept: true)
        let queue = DispatchQueue(label: "client")
        let session = LinkClientSession(endpoint: LinkEndpoint(host: "127.0.0.1", port: listener.port), role: .central, clientName: "unit", queue: queue, retryInterval: .milliseconds(50))
        let connects = Mutex(0), disconnects = Mutex(0)
        session.onConnected = { _ in connects.withLock { $0 += 1 } }
        session.onDisconnected = { _ in disconnects.withLock { $0 += 1 } }
        session.start()
        await waitFor { connects.withLock { $0 } == 1 }
        // A provider that goes away closes its sessions' connections and then stops listening.
        // Cancelling the listener alone leaves the accepted connection open, by design.
        server.acceptedConnection?.cancel()
        listener.cancel()
        await waitFor(timeout: .seconds(3)) { disconnects.withLock { $0 } == 1 }
        let (listener2, _) = try await makeServerOnPort(listener.port, accept: true)
        defer { listener2.cancel() }
        await waitFor(timeout: .seconds(3)) { connects.withLock { $0 } == 2 }
        #expect(connects.withLock { $0 } == 2)
        session.stop()
    }

    @Test("Version mismatch reports disconnect and stops retrying")
    func versionMismatch() async throws {
        let (listener, hellos) = try await makeServer(accept: true, version: LinkProtocol.version + 1)
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "client")
        let session = LinkClientSession(endpoint: LinkEndpoint(host: "127.0.0.1", port: listener.port), role: .central, clientName: "unit", queue: queue, retryInterval: .milliseconds(30))
        let errors = Mutex<[NSError?]>([])
        session.onDisconnected = { error in errors.withLock { $0.append(error) } }
        session.start()
        await waitFor { errors.withLock { $0.count } >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(hellos.withLock { $0.count } == 1)     // no second attempt
        #expect(errors.withLock { $0.first.flatMap { $0 }?.code } == LinkError.protocolVersionMismatch(remote: 0).code)
        #expect(!session.isConnected)
        session.stop()
    }

    private func makeServerOnPort(_ port: UInt16, accept: Bool) async throws -> (LinkListener, ServerLog) {
        let hellos = ServerLog()
        let listener = try LinkListener(endpoint: LinkEndpoint(host: "127.0.0.1", port: port), codec: .json, queue: DispatchQueue(label: "srv2"))
        listener.onConnection = { connection in
            hellos.record(connection)
            connection.onMessage = { message in
                if case .clientHello(let hello) = message {
                    hellos.withLock { $0.append(hello) }
                    connection.send(.serverHello(ServerHello(protocolVersion: LinkProtocol.version, accepted: accept, reason: nil, providerName: "t")))
                }
            }
        }
        try await listener.start()
        return (listener, hellos)
    }
}
#endif
