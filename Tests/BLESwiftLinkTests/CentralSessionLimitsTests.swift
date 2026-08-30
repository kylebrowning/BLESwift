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

    /// Runs `body` on `session`'s own serial queue and returns its result — the sanctioned
    /// way for a test to touch session state, which is queue-confined rather than locked.
    private func onSessionQueue<T: Sendable>(
        _ session: CentralSession,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            session.queue.async { continuation.resume(returning: body()) }
        }
    }

    /// The one central-role session `provider` is serving.
    private func centralSession(of provider: Provider) async throws -> CentralSession {
        try #require(await provider.liveSessions.compactMap { $0 as? CentralSession }.first)
    }

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are unreliable; the simulator-side path is covered by the
    // two-simulator E2E on real simulators.

    @Test("A burst past the write window is parked, not answered with a dropped link")
    func writeWindowOverrunParksRatherThanDroppingTheLink() async throws {
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
            clientName: "bursty",
            retryInterval: .seconds(30)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        _ = try await central.connect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fake"))
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        #expect(await provider.sessionCount == 1)

        // Far past the window the client agreed to honor, which is what a few hundred writers
        // released together by one readiness signal produce — and what CoreBluetooth would
        // simply queue.
        let burst = 4 * LinkFlowControl.writeWithoutResponseWindow + 1
        let reference = Self.control
        queue.async {
            for sequence in 0..<burst {
                link.send(.writeValue(
                    peripheral: Self.deviceID,
                    characteristic: WireCharacteristicRef(reference),
                    value: Data([0x01]),
                    type: .withoutResponse,
                    sequence: UInt64(sequence)
                ))
            }
        }

        // Parked — every one of them, watched arriving rather than assumed: a machine slow
        // enough to still be delivering the burst would otherwise let this test pass without
        // the session ever holding more than the old cap allowed.
        let session = try await centralSession(of: provider)
        await waitFor(timeout: .seconds(10)) {
            await onSessionQueue(session) { session.pendingWrites[Self.deviceID]?.count ?? 0 } == burst
        }
        #expect(await onSessionQueue(session) { session.pendingWrites[Self.deviceID]?.count ?? 0 } == burst)

        // And the scan, every other peripheral and every L2CAP channel this session holds
        // survive a burst on one characteristic.
        #expect(await provider.sessionCount == 1)

        link.shutdown()
        await provider.stop()
    }

    @Test("A client that never consumes its acknowledgements loses that peripheral's queue, not its link")
    func writeQueueOverflowDiscardsThePeripheralsWritesAndKeepsTheSession() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(
                identifier: Self.deviceID,
                name: "Fake",
                canSendWriteWithoutResponse: false,
                queue: queue
            )
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        // A raw client, so nothing acknowledges anything on its behalf: the sequences it
        // spends are never returned to a window it is not keeping.
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "centralsession.writeoverflow")
        )
        let accepted = Mutex(false)
        let events = Mutex<[CentralWireEvent]>([])
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .central,
                clientName: "insatiable"
            )))
        }
        connection.onMessage = { message in
            switch message {
            case .serverHello(let hello) where hello.accepted: accepted.withLock { $0 = true }
            case .centralEvent(let event): events.withLock { $0.append(event) }
            default: break
            }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { accepted.withLock { $0 } }
        connection.send(.centralRequest(.connect(peripheral: Self.deviceID, options: nil, requiresANCS: false)))
        await waitFor(timeout: .seconds(5)) {
            events.withLock { $0 }.contains { if case .didConnect = $0 { return true } else { return false } }
        }

        // One more than the queue holds, none of them ever drained.
        let overrun = CentralSession.maximumPendingWrites + 1
        for sequence in 0..<overrun {
            connection.send(.centralRequest(.writeValue(
                peripheral: Self.deviceID,
                characteristic: WireCharacteristicRef(Self.control),
                value: Data([0x01]),
                type: .withoutResponse,
                sequence: UInt64(sequence)
            )))
        }

        // The peripheral's queue goes, acknowledged write by write so the client's own window
        // is not left holding slots for payloads that were discarded. The link — the scan,
        // every other peripheral, every channel — stays.
        await waitFor(timeout: .seconds(10)) {
            events.withLock { $0 }.filter {
                if case .writeWithoutResponseAccepted = $0 { return true } else { return false }
            }.count == overrun
        }
        #expect(events.withLock { $0 }.filter {
            if case .writeWithoutResponseAccepted = $0 { return true } else { return false }
        }.count == overrun, "every discarded write gives the client back its window slot")
        #expect(await provider.sessionCount == 1)

        // Nothing else is reported: a `.withoutResponse` write has no completion in
        // CoreBluetooth, so a discarded one produces no event at all — least of all one a
        // live `.withResponse` write on the same characteristic would be answered by.
        #expect(!events.withLock { $0 }.contains {
            if case .didWriteValue = $0 { return true } else { return false }
        }, "a discarded withoutResponse write reports nothing")

        connection.send(.centralRequest(.writeValue(
            peripheral: Self.deviceID,
            characteristic: WireCharacteristicRef(Self.control),
            value: Data([0x02]),
            type: .withResponse,
            sequence: UInt64(overrun)
        )))
        await waitFor(timeout: .seconds(10)) {
            events.withLock { $0 }.contains {
                if case .didWriteValue = $0 { return true } else { return false }
            }
        }
        let completions = events.withLock { $0 }.compactMap { event -> WireError?? in
            guard case .didWriteValue(_, let characteristic, let error) = event,
                  characteristic == WireCharacteristicRef(Self.control) else { return nil }
            return .some(error)
        }
        #expect(completions.count == 1, "only the withResponse write is answered")
        #expect(completions.first == .some(nil), "and with its own real result")

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
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

    @Test("An unroutable withoutResponse write is still acknowledged, reopening the client's slot")
    func unroutableWriteWithoutResponseIsAcknowledged() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()

        // A raw client, so the write can name a peripheral the session never connected — the
        // one thing `Peripheral`'s own writer cannot produce.
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "centralsession.unroutablewrite")
        )
        let accepted = Mutex(false)
        let acknowledged = Mutex<[UInt64]>([])
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .central,
                clientName: "unroutable"
            )))
        }
        connection.onMessage = { message in
            switch message {
            case .serverHello(let hello) where hello.accepted:
                accepted.withLock { $0 = true }
            case .centralEvent(.writeWithoutResponseAccepted(_, let sequence)):
                acknowledged.withLock { $0.append(sequence) }
            default:
                break
            }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { accepted.withLock { $0 } }

        // Nothing was ever connected, so there is no remote to route either of these to.
        for sequence in UInt64(0)..<3 {
            connection.send(.centralRequest(.writeValue(
                peripheral: Self.deviceID,
                characteristic: WireCharacteristicRef(Self.control),
                value: Data([0x01]),
                type: .withoutResponse,
                sequence: sequence
            )))
        }

        // Every one of them comes back acknowledged: a dropped write must not cost the client
        // the window slot it is holding for it.
        await waitFor(timeout: .seconds(10)) { acknowledged.withLock { $0.count } == 3 }
        #expect(acknowledged.withLock { $0 } == [0, 1, 2])

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    /// A provider serving one `FakePeripheral` over a `FakeCentral`, a linked `Central`
    /// already connected to it, and one open L2CAP channel.
    ///
    /// Ids are allocated from 1, so the single channel these tests open is channel `1` — which
    /// is what lets them address it from behind `Peripheral`'s back.
    private func makeL2CAPRig(
        label: String,
        clientName: String
    ) async throws -> (provider: Provider, link: LinkCentral, channel: L2CAPChannel, fake: FakeL2CAPChannel) {
        let fakeBox = PeripheralBox()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: "Fake", queue: queue)
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            fakeBox.store(peripheral)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchSerialQueue(label: label)
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: clientName,
            retryInterval: .seconds(30)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        let peripheral = try await central.connect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fake"))
        let channel = try await peripheral.openL2CAPChannel(psm: L2CAPPSM(0x0041), timeout: .seconds(5))
        let fakePeripheral = try #require(fakeBox.peripheral)
        await waitFor(timeout: .seconds(5)) {
            await fakePeripheral.onQueue { fakePeripheral.lastOpenedL2CAPChannel != nil }
        }
        let fake = try #require(await fakePeripheral.onQueue { fakePeripheral.lastOpenedL2CAPChannel })
        return (provider, link, channel, fake)
    }

    @Test("A client that writes past the L2CAP credit window loses its session")
    func l2capWriteWindowOverrunClosesTheSession() async throws {
        let rig = try await makeL2CAPRig(label: "centralsession.l2capwindow", clientName: "greedy-writer")
        let fake = rig.fake
        // Nothing the client writes ever reaches the transport, so the session's outstanding
        // count only grows — exactly the back-pressure a client is supposed to wait out.
        await fake.onQueue { fake.writeBehavior = .hold }

        // One chunk more than the window plus its slack, straight down the link behind
        // `L2CAPChannel`'s back: its own writer waits for credit, which is the whole point.
        let chunk = Data(repeating: 0x5A, count: CentralSession.maximumChunk)
        let overrun = CentralSession.maximumOutstandingWrites / CentralSession.maximumChunk + 1
        let link = rig.link
        link.queue.async {
            for _ in 0..<overrun { link.send(.l2capData(channel: 1, data: chunk)) }
        }

        // The session goes, rather than the provider's memory.
        await waitFor(timeout: .seconds(10)) { await rig.provider.sessionCount == 0 }
        #expect(await rig.provider.sessionCount == 0)

        withExtendedLifetime(rig.channel) {}
        rig.link.shutdown()
        await rig.provider.stop()
    }

    @Test("A single oversized L2CAP frame loses the client its session")
    func l2capOversizedFrameClosesTheSession() async throws {
        let rig = try await makeL2CAPRig(label: "centralsession.l2capframe", clientName: "greedy-framer")

        // One byte past the chunk size both ends agreed on. No honest client produces it: its
        // own writer splits everything it sends at exactly that size.
        let oversized = Data(repeating: 0x5A, count: CentralSession.maximumChunk + 1)
        let link = rig.link
        link.queue.async { link.send(.l2capData(channel: 1, data: oversized)) }

        await waitFor(timeout: .seconds(10)) { await rig.provider.sessionCount == 0 }
        #expect(await rig.provider.sessionCount == 0)
        // Refused before it was ever handed to the transport.
        let fake = rig.fake
        #expect(await fake.onQueue { fake.writtenData }.isEmpty)

        withExtendedLifetime(rig.channel) {}
        rig.link.shutdown()
        await rig.provider.stop()
    }

    @Test("A connect is still tracked when every remote the session already holds is busy")
    func connectSurvivesATableOfBusyRemotes() async throws {
        let busy = UUID()
        let arriving = UUID()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        // A table of one, so the second connect overflows it with the first still connected.
        configuration.maximumRemotesPerCentralSession = 1
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            for identifier in [busy, arriving] {
                // `busy` reports itself connected from the start — `FakeCentral` delivers the
                // connection events but never moves a `FakePeripheral`'s own state, and the
                // cap reads that state to decide what it may evict.
                let peripheral = FakePeripheral(
                    identifier: identifier,
                    name: "Fake",
                    state: identifier == busy ? .connected : .disconnected,
                    queue: queue
                )
                peripheral.availableServices = [Self.service: [Self.control]]
                fake.retrievablePeripherals[identifier] = peripheral
            }
            fake.connectBehavior = .succeed
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchSerialQueue(label: "centralsession.busytable")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "busy",
            retryInterval: .seconds(30)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }

        // Connected, and stays that way: this remote is never idle, so the cap may not evict
        // it — which leaves the arriving one as the only candidate the eviction could pick.
        _ = try await bounded { try await central.connect(PeripheralIdentifier(uuid: busy, name: "Fake")) }
        let second = try await bounded { try await central.connect(PeripheralIdentifier(uuid: arriving, name: "Fake")) }

        // The session still has a remote filed for it, so its requests reach the backend and
        // the answers come back. Before the eviction ran ahead of the insert, this connect
        // evicted itself and every request after it was answered with silence.
        let services = try await bounded { try await second.discoverServices() }
        #expect(services == [Self.service])

        link.shutdown()
        await provider.stop()
    }

    @Test("An idle remote is evicted once the session is holding more than it keeps")
    func remoteTableIsCapped() async throws {
        // One more than the cap, so exactly the least recently connected one is evicted.
        let identifiers = (0..<(CentralSession.defaultMaximumRemotes + 1)).map { _ in UUID() }
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
