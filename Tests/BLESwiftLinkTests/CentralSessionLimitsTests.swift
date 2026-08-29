//
//  CentralSessionLimitsTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
@testable import BLESwiftSimulatorLink
import BLESwiftTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

/// What a central-role session refuses to hold on a misbehaving client's behalf.
@Suite("Central session limits")
struct CentralSessionLimitsTests {

    private static let deviceID = UUID(uuidString: "2C7F9A11-4E3B-4D5A-9C8E-7F6A5B4C3D2E")!
    private static let service = ServiceIdentifier(uuid: "180D")
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: service)

    /// A `Sendable` hand-off for the `FakePeripheral` the backend factory builds on the
    /// session's queue.
    private final class PeripheralBox: Sendable {
        private let storage = Mutex<FakePeripheral?>(nil)
        var peripheral: FakePeripheral? { storage.withLock { $0 } }
        func store(_ peripheral: FakePeripheral) { storage.withLock { $0 = peripheral } }
    }

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are unreliable; the simulator-side path is covered by the
    // two-simulator E2E on real simulators.

    @Test("A client that queues past the write window loses its session")
    func writeWindowOverrunClosesTheSession() async throws {
        let fakeBox = PeripheralBox()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            // Back-pressured from the start: nothing this client queues is ever drained, so
            // the queue grows exactly as fast as the client fills it.
            let peripheral = FakePeripheral(
                identifier: Self.deviceID,
                name: "Fake",
                canSendWriteWithoutResponse: false,
                queue: queue
            )
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            fakeBox.store(peripheral)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchSerialQueue(label: "centralsession.writewindow")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "greedy",
            retryInterval: .seconds(30)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        _ = try await central.connect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fake"))
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        #expect(await provider.sessionCount == 1)

        // Straight down the link, behind `Peripheral`'s back: its own writer honors the
        // window, which is the whole point — only a client that has stopped honoring it can
        // reach this.
        let overrun = CentralSession.maximumPendingWrites + 1
        let reference = Self.control
        queue.async {
            for sequence in 0..<overrun {
                link.send(.writeValue(
                    peripheral: Self.deviceID,
                    characteristic: WireCharacteristicRef(reference),
                    value: Data([0x01]),
                    type: .withoutResponse,
                    sequence: UInt64(sequence)
                ))
            }
        }

        // The session goes, rather than the provider's memory.
        await waitFor(timeout: .seconds(10)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)

        link.shutdown()
        await provider.stop()
    }

    @Test("A client that queues past the channel-open cap loses its session")
    func openOverrunClosesTheSession() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: "Fake", queue: queue)
            // Every open is held: nothing this client queues is ever completed, so the
            // pending-open list grows exactly as fast as the client fills it.
            peripheral.l2capOpenBehavior = .hold
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchSerialQueue(label: "centralsession.openwindow")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "greedy-opener",
            retryInterval: .seconds(30)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        _ = try await central.connect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fake"))
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        #expect(await provider.sessionCount == 1)

        // Straight down the link, behind `Peripheral`'s back, as above.
        let overrun = CentralSession.maximumPendingOpens + 1
        queue.async {
            for channel in 0..<overrun {
                link.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: 0x80, channel: UInt32(channel)))
            }
        }

        await waitFor(timeout: .seconds(10)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)

        link.shutdown()
        await provider.stop()
    }

    @Test("An idle remote is evicted once the session is holding more than it keeps")
    func remoteTableIsCapped() async throws {
        // One more than the cap, so exactly the least recently connected one is evicted.
        let identifiers = (0..<(CentralSession.maximumRemotes + 1)).map { _ in UUID() }
        let oldest = try #require(identifiers.first)
        let newest = try #require(identifiers.last)
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            for (index, identifier) in identifiers.enumerated() {
                let peripheral = FakePeripheral(identifier: identifier, name: "Fake", queue: queue)
                // Distinct values, so an answer names the peripheral it came from.
                peripheral.scriptedRSSI = -index
                fake.retrievablePeripherals[identifier] = peripheral
            }
            // Held: every remote stays `.disconnected`, which is exactly what the cap evicts.
            fake.connectBehavior = .hang
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "centralsession.remotecap")
        )
        let accepted = Mutex(false)
        let rssi = Mutex<[UUID]>([])
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .central,
                clientName: "collector"
            )))
        }
        connection.onMessage = { message in
            switch message {
            case .serverHello(let hello) where hello.accepted:
                accepted.withLock { $0 = true }
            case .centralEvent(.didReadRSSI(let peripheral, _, _)):
                rssi.withLock { $0.append(peripheral) }
            default:
                break
            }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { accepted.withLock { $0 } }
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }

        // One connect per identifier, oldest first — none of them ever completes.
        for identifier in identifiers {
            connection.send(.centralRequest(.connect(peripheral: identifier, options: nil, requiresANCS: false)))
        }

        // The link is ordered and the session's queue serial, so the answer to the second
        // read cannot arrive before the first would have.
        connection.send(.centralRequest(.readRSSI(peripheral: oldest)))
        connection.send(.centralRequest(.readRSSI(peripheral: newest)))
        await waitFor(timeout: .seconds(10)) { rssi.withLock { $0.contains(newest) } }

        // The newest is answered; the oldest was forgotten to make room for it.
        #expect(rssi.withLock { $0 } == [newest])

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }
#endif
}
#endif
