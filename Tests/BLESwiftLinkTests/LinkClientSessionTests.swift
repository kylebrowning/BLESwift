//
//  LinkClientSessionTests.swift
//  BLESwiftLinkTests
//

import BLESwiftLink
import BLESwiftSimulatorLink
import Dispatch
import Foundation
import Synchronization
import Testing

/// What a stand-in provider recorded, carried out of the helpers by reference.
///
/// A `Mutex` is noncopyable and so cannot be a tuple element, hence the box; it exposes the same
/// `withLock` shape the tests use for the hellos everywhere else. It also keeps the accepted
/// server-side connection, because cancelling a `LinkListener` deliberately leaves accepted
/// connections alone — closing that connection is what a provider going away actually looks like.
private final class ServerLog: Sendable {
    private let hellos = Mutex<[ClientHello]>([])
    private let connection = Mutex<LinkConnection?>(nil)

    func withLock<T: Sendable>(_ body: (inout [ClientHello]) -> T) -> T {
        hellos.withLock { hellos in body(&hellos) }
    }

    /// The most recently accepted connection, so a test can drop it the way a provider would.
    var acceptedConnection: LinkConnection? { connection.withLock { $0 } }

    func record(_ connection: LinkConnection) {
        self.connection.withLock { $0 = connection }
    }
}

@Suite("LinkClientSession")
struct LinkClientSessionTests {

    /// A minimal provider stand-in: accepts or rejects the hello, echoes everything else.
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
        let queue = DispatchSerialQueue(label: "client")
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
        // A port the system just handed out and released, rather than a fixed number another
        // process — or another run of this suite — could be sitting on. Releasing it does mean
        // something else can take it before this test binds it, so each attempt starts over
        // with a fresh one.
        for _ in 0..<5 {
            let port = try await Self.freePort()
            let queue = DispatchSerialQueue(label: "client")
            let session = LinkClientSession(endpoint: LinkEndpoint(host: "127.0.0.1", port: port), role: .central, clientName: "unit", queue: queue, retryInterval: .milliseconds(50))
            session.start()
            try await Task.sleep(for: .milliseconds(200))
            guard !session.isConnected else {
                // Something else answered on that port; it was never ours to test with.
                session.stop()
                continue
            }
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

    /// A weak handle on one of the connections a session dialled.
    private struct WeakConnection: Sendable {
        weak var connection: LinkConnection?
    }

    @Test("A session retrying against a closed port releases every connection it creates")
    func retryingReleasesItsConnections() async throws {
        let port = try await Self.freePort()
        let queue = DispatchSerialQueue(label: "client")
        let session = LinkClientSession(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            role: .central,
            clientName: "unit",
            queue: queue,
            retryInterval: .milliseconds(50)
        )
        // `dial()` stores handlers that capture their own connection strongly, so a connection
        // whose handlers survive its terminal state can never be released.
        let dialled = Mutex<[WeakConnection]>([])
        session.onDial = { connection in dialled.withLock { $0.append(WeakConnection(connection: connection)) } }
        session.start()
        try await Task.sleep(for: .milliseconds(700))
        session.stop()
        #expect(!session.isConnected)

        let observed = dialled.withLock { $0 }
        #expect(observed.count >= 5, "only \(observed.count) dials observed")
        try await Task.sleep(for: .milliseconds(300))
        let alive = observed.filter { $0.connection != nil }.count
        #expect(alive == 0, "\(alive) of \(observed.count) connections still alive")
    }

    /// A loopback port nothing is bound to: taken by a listener on port 0, read back, and
    /// released again.
    private static func freePort() async throws -> UInt16 {
        let listener = try LinkListener(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: 0),
            codec: .json,
            queue: DispatchQueue(label: "freeport")
        )
        try await listener.start()
        let port = listener.port
        listener.cancel()
        return port
    }

    @Test("Reconnects after the provider drops, reporting disconnect first")
    func reconnects() async throws {
        let (listener, server) = try await makeServer(accept: true)
        let queue = DispatchSerialQueue(label: "client")
        let session = LinkClientSession(endpoint: LinkEndpoint(host: "127.0.0.1", port: listener.port), role: .central, clientName: "unit", queue: queue, retryInterval: .milliseconds(50))
        let connects = Mutex(0), disconnects = Mutex(0)
        session.onConnected = { connects.withLock { $0 += 1 } }
        session.onDisconnected = { _ in disconnects.withLock { $0 += 1 } }
        session.start()
        await waitFor { connects.withLock { $0 } == 1 }
        // A provider going away closes its sessions' connections and then stops listening;
        // cancelling the listener alone leaves the accepted connection open, by design.
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
        let queue = DispatchSerialQueue(label: "client")
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
