//
//  PassthroughWiringTests.swift
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

/// What a passthrough ``BLESwiftProvider/Provider`` owes its clients: every call a linked
/// client makes reaches *both* the virtual radio and the host's real backend, and events
/// from either reach the client.
///
/// The real half is stood in for by `BLESwiftTestSupport`'s fakes, injected through
/// ``BLESwiftProvider/ProviderConfiguration/centralBackendFactory`` and
/// ``BLESwiftProvider/ProviderConfiguration/peripheralManagerBackendFactory`` — the very
/// seam ``BLESwiftProvider/CoreBluetoothBackends`` fills when no factory is given. So the
/// composition these tests exercise is the shipped one, minus the Bluetooth hardware. The
/// two smoke tests at the end cover what a fake cannot: that `CoreBluetoothBackends` really
/// does vend a live, queue-confined CoreBluetooth object.
@Suite("Provider passthrough wiring")
struct PassthroughWiringTests {

    // MARK: - Fixtures

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

    private static let realDeviceID = UUID(uuidString: "3F2A1C4E-77B5-4D6A-9E10-2C8B4F5A6D7E")!

    /// One fixture device on the provider's virtual radio, so a scan has something virtual
    /// to find alongside whatever the real backend reports.
    private static let fixtureJSON = """
    { "devices": [ { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "Fixture HRM",
      "advertisedServices": ["180D"],
      "services": [ { "uuid": "180D", "characteristics": [
        { "uuid": "2A37", "properties": ["read", "notify"], "value": "AEg=" } ] } ] } ] }
    """

    /// The service a peripheral-role client hosts in the host-side tests.
    private static var service: GATTService {
        GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable])
        ])
    }

    // MARK: - Rig

    /// A `Sendable` hand-off for a fake the backend factory builds on the session's own
    /// queue — `Mutex` is non-copyable, so it cannot live in a struct alongside the rest of
    /// a rig.
    private final class FakeBox<Fake: Sendable>: Sendable {
        private let storage = Mutex<Fake?>(nil)

        var value: Fake? { storage.withLock { $0 } }

        func store(_ fake: Fake) { storage.withLock { $0 = fake } }
    }

    /// A started passthrough provider on a system-assigned loopback port.
    ///
    /// Both factories are called once per session, on that session's own serial queue —
    /// which is exactly why the fakes are constructed and scripted *inside* the closure:
    /// their scripting setters are queue-confined.
    private func makeProvider(
        fixtures: [FixtureDevice] = [],
        centralFactory: (@Sendable (DispatchSerialQueue) -> any CentralManaging)? = nil,
        peripheralFactory: (@Sendable (DispatchSerialQueue) -> any PeripheralManaging)? = nil
    ) async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.fixtures = fixtures
        configuration.centralBackendFactory = centralFactory
        configuration.peripheralManagerBackendFactory = peripheralFactory
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    /// A `LinkCentral` dialing `port` on a queue of its own.
    private func makeLink(port: UInt16, label: String) -> (LinkCentral, DispatchSerialQueue) {
        let queue = DispatchSerialQueue(label: label)
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "passthrough",
            retryInterval: .milliseconds(50)
        )
        return (link, queue)
    }

    /// Runs `body` on `queue` and returns its result, without blocking a cooperative thread.
    private static func onQueue<T: Sendable>(
        _ queue: DispatchSerialQueue,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Drops the client's link, waits for the provider to notice, then stops it.
    private func tearDown(link: LinkCentral, provider: Provider) async {
        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    // MARK: - Central role

    @Test("A central session's scan reaches both the virtual radio and the real backend")
    func scanFansOutToBothBackends() async throws {
        let box = FakeBox<FakeCentral>()
        let provider = try await makeProvider(
            fixtures: try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices,
            centralFactory: { queue in
                let fake = FakeCentral(queue: queue, state: .poweredOn)
                box.store(fake)
                return fake
            }
        )
        let (link, queue) = makeLink(port: await provider.port, label: "passthrough.scan")
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }

        // The virtual half: the fixture is found through this one scan.
        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event {
                found = discovery
                break
            }
        }
        #expect(found?.peripheral.name == "Fixture HRM")

        // The real half: the same scan reached the injected backend, once, with the filter.
        let fake = try #require(box.value)
        #expect(await fake.onQueue { fake.scanCallCount } == 1)
        let services = await fake.onQueue { fake.lastScanServices }
        #expect((services ?? nil) == [Self.heartRate])

        await tearDown(link: link, provider: provider)
    }

    @Test("A peripheral discovered on the real backend is connectable, and reads come back")
    func realBackendPeripheralIsConnectable() async throws {
        let centralBox = FakeBox<FakeCentral>()
        let provider = try await makeProvider(centralFactory: { queue in
            // On the session's own queue, so the fakes' queue-confined scripting setters
            // may be driven inline.
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.realDeviceID, name: "Real HRM", queue: queue)
            peripheral.availableServices = [Self.heartRate: [Self.measurement]]
            peripheral.scriptedProperties = [Self.measurement: [.read]]
            peripheral.scriptedReadValues = [Self.measurement: Data([0, 0x5B])]
            fake.retrievablePeripherals[Self.realDeviceID] = peripheral
            fake.connectBehavior = .succeed
            centralBox.store(fake)
            return fake
        })
        let (link, queue) = makeLink(port: await provider.port, label: "passthrough.connect")
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        let fake = try #require(centralBox.value)

        // The fake only advertises when told to, and a discovery delivered before the scan
        // request has crossed the socket would be dropped — so sight it repeatedly until
        // the client's stream yields.
        let identifier = PeripheralIdentifier(uuid: Self.realDeviceID, name: "Real HRM")
        let advertisement = AdvertisementData(localName: "Real HRM", serviceUUIDs: [Self.heartRate])
        let sightings = Task {
            while !Task.isCancelled {
                fake.simulateDiscovery(peripheral: identifier, advertisement: advertisement, rssi: -42)
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event, discovery.peripheral.uuid == Self.realDeviceID {
                found = discovery
                break
            }
        }
        sightings.cancel()
        let discovery = try #require(found)

        // Connecting to it must resolve to the fake's remote, not a virtual placeholder —
        // a placeholder would connect but have nothing to read.
        let peripheral = try await central.connect(discovery.peripheral)
        let value: Data = try await peripheral.read(from: Self.measurement)
        #expect(value == Data([0, 0x5B]))
        #expect(await fake.onQueue { fake.connectCallCount } == 1)

        // No explicit disconnect: `FakeCentral.cancelPeripheralConnection` only records the
        // call — it never delivers `didDisconnect` — so dropping the link is how this rig
        // ends a connection, exactly as the L2CAP link tests do.
        await tearDown(link: link, provider: provider)
    }

    @Test("Connection-event registration and requiresANCS reach the real backend")
    func connectionEventRegistrationAndANCSReachTheRealBackend() async throws {
        let box = FakeBox<FakeCentral>()
        let provider = try await makeProvider(centralFactory: { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.realDeviceID, name: "Real HRM", queue: queue)
            fake.retrievablePeripherals[Self.realDeviceID] = peripheral
            fake.connectBehavior = .succeed
            box.store(fake)
            return fake
        })
        let (link, queue) = makeLink(port: await provider.port, label: "passthrough.ancs")
        await waitFor(timeout: .seconds(5)) { link.isProviderConnected }
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }

        // `Central`'s connection-event and ANCS APIs are iOS-only (`#if !os(macOS)` and
        // `#if os(iOS)` respectively) and this suite is macOS-only, so the requests are
        // issued through `LinkCentral`'s own queue-confined `CentralManaging` witnesses —
        // the exact calls `Central` forwards on iOS. What is under test is the
        // wire → `CentralSession` → `CompositeCentral` → real backend path, which is
        // identical either way.
        await Self.onQueue(queue) {
            link.registerForConnectionEvents(services: [Self.heartRate], peripherals: nil)
            guard let remote = link.retrievePeripherals(withIdentifiers: [Self.realDeviceID]).first else { return }
            link.connect(remote, options: nil, requiresANCS: true)
        }

        let fake = try #require(box.value)
        await waitFor(timeout: .seconds(5)) {
            await fake.onQueue { fake.connectionEventRegistrationCount == 1 && fake.lastConnectRequiresANCS != nil }
        }
        #expect(await fake.onQueue { fake.connectionEventRegistrationCount } == 1)
        #expect(await fake.onQueue { fake.lastConnectionEventServices } == [Self.heartRate])
        #expect(await fake.onQueue { fake.lastConnectRequiresANCS } == true)

        await tearDown(link: link, provider: provider)
    }

    // MARK: - Peripheral role

    /// A `PeripheralHost` linked to `provider`, plus its link.
    private func makeHost(port: UInt16, label: String) -> (PeripheralHost, LinkPeripheralManager) {
        let queue = DispatchSerialQueue(label: label)
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "passthrough-host",
            retryInterval: .milliseconds(50)
        )
        return (PeripheralHost(backend: link, queue: queue), link)
    }

    @Test("A host session's add reaches both the real backend and the virtual radio")
    func hostAddFansOutToBothBackends() async throws {
        let box = FakeBox<FakePeripheralManager>()
        let provider = try await makeProvider(peripheralFactory: { queue in
            let fake = FakePeripheralManager(queue: queue, state: .poweredOn)
            box.store(fake)
            return fake
        })
        let (host, hostLink) = makeHost(port: await provider.port, label: "passthrough.host.add")
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }

        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Passthrough Host", serviceUUIDs: [Self.heartRate])
        )

        // The real half: the service and the advertisement both landed on the fake.
        let fake = try #require(box.value)
        #expect(await fake.onQueue { fake.addedServices.map(\.identifier) } == [Self.heartRate])
        #expect(await fake.onQueue { fake.startAdvertisingCallCount } == 1)
        #expect(await fake.onQueue { fake.lastAdvertisement?.localName } == "Passthrough Host")

        // The virtual half: a `Central` on the provider's own radio finds the same host.
        let virtualQueue = DispatchSerialQueue(label: "passthrough.host.virtual")
        let virtualCentral = Central(
            backend: VirtualCentralBackend(radio: provider.radio, queue: virtualQueue),
            queue: virtualQueue
        )
        await waitFor(timeout: .seconds(5)) { virtualCentral.state == .poweredOn }
        var found: Discovery?
        for try await event in await virtualCentral.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event {
                found = discovery
                break
            }
        }
        #expect(found?.advertisement.localName == "Passthrough Host")

        hostLink.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A read request from the real backend reaches the host, and its response lands back")
    func realBackendReadRequestReachesTheHost() async throws {
        let box = FakeBox<FakePeripheralManager>()
        let provider = try await makeProvider(peripheralFactory: { queue in
            let fake = FakePeripheralManager(queue: queue, state: .poweredOn)
            box.store(fake)
            return fake
        })
        let (host, hostLink) = makeHost(port: await provider.port, label: "passthrough.host.read")
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }
        try await host.add(Self.service)

        // The stream is created before the request is simulated — `readRequests()` does not
        // replay, so subscribing inside the responder task would be a race.
        let requests = await host.readRequests()
        let responder = Task {
            for await request in requests {
                await host.respond(to: request, with: .success(Data([0, 88])))
            }
        }

        let fake = try #require(box.value)
        let subscriber = Subscriber(id: UUID(), maximumUpdateValueLength: 20)
        let token = fake.simulateReadRequest(central: subscriber, characteristic: Self.measurement)

        await waitFor(timeout: .seconds(5)) { await fake.onQueue { !fake.respondCalls.isEmpty } }
        let calls = await fake.onQueue { fake.respondCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.token == token)
        #expect(calls.first?.value == Data([0, 88]))
        #expect(calls.first?.error == nil)

        responder.cancel()
        hostLink.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    // MARK: - CoreBluetoothBackends

    @Test("CoreBluetoothBackends vends a live, queue-confined real central")
    func realCentralBackendSmokeTest() async {
        let queue = DispatchSerialQueue(label: "passthrough.corebluetooth.central")
        // No hardware assumption: whatever `radioState` answers is a pass. What is asserted
        // is that the object exists, answers on `queue`, and takes an `eventHandler` — the
        // set that installs the delegate proxy — and gives it back.
        let probe = await Self.onQueue(queue) { () -> [Bool] in
            let backend = CoreBluetoothBackends.makeCentral(queue: queue)
            _ = backend.radioState
            backend.eventHandler = { _ in }
            let installed = backend.eventHandler != nil
            backend.eventHandler = nil
            return [installed, backend.eventHandler == nil]
        }
        #expect(probe == [true, true])
    }

    @Test("CoreBluetoothBackends vends a live, queue-confined real peripheral manager")
    func realPeripheralManagerBackendSmokeTest() async {
        let queue = DispatchSerialQueue(label: "passthrough.corebluetooth.peripheral")
        let probe = await Self.onQueue(queue) { () -> [Bool] in
            let backend = CoreBluetoothBackends.makePeripheralManager(queue: queue)
            _ = backend.radioState
            backend.eventHandler = { _ in }
            let installed = backend.eventHandler != nil
            backend.eventHandler = nil
            return [installed, backend.eventHandler == nil]
        }
        #expect(probe == [true, true])
    }
}
#endif
