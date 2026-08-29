//
//  HostSessionLimitsTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
import BLESwiftTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

/// What a peripheral-role session refuses to hold on a misbehaving client's behalf — the
/// counterpart to `CentralSessionLimitsTests` for the notification queue — and what it
/// refuses to pass on from a malformed request.
@Suite("Host session limits")
struct HostSessionLimitsTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are unreliable; the simulator-side path is covered by the
    // two-simulator E2E on real simulators.

    @Test("A client that queues past the update window loses its session")
    func updateWindowOverrunClosesTheSession() async throws {
        // One more than the cap, plus the window the composite backend in front of the fake
        // accepts and drains before it starts refusing — those never sit in the queue this
        // cap counts.
        let overrun = HostSession.maximumPendingUpdates + LinkFlowControl.updateValueWindow + 1
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        // `peripheralManagerBackendFactory` stands in for the host's real CoreBluetooth,
        // which only a passthrough provider builds.
        configuration.passthrough = true
        configuration.peripheralManagerBackendFactory = { queue in
            // Back-pressured from the start: every offer is refused and no
            // `readyToUpdateSubscribers` ever follows, so the session's queue grows exactly
            // as fast as the client fills it.
            let fake = FakePeripheralManager(queue: queue, state: .poweredOn)
            // Far more refusals than this test can consume: the composite in front of the
            // fake re-offers a parked push every time the virtual backend reports itself
            // ready, so the script has to outlast those retries as well.
            fake.scriptedUpdateValueReturns = Array(repeating: false, count: 100_000)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        // Straight down the link, behind `LinkPeripheralManager`'s back: its own
        // `updateValue` honors the window, which is the point — only a client that has
        // stopped honoring it can reach this.
        let connection = LinkConnection.connect(
            to: endpoint,
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "hostsession.updatewindow")
        )
        let accepted = Mutex(false)
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .peripheral,
                clientName: "greedy-host"
            )))
        }
        connection.onMessage = { message in
            guard case .serverHello(let hello) = message, hello.accepted else { return }
            accepted.withLock { $0 = true }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { accepted.withLock { $0 } }
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        #expect(await provider.sessionCount == 1)

        for sequence in 0..<overrun {
            connection.send(.hostRequest(.updateValue(
                sequence: UInt64(sequence),
                value: Data([0x01]),
                characteristic: WireCharacteristicRef(Self.measurement),
                centrals: nil
            )))
        }

        // The session goes, rather than the provider's memory.
        await waitFor(timeout: .seconds(10)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    @Test("A respond carrying an ATT code no ATTError holds loses the session")
    func unknownATTErrorClosesTheSession() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        // Straight down the link, behind `LinkPeripheralManager`'s back: its own `respond`
        // can only ever send a code an `ATTError` already held.
        let connection = LinkConnection.connect(
            to: endpoint,
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "hostsession.atterror")
        )
        let accepted = Mutex(false)
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .peripheral,
                clientName: "malformed-host"
            )))
        }
        connection.onMessage = { message in
            guard case .serverHello(let hello) = message, hello.accepted else { return }
            accepted.withLock { $0 = true }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { accepted.withLock { $0 } }
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        #expect(await provider.sessionCount == 1)

        connection.send(.hostRequest(.respond(token: UUID(), value: nil, attError: 999)))

        // Refused outright, rather than passed on as a success the client never asked for.
        await waitFor(timeout: .seconds(10)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }
#endif
}
#endif
