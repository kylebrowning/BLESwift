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
import BLESwiftCompat17
import Testing

/// The limits that a peripheral-role session enforces against a misbehaving client. This is the
/// counterpart to `CentralSessionLimitsTests` for the notification queue, and it also covers
/// malformed requests.
@Suite("Host session limits")
struct HostSessionLimitsTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are not reliable. The two-simulator E2E on real simulators covers
    // the simulator-side path.

    @Test("A client that queues past the update window loses its session")
    func updateWindowOverrunClosesTheSession() async throws {
        // One more than the cap, plus the window that the composite in front of the fake accepts
        // and drains before it refuses. Those pushes never sit in the queue that the cap counts.
        let overrun = HostSession.maximumPendingUpdates + LinkFlowControl.updateValueWindow + 1
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        // `peripheralManagerBackendFactory` replaces the host's real CoreBluetooth. Only a
        // passthrough provider builds the real CoreBluetooth.
        configuration.passthrough = true
        configuration.peripheralManagerBackendFactory = { queue in
            // The back-pressure is on from the start. The fake refuses every offer and never sends
            // `readyToUpdateSubscribers`, so the session's queue grows as fast as the client fills
            // it.
            let fake = FakePeripheralManager(queue: queue, state: .poweredOn)
            // The refusals outnumber what the test can consume. The composite offers a parked push
            // again each time the virtual backend is ready, so the script must outlast these
            // retries.
            fake.scriptedUpdateValueReturns = Array(repeating: false, count: 100_000)
            // A live child with a real transmit queue, not a dead handle. It raises a readiness
            // before any push, so the composite treats its refusals as back-pressure. Its full FIFO
            // closes the composite's window, and the session's queue grows from there.
            fake.simulateReadyToUpdate()
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        // The test writes straight down the link, behind `LinkPeripheralManager`'s back. Its own
        // `updateValue` honors the window, so only a misbehaving client reaches this state.
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

        await waitFor(timeout: .seconds(10)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    @Test("A client that publishes past the hosted-service cap loses its session")
    func hostedServiceOverrunClosesTheSession() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        // The test writes straight down the link, behind `LinkPeripheralManager`'s back. An honest
        // client publishes a handful of services, not a fresh service for each frame forever.
        let connection = LinkConnection.connect(
            to: endpoint,
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "hostsession.services")
        )
        let accepted = Mutex(false)
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .peripheral,
                clientName: "greedy-publisher"
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

        for _ in 0...HostSession.maximumHostedServices {
            let service = GATTService(
                identifier: ServiceIdentifier(uuid: UUID().uuidString),
                characteristics: [
                    GATTCharacteristic(identifier: Self.measurement, properties: [.read], permissions: [.readable])
                ]
            )
            connection.send(.hostRequest(.addService(WireGATTService(service))))
        }

        await waitFor(timeout: .seconds(10)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    @Test("Re-adding one service past the hosted-service cap keeps the session")
    func duplicateServiceAddsDoNotCloseTheSession() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        let connection = LinkConnection.connect(
            to: endpoint,
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "hostsession.duplicates")
        )
        let accepted = Mutex(false)
        let answers = Mutex<[Bool]>([])
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .peripheral,
                clientName: "duplicate-publisher"
            )))
        }
        connection.onMessage = { message in
            switch message {
            case .serverHello(let hello) where hello.accepted:
                accepted.withLock { $0 = true }
            case .hostEvent(.didAddService(_, let error)):
                answers.withLock { $0.append(error != nil) }
            default:
                break
            }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { accepted.withLock { $0 } }
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        #expect(await provider.sessionCount == 1)

        // The test answers each add before it sends the next, as an honest client does. The
        // database never holds more than the one service, so the cap has nothing to defend against
        // and the link stays up.
        let service = GATTService(
            identifier: ServiceIdentifier(uuid: UUID().uuidString),
            characteristics: [
                GATTCharacteristic(identifier: Self.measurement, properties: [.read], permissions: [.readable])
            ]
        )
        for attempt in 0...HostSession.maximumHostedServices {
            connection.send(.hostRequest(.addService(WireGATTService(service))))
            await waitFor(timeout: .seconds(5)) { answers.withLock { $0.count } > attempt }
        }

        #expect(await provider.sessionCount == 1, "a refused duplicate must not spend a slot against the cap")
        let refusals = answers.withLock { $0 }
        #expect(refusals.count == HostSession.maximumHostedServices + 1)
        #expect(refusals.first == false, "the first add publishes the service")
        #expect(refusals.dropFirst().allSatisfy { $0 }, "every re-add is refused as a duplicate")

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

        // The test writes straight down the link, behind `LinkPeripheralManager`'s back. Its own
        // `respond` can only send a code that an `ATTError` already held.
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

        // The session refuses the request outright. It does not pass the request on as a success
        // that the client never asked for.
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
