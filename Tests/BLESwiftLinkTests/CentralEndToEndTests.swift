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
        // `Peripheral` exposes no public "notifications are armed" signal, so a fixed delay
        // stands in for one, exactly as the virtual-radio tests do.
        try await Task.sleep(for: .milliseconds(100))
        try await peripheral.write(Data([0x3C]), to: Self.control)
        #expect(try await notified.value == Data([0x3C]))

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
        // See `endToEnd()` — no public arming signal, so a fixed delay stands in for one.
        try await Task.sleep(for: .milliseconds(100))

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
