//
//  CentralEndToEndTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftProvider
import BLESwiftSimulatorLink
import BLESwiftTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

@Suite("Central role end to end over the link")
struct CentralEndToEndTests {

    private static let fixtureJSON = """
    { "devices": [ { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "Fixture HRM", "advertisedServices": ["180D"],
      "services": [ { "uuid": "180D", "characteristics": [
        { "uuid": "2A37", "properties": ["read", "notify"], "value": "AEg=" },
        { "uuid": "2A39", "properties": ["read", "write", "notify"], "value": "AA==" } ] } ] } ] }
    """
    private static let deviceID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: service)

    /// A provider listening on a system-assigned loopback port, serving the fixture device.
    private func makeProvider() async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.fixtures = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    /// A `Central` driven by a `LinkCentral` dialing `port`, plus the link itself.
    private func makeCentral(port: UInt16, label: String) -> (Central, LinkCentral) {
        let queue = DispatchSerialQueue(label: label)
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "e2e",
            retryInterval: .milliseconds(50)
        )
        return (Central(backend: link, queue: queue), link)
    }

    @Test("A linked central scans, connects, reads, writes, is notified, and disconnects")
    func endToEnd() async throws {
        let provider = try await makeProvider()
        let (central, link) = makeCentral(port: await provider.port, label: "e2e.single")

        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        #expect(central.state == .poweredOn)

        var found: Discovery?
        for try await event in await central.scan(services: [Self.service], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event {
                found = discovery
                break
            }
        }
        #expect(found?.peripheral.name == "Fixture HRM")

        let peripheral = try await central.connect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fixture HRM"))

        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 0x48]))

        try await peripheral.write(Data([0x2A]), to: Self.control)
        let readBack: Data = try await peripheral.read(from: Self.control)
        #expect(readBack == Data([0x2A]))

        let notified = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.control) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // `Peripheral` publishes no "notifications are armed" signal of its own, so the wait is
        // on the provider radio's own subscription table — the state the push consults — rather
        // than on a delay a starved runner can outrun.
        await waitFor(timeout: .seconds(10)) { await provider.radio.isSubscribed(characteristic: Self.control) }
        #expect(await provider.radio.isSubscribed(characteristic: Self.control))
        try await peripheral.write(Data([0x3C]), to: Self.control)
        #expect(try await bounded { try await notified.value } == Data([0x3C]))

        #expect(try await peripheral.readRSSI() == -50)

        try await central.disconnect(peripheral.id)

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)
        await provider.stop()
    }

    @Test("Two linked centrals are served at once")
    func multiplexing() async throws {
        let provider = try await makeProvider()
        let port = await provider.port
        let (first, firstLink) = makeCentral(port: port, label: "e2e.first")
        let (second, secondLink) = makeCentral(port: port, label: "e2e.second")

        await waitFor(timeout: .seconds(5)) { first.state == .poweredOn && second.state == .poweredOn }
        #expect(await provider.sessionCount == 2)

        async let firstName = Self.firstSighting(of: first)
        async let secondName = Self.firstSighting(of: second)
        #expect(await firstName == "Fixture HRM")
        #expect(await secondName == "Fixture HRM")

        firstLink.shutdown()
        secondLink.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)
        await provider.stop()
    }

    @Test("500 notifications arrive in order over the link")
    func notificationThroughput() async throws {
        let provider = try await makeProvider()
        let (central, link) = makeCentral(port: await provider.port, label: "e2e.throughput")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }

        let peripheral = try await central.connect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fixture HRM"))
        let handle = try #require(await provider.handle(for: Self.deviceID))

        let received = Mutex<[Data]>([])
        let collector = Task {
            for try await value in peripheral.notifications(for: Self.control) as AsyncThrowingStream<Data, Error> {
                let count = received.withLock { values -> Int in
                    values.append(value)
                    return values.count
                }
                if count == 500 { return }
            }
        }
        // See `endToEnd()` — no public arming signal, so the wait is on the radio's own
        // subscription table. Getting this wrong is what made this test receive [] on a
        // starved runner: every one of the 500 pushes below went out with nothing subscribed.
        await waitFor(timeout: .seconds(10)) { await provider.radio.isSubscribed(characteristic: Self.control) }
        #expect(await provider.radio.isSubscribed(characteristic: Self.control))

        let expected = (0..<500).map { Data([UInt8($0 % 256), UInt8($0 / 256)]) }
        let start = ContinuousClock.now
        for value in expected {
            await handle.notify(value, for: Self.control, to: nil)
        }
        await waitFor(timeout: .seconds(5)) { received.withLock { $0.count } == 500 }
        let elapsed = ContinuousClock.now - start
        collector.cancel()

        #expect(received.withLock { $0 } == expected)
        #expect(elapsed < .seconds(5))
        print("link: 500 notifications in \(elapsed)")

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A hello sent the instant a connection is ready is always answered")
    func handshakeRace() async throws {
        let provider = try await makeProvider()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)
        // The hello leaves on the `.ready` transition itself, so it races the provider's own
        // bookkeeping for the connection it just accepted. Repeated because the race is
        // scheduler-dependent: one iteration proves nothing, fifty consistently caught the
        // dropped handshake before the pending table was made synchronous.
        for iteration in 0..<50 {
            let connection = LinkConnection.connect(
                to: endpoint,
                codec: .binaryPropertyList,
                queue: DispatchQueue(label: "e2e.race.\(iteration)")
            )
            let answer = Mutex<ServerHello?>(nil)
            connection.onStateChange = { [weak connection] state in
                guard case .ready = state else { return }
                connection?.send(.clientHello(ClientHello(
                    protocolVersion: LinkProtocol.version,
                    role: .central,
                    clientName: "race"
                )))
            }
            connection.onMessage = { message in
                guard case .serverHello(let hello) = message else { return }
                answer.withLock { $0 = hello }
            }
            connection.start()
            await waitFor(timeout: .seconds(2)) { answer.withLock { $0 != nil } }
            #expect(answer.withLock { $0?.accepted } == true, "iteration \(iteration)")
            connection.onStateChange = nil
            connection.onMessage = nil
            connection.cancel()
        }
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)
        await provider.stop()
    }

    @Test("Connecting to an identifier the provider does not know fails fast")
    func connectToUnknownIdentifierFailsFast() async throws {
        let provider = try await makeProvider()
        let (central, link) = makeCentral(port: await provider.port, label: "e2e.unknownid")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        #expect(central.state == .poweredOn)

        // The client vends a remote for any identifier — it cannot know what the provider
        // holds — so this reaches the session, which has no backend remote for it. Answering
        // with a failure is what keeps the client from sitting out its whole connect timeout
        // for an outcome that is already settled.
        let start = ContinuousClock.now
        do {
            _ = try await central.connect(PeripheralIdentifier(uuid: UUID(), name: nil), timeout: .seconds(15))
            Issue.record("expected the connect to fail")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "BLESwiftProvider")
            #expect(nsError.code == 1)
        }
        #expect(ContinuousClock.now - start < .seconds(1))

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A request sent behind the hello, before the session exists, is still served")
    func requestBehindTheHelloIsServed() async throws {
        let provider = try await makeProvider()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)
        // The scan leaves on the heels of the hello — same `.ready` callback, so both frames
        // are decoded from the same receive and delivered back to back on the provider's
        // listener queue, long before the handshake has hopped onto the actor and built a
        // session. Repeated because the window is scheduler-dependent: before the provider
        // held the messages behind the hello, this dropped the scan (or refused the
        // connection outright, reading the scan as a first message that was not a hello).
        for iteration in 0..<25 {
            let connection = LinkConnection.connect(
                to: endpoint,
                codec: .binaryPropertyList,
                queue: DispatchQueue(label: "e2e.behindhello.\(iteration)")
            )
            let discovered = Mutex<UUID?>(nil)
            connection.onStateChange = { [weak connection] state in
                guard case .ready = state else { return }
                connection?.send(.clientHello(ClientHello(
                    protocolVersion: LinkProtocol.version,
                    role: .central,
                    clientName: "behind-hello"
                )))
                connection?.send(.centralRequest(.scan(services: ["180D"], allowDuplicates: false)))
            }
            connection.onMessage = { message in
                guard case .centralEvent(.didDiscover(let peripheral, _, _, _)) = message else { return }
                discovered.withLock { $0 = peripheral }
            }
            connection.start()
            await waitFor(timeout: .seconds(5)) { discovered.withLock { $0 != nil } }
            #expect(discovered.withLock { $0 } == Self.deviceID, "iteration \(iteration)")
            connection.onStateChange = nil
            connection.onMessage = nil
            connection.cancel()
        }
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)
        await provider.stop()
    }

    @Test("Requests sent behind the hello reach the backend in the order they were sent")
    func requestsBehindTheHelloKeepTheirOrder() async throws {
        // The backlog is replayed to the session outside the connection table's lock, so the
        // table has to keep holding what arrives during the replay. A `FakeCentral` records
        // the order the provider's session actually drove it in.
        let fakeBox = FakeCentralBox()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            fakeBox.store(fake)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        // Every frame leaves in the one `.ready` callback, so they are all on the wire before
        // the handshake has hopped onto the actor and built a session: the whole run is
        // backlog, replayed, and must arrive in this order.
        let rounds = 32
        let last = ServiceIdentifier(uuid: "FFFF")
        let connection = LinkConnection.connect(
            to: endpoint,
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "e2e.behindhello.order")
        )
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .central,
                clientName: "behind-hello-order"
            )))
            for round in 0..<rounds {
                connection?.send(.centralRequest(.scan(services: [String(format: "%04X", round)], allowDuplicates: false)))
                connection?.send(.centralRequest(.stopScan))
            }
            connection?.send(.centralRequest(.scan(services: [last.uuidString], allowDuplicates: false)))
        }
        connection.start()

        await waitFor(timeout: .seconds(5)) { fakeBox.fake != nil }
        let fake = try #require(fakeBox.fake)
        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.scanCallCount } == rounds + 1 }

        // One scan more than the stops, and the *last* thing the backend saw is the scan that
        // was sent last — not a `stopScan` that overtook it during the replay.
        #expect(await fake.onQueue { fake.scanCallCount } == rounds + 1)
        #expect(await fake.onQueue { fake.stopScanCallCount } == rounds)
        #expect(await fake.onQueue { fake.lastScanServices ?? nil } == [last])

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    /// A `Sendable` hand-off for the `FakeCentral` the backend factory builds on the session's
    /// queue.
    private final class FakeCentralBox: Sendable {
        private let storage = Mutex<FakeCentral?>(nil)
        var fake: FakeCentral? { storage.withLock { $0 } }
        func store(_ fake: FakeCentral) { storage.withLock { $0 = fake } }
    }

    @Test("A hello arriving after stop() opens no session")
    func helloAfterStop() async throws {
        let provider = try await makeProvider()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)
        let connection = LinkConnection.connect(
            to: endpoint,
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "e2e.afterstop")
        )
        let ready = Mutex(false)
        let answer = Mutex<ServerHello?>(nil)
        connection.onStateChange = { state in
            guard case .ready = state else { return }
            ready.withLock { $0 = true }
        }
        connection.onMessage = { message in
            guard case .serverHello(let hello) = message else { return }
            answer.withLock { $0 = hello }
        }
        connection.start()
        await waitFor(timeout: .seconds(2)) { ready.withLock { $0 } }
        #expect(ready.withLock { $0 })

        // The provider is torn down with the connection accepted but not yet handshaken; the
        // hello that follows must not be answered with a session.
        await provider.stop()
        connection.send(.clientHello(ClientHello(
            protocolVersion: LinkProtocol.version,
            role: .central,
            clientName: "after-stop"
        )))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await provider.sessionCount == 0)
        #expect(answer.withLock { $0?.accepted } != true)

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
    }

    /// One silent client: a connection that opens the socket and then says nothing, with a
    /// flag recording whether the provider has since dropped it.
    private final class SilentClient: Sendable {

        /// The two flags a silent client has, in a class the connection's handler can capture —
        /// a `Mutex` is noncopyable, so it is wrapped rather than closed over.
        private final class Flags: Sendable {
            private let storage = Mutex<(isReady: Bool, hasEnded: Bool)>((false, false))
            var isReady: Bool { storage.withLock { $0.isReady } }
            var hasEnded: Bool { storage.withLock { $0.hasEnded } }
            func markReady() { storage.withLock { $0.isReady = true } }
            func markEnded() { storage.withLock { $0.hasEnded = true } }
        }

        let connection: LinkConnection
        private let flags = Flags()

        /// Whether the socket reached `.ready`.
        var isReady: Bool { flags.isReady }

        /// Whether the connection has since reached a terminal state — which, for a client
        /// that never writes, only the provider can have caused.
        var hasEnded: Bool { flags.hasEnded }

        /// Opens a socket to `endpoint` and never writes to it. Several clients share one
        /// `queue` — a silent client's only callbacks are its own state transitions, and a
        /// queue apiece would put dozens of threads behind sixty-four idle sockets.
        init(endpoint: LinkEndpoint, queue: DispatchQueue) {
            connection = LinkConnection.connect(
                to: endpoint,
                codec: .binaryPropertyList,
                queue: queue
            )
            connection.onStateChange = { [flags] state in
                switch state {
                case .ready: flags.markReady()
                case .failed, .cancelled: flags.markEnded()
                case .idle, .connecting: break
                }
            }
            connection.start()
        }

        /// Drops the handlers and closes the socket.
        func close() {
            connection.onStateChange = nil
            connection.onMessage = nil
            connection.cancel()
        }
    }

    @Test("A connection that sends no client hello is released at the handshake deadline")
    func silentConnectionIsReleasedAtTheHandshakeDeadline() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        // Short enough to test, far longer than a loopback handshake needs.
        configuration.handshakeTimeout = .milliseconds(300)
        let log = Mutex<[String]>([])
        configuration.log = { line in log.withLock { $0.append(line) } }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        let silent = SilentClient(endpoint: endpoint, queue: DispatchQueue(label: "e2e.silent"))
        await waitFor(timeout: .seconds(5)) { silent.isReady }
        #expect(silent.isReady)
        #expect(!silent.hasEnded)

        // Nothing is ever sent, so only the deadline can end this.
        await waitFor(timeout: .seconds(10)) { silent.hasEnded }
        #expect(silent.hasEnded)
        #expect(log.withLock { $0 }.contains { $0.contains("no client hello") })
        #expect(await provider.sessionCount == 0)

        // And a client that does handshake, on the same provider, is served as before — the
        // deadline only ever fires on a connection that has not been claimed.
        let (central, link) = makeCentral(port: await provider.port, label: "e2e.silent.real")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        #expect(central.state == .poweredOn)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await provider.sessionCount == 1)

        silent.close()
        link.shutdown()
        await provider.stop()
    }

    @Test("Beyond the pending cap, a further connection awaiting a handshake is refused")
    func pendingConnectionCapRefusesFurtherConnections() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.maximumPendingConnections = 64
        // The default deadline, so nothing below can be released before the cap is reached.
        let log = Mutex<[String]>([])
        configuration.log = { line in log.withLock { $0.append(line) } }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        // One queue for all sixty-five: see `SilentClient.init(endpoint:queue:)`.
        let clientQueue = DispatchQueue(label: "e2e.cap")
        var silent: [SilentClient] = []
        defer { for client in silent { client.close() } }
        for index in 0..<64 {
            let client = SilentClient(endpoint: endpoint, queue: clientQueue)
            silent.append(client)
            await waitFor(timeout: .seconds(10)) { client.isReady }
            #expect(client.isReady, "connection \(index)")
        }
        // The accepts are delivered on the provider's listener queue, one behind the other;
        // this settles the last of them before the connection that must be refused is opened.
        try await Task.sleep(for: .milliseconds(300))
        #expect(silent.allSatisfy { !$0.hasEnded })

        let refused = SilentClient(endpoint: endpoint, queue: clientQueue)
        defer { refused.close() }
        await waitFor(timeout: .seconds(10)) { refused.hasEnded }
        #expect(refused.hasEnded)
        #expect(log.withLock { $0 }.contains { $0.contains("too many are awaiting a handshake") })
        // The cap sheds the newcomer, never the connections already waiting.
        #expect(silent.allSatisfy { !$0.hasEnded })

        await provider.stop()
    }

    @Test("A connection holding a megabyte behind its own handshake is dropped")
    func backlogByteCapDropsTheConnection() async throws {
        // A session's backend is built inside the handshake, on the actor, so a factory that
        // waits holds the handshake open — and that is the only window in which a connection's
        // messages are held rather than served. Nothing else can keep it open on demand.
        //
        // The wait is short and independently released: it occupies a cooperative thread while
        // it lasts, and a test that held one until *another* async assertion completed could
        // starve the very pool that assertion needs.
        let gate = DispatchSemaphore(value: 0)
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            _ = gate.wait(timeout: .now() + 2)
            return FakeCentral(queue: queue, state: .poweredOn)
        }
        let log = Mutex<[String]>([])
        configuration.log = { line in log.withLock { $0.append(line) } }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "e2e.backlog")
        )
        let ready = Mutex(false)
        let ended = Mutex(false)
        connection.onStateChange = { state in
            switch state {
            case .ready: ready.withLock { $0 = true }
            case .failed, .cancelled: ended.withLock { $0 = true }
            case .idle, .connecting: break
            }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { ready.withLock { $0 } }
        #expect(ready.withLock { $0 })

        // Released on a timer of its own, well after the burst below has crossed a loopback
        // socket, so the handshake is never held on an assertion that has to run to free it.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(750)) { gate.signal() }

        connection.send(.clientHello(ClientHello(
            protocolVersion: LinkProtocol.version,
            role: .central,
            clientName: "backlog"
        )))
        // A megabyte and a quarter behind a handshake that cannot complete — past the cap, and
        // well under the count cap, so only the byte cap can answer it.
        let value = Data(repeating: 0x5A, count: 128 * 1024)
        for sequence in 0..<10 {
            connection.send(.centralRequest(.writeValue(
                peripheral: Self.deviceID,
                characteristic: WireCharacteristicRef(Self.control),
                value: value,
                type: .withoutResponse,
                sequence: UInt64(sequence)
            )))
        }

        await waitFor(timeout: .seconds(15)) { ended.withLock { $0 } }
        #expect(ended.withLock { $0 })
        #expect(log.withLock { $0 }.contains { $0.contains("behind its handshake") })

        gate.signal()
        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    /// The name on the first peripheral `central` sights, or `nil` if the scan ends first.
    private static func firstSighting(of central: Central) async -> String? {
        do {
            for try await event in await central.scan(services: [Self.service], timeout: .seconds(5)) {
                if case .discovered(let discovery) = event { return discovery.peripheral.name }
            }
        } catch {
            return nil
        }
        return nil
    }
}
#endif
