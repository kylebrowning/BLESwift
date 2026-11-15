//
//  ProviderStatusTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwiftLink
import BLESwiftProvider
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// The status request of a ``LinkRole/monitor`` client, from ``ProviderStatusClient`` to a live
/// ``Provider`` and back.
@Suite("Provider status")
struct ProviderStatusTests {

    private static let sample = ProviderStatus(
        providerName: "bleswift-provider",
        passthrough: true,
        fixtureDeviceCount: 2,
        sessions: [
            ProviderStatus.Session(ordinal: 1, role: .central, clientName: "MyApp (iPhone 17)"),
            ProviderStatus.Session(ordinal: 3, role: .peripheral, clientName: "Advertiser"),
        ]
    )

    /// Opens a connection to `port` that sends a hello for `role` and waits for the server hello.
    /// The caller cancels the returned connection.
    private func openSession(port: UInt16, role: LinkRole, name: String) async -> LinkConnection {
        let received = Mutex(false)
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "status.\(name)")
        )
        connection.onMessage = { message in
            if case .serverHello = message { received.withLock { $0 = true } }
        }
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: role,
                clientName: name
            )))
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { received.withLock { $0 } }
        return connection
    }

    @Test("ProviderStatus round-trips through every codec", arguments: LinkCodec.allCases)
    func codableRoundTrip(codec: LinkCodec) throws {
        let decoded = try codec.decode(ProviderStatus.self, from: codec.encode(Self.sample))
        #expect(decoded == Self.sample)
        let message = LinkMessage.providerStatus(Self.sample)
        #expect(try codec.decode(LinkMessage.self, from: codec.encode(message)) == message)
    }

    @Test("A status request lists the live sessions with their ordinals and roles")
    func roundTrip() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.providerName = "status-test"
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let port = await provider.port

        let central = await openSession(port: port, role: .central, name: "central-client")
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        let host = await openSession(port: port, role: .peripheral, name: "host-client")
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 2 }

        let status = try await bounded {
            try await ProviderStatusClient.fetch(endpoint: LinkEndpoint(host: "127.0.0.1", port: port))
        }
        #expect(status == ProviderStatus(
            providerName: "status-test",
            passthrough: false,
            fixtureDeviceCount: 0,
            sessions: [
                ProviderStatus.Session(ordinal: 1, role: .central, clientName: "central-client"),
                ProviderStatus.Session(ordinal: 2, role: .peripheral, clientName: "host-client"),
            ]
        ))
        // The monitor client opens no session of its own.
        #expect(await provider.sessionCount == 2)

        central.cancel()
        host.cancel()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A status request to a closed port is unreachable")
    func closedPortIsUnreachable() async throws {
        let port = try closedPort()
        do {
            _ = try await bounded {
                try await ProviderStatusClient.fetch(endpoint: LinkEndpoint(host: "127.0.0.1", port: port))
            }
            Issue.record("a closed port must not give a status")
        } catch let error as ProviderStatusError {
            guard case .unreachable = error else {
                Issue.record("expected unreachable, got \(error)")
                return
            }
        }
    }

    @Test("A listener that closes without a hello rejects the status request")
    func closeWithoutAHelloIsRejected() async throws {
        // This listener acts as an older provider. It reads the hello and closes the connection
        // with no reply.
        let queue = DispatchQueue(label: "status.older")
        let listener = try LinkListener(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: 0),
            codec: .binaryPropertyList,
            queue: queue
        )
        let accepted = Mutex<[LinkConnection]>([])
        listener.onConnection = { connection in
            accepted.withLock { $0.append(connection) }
            connection.onMessage = { [weak connection] _ in connection?.cancel() }
        }
        try await listener.start()
        defer { listener.cancel() }
        do {
            _ = try await bounded {
                try await ProviderStatusClient.fetch(endpoint: LinkEndpoint(host: "127.0.0.1", port: listener.port))
            }
            Issue.record("a listener with no reply must not give a status")
        } catch let error as ProviderStatusError {
            #expect(error == .rejected(
                "the provider closed the connection without a reply. It may be older than this tool."
            ))
        }
    }

    @Test("The handshake deadline closes a monitor connection that the client keeps open")
    func deadlineClosesAnOpenMonitor() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.handshakeTimeout = .milliseconds(200)
        let lines = Mutex<[String]>([])
        configuration.log = { line in lines.withLock { $0.append(line) } }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let status = Mutex<ContinuousClock.Instant?>(nil)
        let closed = Mutex<ContinuousClock.Instant?>(nil)
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "status.open")
        )
        connection.onMessage = { message in
            if case .providerStatus = message { status.withLock { $0 = .now } }
        }
        connection.onStateChange = { [weak connection] state in
            switch state {
            case .ready:
                connection?.send(.clientHello(ClientHello(
                    protocolVersion: LinkProtocol.version,
                    role: .monitor,
                    clientName: "open-monitor"
                )))
            case .cancelled, .failed:
                closed.withLock { $0 = .now }
            case .idle, .connecting:
                break
            }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { closed.withLock { $0 } != nil }
        let statusTime = try #require(status.withLock { $0 })
        let closeTime = try #require(closed.withLock { $0 })
        // The provider does not close a monitor connection after the status. Only the deadline
        // closes it, 200 ms after the connection opened.
        #expect(closeTime - statusTime >= .milliseconds(150))
        #expect(lines.withLock { $0 }.contains("closing a monitor connection that stayed open"))
        #expect(!lines.withLock { $0 }.contains { $0.hasPrefix("releasing a connection that sent no client hello") })
        #expect(await provider.sessionCount == 0)
        await provider.stop()
    }
}
#endif
