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
import BLESwiftCompat17
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

    /// A provider that listens on a system-assigned loopback port and serves the fixture device.
    private func makeProvider() async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.fixtures = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    /// A `Central` driven by a `LinkCentral` that dials `port`. The result includes the link.
    private func makeCentral(port: UInt16, label: String) -> (Central, LinkCentral) {
        let queue = DispatchQueue(label: label)
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
        // `Peripheral` has no "notifications are armed" signal, so the test waits on the radio's
        // subscription table, which the push consults. A fixed delay could be outrun by a starved
        // runner.
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
        // See `endToEnd()`. A wrong wait here made the test receive [] on a starved runner, because
        // all 500 pushes went out with nothing subscribed.
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
        // The hello leaves on the `.ready` transition, so it races the provider's bookkeeping for
        // the new connection. The race depends on the scheduler, so the test repeats it fifty
        // times.
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

        // The client vends a remote for any identifier. The session has no backend remote for this
        // one, so the answer is a failure and the client does not wait out its connect timeout.
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
        // The scan leaves right after the hello, on the same `.ready` callback. The provider
        // delivers both frames back to back, long before the handshake builds a session. The window
        // depends on the scheduler, so the test repeats it. The provider must hold the scan behind
        // the hello and not drop it or refuse the connection.
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
        // The provider replays the backlog outside the connection table's lock, so the table must
        // keep holding what arrives during the replay. A `FakeCentral` records the order in which
        // the session drove it.
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

        // Every frame leaves in the one `.ready` callback, so the whole run is backlog. The
        // provider replays it, and it must arrive in this order.
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

        // There is one more scan than stops, so the backend's last event is the client's last scan.
        // It is not a `stopScan` that overtook the scan during the replay.
        #expect(await fake.onQueue { fake.scanCallCount } == rounds + 1)
        #expect(await fake.onQueue { fake.stopScanCallCount } == rounds)
        #expect(await fake.onQueue { fake.lastScanServices ?? nil } == [last])

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    /// A `Sendable` hand-off for the `FakeCentral` that the backend factory builds on the session's
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

        // The test tears the provider down with the connection accepted but not yet handshaken. The
        // hello that follows must not get a session.
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

    /// A silent client: a connection that opens the socket and then says nothing. A flag records
    /// whether the provider has since dropped it.
    private final class SilentClient: Sendable {

        /// The two flags of a silent client, in a class that the connection handler can capture. A
        /// `Mutex` is noncopyable, so the code wraps it instead of closing over it.
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

        /// Whether the connection has since reached a terminal state. A client that never writes
        /// cannot cause this, so only the provider can.
        var hasEnded: Bool { flags.hasEnded }

        /// Opens a socket to `endpoint` and never writes. Clients share one `queue`, because a
        /// queue for each would put dozens of threads behind sixty-four idle sockets.
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

        await waitFor(timeout: .seconds(10)) { silent.hasEnded }
        #expect(silent.hasEnded)
        #expect(log.withLock { $0 }.contains { $0.contains("no client hello") })
        #expect(await provider.sessionCount == 0)

        // A client that does handshake on the same provider gets service as before. The deadline
        // fires only on a connection that nobody has claimed.
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
        let log = Mutex<[String]>([])
        configuration.log = { line in log.withLock { $0.append(line) } }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        let clientQueue = DispatchQueue(label: "e2e.cap")
        var silent: [SilentClient] = []
        defer { for client in silent { client.close() } }
        for index in 0..<64 {
            let client = SilentClient(endpoint: endpoint, queue: clientQueue)
            silent.append(client)
            await waitFor(timeout: .seconds(10)) { client.isReady }
            #expect(client.isReady, "connection \(index)")
        }
        // The provider delivers accepts one behind the other on its listener queue. This settles
        // the last of them before the test opens the connection that must be refused.
        try await Task.sleep(for: .milliseconds(300))
        #expect(silent.allSatisfy { !$0.hasEnded })

        let refused = SilentClient(endpoint: endpoint, queue: clientQueue)
        defer { refused.close() }
        await waitFor(timeout: .seconds(10)) { refused.hasEnded }
        #expect(refused.hasEnded)
        #expect(log.withLock { $0 }.contains { $0.contains("too many are awaiting a handshake") })
        #expect(silent.allSatisfy { !$0.hasEnded })

        await provider.stop()
    }

    @Test("A connection holding a megabyte behind its own handshake is dropped")
    func backlogByteCapDropsTheConnection() async throws {
        // The provider builds the backend inside the handshake, so a factory that waits holds the
        // handshake open. This is the only way to keep messages unserved on demand.
        //
        // The drop releases the wait, and a bound limits it. The wait occupies a cooperative
        // thread, so it must not depend on another async assertion. The drop is decided on the
        // listener queue before any handshake work reaches the actor, so the log line it writes
        // opens the gate. The timeout is only a fallback and is too wide for a loaded runner to
        // open the gate early.
        let gate = DispatchSemaphore(value: 0)
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            _ = gate.wait(timeout: .now() + 10)
            return FakeCentral(queue: queue, state: .poweredOn)
        }
        let log = Mutex<[String]>([])
        configuration.log = { line in
            log.withLock { $0.append(line) }
            if line.contains("bytes behind its handshake") { gate.signal() }
        }
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

        connection.send(.clientHello(ClientHello(
            protocolVersion: LinkProtocol.version,
            role: .central,
            clientName: "backlog"
        )))
        // The test sends 1.25 MB behind a handshake that cannot complete. This is past the byte cap
        // and well under the count cap, so only the byte cap can answer it.
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
        #expect(log.withLock { $0 }.contains { $0.contains("bytes behind its handshake") })

        gate.signal()
        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    /// The name of the first peripheral that `central` sights, or `nil` if the scan ends first.
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
