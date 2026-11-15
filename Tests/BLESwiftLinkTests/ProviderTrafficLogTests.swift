//
//  ProviderTrafficLogTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwiftLink
import BLESwiftProvider
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// The traffic log that ``ProviderConfiguration/logTraffic`` turns on, and the summary that each
/// log line uses.
@Suite("Provider traffic log")
struct ProviderTrafficLogTests {

    /// Collects the log lines of a provider off its actor.
    private final class LogLines: Sendable {
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    /// Starts a provider on a loopback port that the system selects.
    private func makeProvider(logTraffic: Bool, lines: LogLines) async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.logTraffic = logTraffic
        configuration.log = { lines.append($0) }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    /// Opens a central-role connection to `provider`, sends a hello, and waits for the server
    /// hello. The caller cancels the returned connection.
    private func handshake(with provider: Provider) async throws -> LinkConnection {
        let received = Mutex(false)
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "traffic.client")
        )
        connection.onMessage = { message in
            if case .serverHello = message { received.withLock { $0 = true } }
        }
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .central,
                clientName: "traffic"
            )))
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { received.withLock { $0 } }
        #expect(received.withLock { $0 })
        return connection
    }

    @Test("A short summary is the message's description")
    func shortSummary() {
        let message = LinkMessage.centralRequest(.stopScan)
        #expect(message.trafficSummary == String(describing: message))
    }

    @Test("A long summary keeps 240 characters and adds an ellipsis")
    func longSummaryIsTruncated() {
        let message = LinkMessage.clientHello(ClientHello(
            protocolVersion: LinkProtocol.version,
            role: .central,
            clientName: String(repeating: "x", count: 500)
        ))
        let description = String(describing: message)
        #expect(description.count > 240)
        let summary = message.trafficSummary
        #expect(summary.count == 241)
        #expect(summary.hasSuffix("…"))
        #expect(summary.dropLast() == description.prefix(240))
    }

    @Test("A provider with logTraffic logs each direction of a handshake")
    func logsTheHandshake() async throws {
        let lines = LogLines()
        let provider = try await makeProvider(logTraffic: true, lines: lines)
        let connection = try await handshake(with: provider)
        await waitFor(timeout: .seconds(5)) {
            lines.all.contains { $0.hasPrefix("link 1 -> serverHello(") }
        }
        #expect(lines.all.contains { $0.hasPrefix("link 1 <- clientHello(") })
        #expect(lines.all.contains { $0.hasPrefix("link 1 -> serverHello(") })
        #expect(lines.all.contains("link 1 is central session 1"))
        connection.cancel()
        await provider.stop()
    }

    @Test("A provider without logTraffic logs no link lines")
    func logsNothingWhenOff() async throws {
        let lines = LogLines()
        let provider = try await makeProvider(logTraffic: false, lines: lines)
        let connection = try await handshake(with: provider)
        await waitFor(timeout: .seconds(5)) {
            lines.all.contains { $0.hasPrefix("opened central session") }
        }
        #expect(lines.all.contains { $0.hasPrefix("opened central session") })
        #expect(!lines.all.contains { $0.hasPrefix("link ") })
        connection.cancel()
        await provider.stop()
    }
}
#endif
