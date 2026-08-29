//
//  HostEndToEndTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
import BLESwiftSimulatorLink
import Dispatch
import Foundation
import Synchronization
import Testing

/// Sim-to-sim over a real socket: a `PeripheralHost` driven by a ``LinkPeripheralManager``
/// and a `Central` driven by a ``LinkCentral``, each dialing the same ``Provider``, which
/// hosts the peripheral role's device on its ``VirtualRadio`` where the central role's scan
/// can find it.
///
/// The socket-backed counterpart to `VirtualPeripheralManagerTests.fullConversation`.
@Suite("Peripheral role end to end over the link")
struct HostEndToEndTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: heartRate)

    /// The Heart Rate service the host publishes: a dynamic, readable/notifying measurement
    /// and a write-only control point.
    private static var service: GATTService {
        GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable]),
            GATTCharacteristic(identifier: control, properties: [.write], permissions: [.writeable])
        ])
    }

    /// A provider listening on a system-assigned loopback port, hosting no fixtures — every
    /// device it serves comes from a peripheral-role client.
    private func makeProvider(port: UInt16 = 0) async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: port)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    /// A `PeripheralHost` driven by a `LinkPeripheralManager` dialing `port`, plus the link.
    private func makeHost(port: UInt16, label: String) -> (PeripheralHost, LinkPeripheralManager) {
        let queue = DispatchSerialQueue(label: label)
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "host-e2e",
            retryInterval: .milliseconds(50)
        )
        return (PeripheralHost(backend: link, queue: queue), link)
    }

    /// A `Central` driven by a `LinkCentral` dialing `port`, plus the link.
    private func makeCentral(port: UInt16, label: String) -> (Central, LinkCentral) {
        let queue = DispatchSerialQueue(label: label)
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "central-e2e",
            retryInterval: .milliseconds(50)
        )
        return (Central(backend: link, queue: queue), link)
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

    @Test("A linked host advertises and serves GATT to a linked central")
    func endToEnd() async throws {
        let provider = try await makeProvider()
        let port = await provider.port
        let (host, hostLink) = makeHost(port: port, label: "host.e2e.host")

        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }
        #expect(host.state == .poweredOn)

        try await host.add(Self.service)

        // Subscribe to the request streams BEFORE advertising — they do not replay.
        let written = Mutex<Data?>(nil)
        let readResponder = Task { @Sendable in
            for await request in await host.readRequests() {
                await host.respond(to: request, with: .success(Data([0, 72])))
            }
        }
        let writeResponder = Task { @Sendable in
            for await request in await host.writeRequests() {
                written.withLock { $0 = request.entries.first?.value }
                await host.respond(to: request, with: .success(()))
            }
        }

        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Sim Host", serviceUUIDs: [Self.heartRate])
        )
        #expect(host.isAdvertising)

        // ---- The other simulator: a linked central, on its own queue ----
        let (central, centralLink) = makeCentral(port: port, label: "host.e2e.central")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }

        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        let discovery = try #require(found)
        #expect(discovery.advertisement.localName == "Sim Host")

        let peripheral = try await central.connect(discovery.peripheral)

        // Read: answered by the host's `readRequests()` responder, over two sockets.
        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 72]))

        // Write: reaches the host's `writeRequests()`, which acknowledges it.
        try await peripheral.write(Data([0x2A]), to: Self.control)
        #expect(written.withLock { $0 } == Data([0x2A]))

        // Notify: the subscription must reach the host as a real subscriber.
        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.measurement) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // The host's own subscriber list is the arming signal on this path, so wait on it
        // rather than on a fixed delay.
        await waitFor(timeout: .seconds(5)) { await !host.subscribers(for: Self.measurement).isEmpty }
        #expect(await !host.subscribers(for: Self.measurement).isEmpty)
        try await host.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil)
        #expect(try await bounded { try await notifications.value } == Data([0, 99]))

        try await central.disconnect(peripheral.id)

        // ---- Once the host stops advertising, a fresh scan finds nothing ----
        await host.stopAdvertising()
        try await Task.sleep(for: .milliseconds(100))
        var again: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(1)) {
            if case .discovered(let discovery) = event { again = discovery; break }
        }
        #expect(again == nil)

        readResponder.cancel()
        writeResponder.cancel()
        hostLink.shutdown()
        centralLink.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)
        await provider.stop()
    }

    @Test("The updateValue window closes after 32 unacknowledged pushes and reopens on the acknowledgement")
    func updateValueWindow() async throws {
        let provider = try await makeProvider()
        let queue = DispatchSerialQueue(label: "host.e2e.window")
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "window-e2e",
            retryInterval: .milliseconds(50)
        )

        // `PeripheralHost.updateValue` retries internally and never surfaces the backend's
        // `Bool`, so the window is driven at the seam instead — with a test-installed handler
        // standing in for the host's.
        let states = Mutex<[CentralState]>([])
        let readyCount = Mutex<Int>(0)
        await Self.onQueue(queue) {
            link.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .readyToUpdateSubscribers: readyCount.withLock { $0 += 1 }
                default: break
                }
            }
        }
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.contains(.poweredOn) } }
        #expect(states.withLock { $0.contains(.poweredOn) })

        // One queue block, so no acknowledgement can be processed between the pushes.
        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in
                link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil)
            }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)

        // The provider acknowledges every push (the virtual radio never applies back-pressure),
        // and the first acknowledgement reopens the window.
        await waitFor(timeout: .seconds(5)) { readyCount.withLock { $0 } > 0 }
        #expect(readyCount.withLock { $0 } > 0)
        #expect(await Self.onQueue(queue) { link.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil) })

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A linked host's ATT failure surfaces to a linked central as a CBATTErrorDomain error")
    func readFailure() async throws {
        let provider = try await makeProvider()
        let port = await provider.port
        let (host, hostLink) = makeHost(port: port, label: "host.e2e.grumpy")
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }

        try await host.add(Self.service)
        let readResponder = Task { @Sendable in
            for await request in await host.readRequests() {
                await host.respond(to: request, with: .failure(.readNotPermitted))
            }
        }
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Grumpy Sim Host", serviceUUIDs: [Self.heartRate])
        )

        let (central, centralLink) = makeCentral(port: port, label: "host.e2e.grumpy.central")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }

        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        let peripheral = try await central.connect(try #require(found).peripheral)

        do {
            let value: Data = try await peripheral.read(from: Self.measurement)
            Issue.record("Expected the read to fail, got \(value as NSData)")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "CBATTErrorDomain")
            #expect(nsError.code == ATTError.readNotPermitted.rawValue)
        }

        readResponder.cancel()
        hostLink.shutdown()
        centralLink.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }
    /// How many `updateValue` pushes `provider` has received.
    private static func updateCount(_ provider: ScriptedHostProvider) -> Int {
        provider.requests.withLock { requests in
            requests.filter { if case .updateValue = $0 { return true }; return false }.count
        }
    }

    @Test("A provider drop empties the notification window, and the reconnect releases a blocked host")
    func windowSurvivesProviderDrop() async throws {
        // A scripted peer, not a real provider: what this test holds open is the *client's*
        // window, and only a peer that acknowledges nothing can hold it. No real provider can
        // play that part. A `passthrough` one composes the refusing backend with the virtual
        // radio, and the composite's per-child FIFO accepts a push the moment *any* child takes
        // it — the virtual child always does — so the session acknowledges it and the window
        // drains under the test. `ScriptedHostProvider` has no acknowledgement path at all.
        let scripted = try ScriptedHostProvider()
        try await scripted.start()
        let port = scripted.listener.port
        let queue = DispatchSerialQueue(label: "host.e2e.drop")
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "drop-e2e",
            // The scripted peer speaks JSON; the real provider that replaces it on the same
            // port accepts either, so one codec serves both halves of the test.
            codec: .json,
            retryInterval: .milliseconds(50)
        )

        let states = Mutex<[CentralState]>([])
        let readyCount = Mutex<Int>(0)
        await Self.onQueue(queue) {
            link.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .readyToUpdateSubscribers: readyCount.withLock { $0 += 1 }
                default: break
                }
            }
        }
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .poweredOn } }
        #expect(states.withLock { $0.last } == .poweredOn)

        // Nothing is ever acknowledged, so the window fills for real.
        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)
        // Gated on the peer having received every push that fitted — so the window is known to
        // be full of pushes that really went out, and known to be unacknowledged.
        await waitFor(timeout: .seconds(10)) { Self.updateCount(scripted) == LinkFlowControl.updateValueWindow }
        #expect(Self.updateCount(scripted) == LinkFlowControl.updateValueWindow)
        #expect(readyCount.withLock { $0 } == 0)

        // ---- Drop the peer with the window full ----
        scripted.stop()
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .unsupported } }
        #expect(states.withLock { $0.last } == .unsupported)
        // The drop alone must not release the host: the radio it would push at is gone.
        #expect(readyCount.withLock { $0 } == 0)

        // ---- A real provider on the same port; the reconnect releases the blocked host ----
        let second = try await Self.rebind(port: port) { try await self.makeProvider(port: port) }
        await waitFor(timeout: .seconds(10)) { states.withLock { $0.last == .poweredOn } }
        #expect(states.withLock { $0.last } == .poweredOn)
        await waitFor(timeout: .seconds(5)) { readyCount.withLock { $0 } == 1 }
        #expect(readyCount.withLock { $0 } == 1)
        #expect(await Self.onQueue(queue) { link.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil) })

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await second.sessionCount == 0 }
        await second.stop()
    }

    @Test("Pushes made while the link is down are cleared by the reconnect, not left occupying the window")
    func windowFilledWhileDisconnectedClearsOnReconnect() async throws {
        let first = try await makeProvider()
        let port = await first.port
        let queue = DispatchSerialQueue(label: "host.e2e.downfill")
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "downfill-e2e",
            retryInterval: .milliseconds(50)
        )

        let states = Mutex<[CentralState]>([])
        let readyCount = Mutex<Int>(0)
        await Self.onQueue(queue) {
            link.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .readyToUpdateSubscribers: readyCount.withLock { $0 += 1 }
                default: break
                }
            }
        }
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .poweredOn } }

        // ---- Drop the provider with an *empty* window, so nothing is latched at the drop ----
        await first.stop()
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .unsupported } }
        #expect(readyCount.withLock { $0 } == 0)

        // ---- Fill the window while there is no link: every push is dropped unsent ----
        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)
        #expect(readyCount.withLock { $0 } == 0)

        // ---- The reconnect clears those unacknowledgeable pushes and releases the host ----
        let second = try await Self.rebind(port: port) { try await self.makeProvider(port: port) }
        await waitFor(timeout: .seconds(10)) { states.withLock { $0.last == .poweredOn } }
        await waitFor(timeout: .seconds(5)) { readyCount.withLock { $0 } == 1 }
        #expect(readyCount.withLock { $0 } == 1)
        #expect(await Self.onQueue(queue) { link.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil) })

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await second.sessionCount == 0 }
        await second.stop()
    }

    @Test("A window filled before the first provider connection is cleared by that connection")
    func windowFilledBeforeFirstConnectionClearsOnConnect() async throws {
        // A port nothing is listening on, so the link's first dial has nowhere to land. Taken
        // from below the ephemeral range, so no test running in parallel can be handed it and
        // accept this link's handshake.
        let port = try closedPort()
        let queue = DispatchSerialQueue(label: "host.e2e.prefill")
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "prefill-e2e",
            retryInterval: .milliseconds(50)
        )

        let states = Mutex<[CentralState]>([])
        let readyCount = Mutex<Int>(0)
        await Self.onQueue(queue) {
            link.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .readyToUpdateSubscribers: readyCount.withLock { $0 += 1 }
                default: break
                }
            }
        }

        // ---- Fill the window before a provider has ever answered: every push is dropped
        // unsent, and no acknowledgement can ever arrive for one. ----
        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)
        #expect(readyCount.withLock { $0 } == 0)

        // ---- The first provider connection clears them and releases the blocked host ----
        let provider = try await Self.rebind(port: port) { try await self.makeProvider(port: port) }
        await waitFor(timeout: .seconds(10)) { states.withLock { $0.last == .poweredOn } }
        #expect(states.withLock { $0.last } == .poweredOn)
        await waitFor(timeout: .seconds(5)) { readyCount.withLock { $0 } == 1 }
        #expect(readyCount.withLock { $0 } == 1)
        #expect(await Self.onQueue(queue) { link.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil) })

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A provider drop reaches the host as an unsubscribe for every subscriber it had")
    func providerDropUnsubscribesTheHost() async throws {
        let provider = try await makeProvider()
        let port = await provider.port
        let (host, hostLink) = makeHost(port: port, label: "host.e2e.dropsub.host")
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }
        try await host.add(Self.service)

        // Attached before anything can subscribe: `subscriptionEvents()` does not replay.
        let log = SubscriptionLog()
        let stream = await host.subscriptionEvents()
        let observer = Task { for await event in stream { log.append(event) } }
        defer { observer.cancel() }

        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Sim Host", serviceUUIDs: [Self.heartRate])
        )

        let (central, centralLink) = makeCentral(port: port, label: "host.e2e.dropsub.central")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        let peripheral = try await central.connect(try #require(found).peripheral)

        let notifications = Task {
            for try await _ in peripheral.notifications(for: Self.measurement) as AsyncThrowingStream<Data, Error> {}
        }
        defer { notifications.cancel() }
        await waitFor(timeout: .seconds(5)) { await !host.subscribers(for: Self.measurement).isEmpty }
        let subscriber = try #require(await host.subscribers(for: Self.measurement).first)

        // ---- The provider goes away with the subscription still live ----
        await provider.stop()

        // The subscriber died with the session that minted it: a reconnect issues fresh ids,
        // so a host still holding this one would be pushing at a central that cannot receive.
        await waitFor(timeout: .seconds(5)) { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        let departure = try #require(log.lastUnsubscribe)
        #expect(departure.central == subscriber)
        #expect(departure.characteristic == Self.measurement)

        hostLink.shutdown()
        centralLink.shutdown()
    }

    /// The first peripheral `central` sights advertising ``heartRate``, or `nil` if the scan
    /// ends without one.
    private static func firstDiscovery(_ central: Central) async throws -> Discovery? {
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event { return discovery }
        }
        return nil
    }

    @Test("A hosted device keeps its identifier across a provider drop and reconnect")
    func hostedDeviceKeepsItsIdentifierAcrossAReconnect() async throws {
        let first = try await makeProvider()
        let port = await first.port
        let (host, hostLink) = makeHost(port: port, label: "host.e2e.identity.host")
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }
        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Sim Host", serviceUUIDs: [Self.heartRate])
        )

        let (central, centralLink) = makeCentral(port: port, label: "host.e2e.identity.central")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        let before = try #require(try await Self.firstDiscovery(central))

        // ---- The provider goes away, and a fresh one takes its port ----
        await first.stop()
        await waitFor(timeout: .seconds(5)) { host.state != .poweredOn }
        let second = try await Self.rebind(port: port) { try await self.makeProvider(port: port) }
        await waitFor(timeout: .seconds(10)) { host.state == .poweredOn }
        await waitFor(timeout: .seconds(10)) { central.state == .poweredOn }

        // The session that held the GATT database died with the provider, so the host
        // republishes — the same thing a CoreBluetooth host does after a power bounce. What it
        // does *not* have to do is tell anyone it is a new device, because it is not one.
        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Sim Host", serviceUUIDs: [Self.heartRate])
        )

        let after = try #require(try await Self.firstDiscovery(central))
        #expect(after.peripheral.uuid == before.peripheral.uuid)

        // And the identifier the central noted before the drop still reaches it: a connect by
        // the *old* identifier lands on the republished host.
        let peripheral = try await bounded { try await central.connect(before.peripheral) }
        #expect(peripheral.id.uuid == before.peripheral.uuid)
        // Serving the republished database, not an empty shell of the device it used to be.
        #expect(try await bounded { try await peripheral.discoverServices() } == [Self.heartRate])

        hostLink.shutdown()
        centralLink.shutdown()
        await second.stop()
    }

    @Test("A link drop and immediate redial leaves the reconnected host's device on the radio")
    func redialSurvivesTheOldSessionsTeardown() async throws {
        let provider = try await makeProvider()
        let port = await provider.port
        let (host, hostLink) = makeHost(port: port, label: "host.e2e.redial.host")
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }
        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Sim Host", serviceUUIDs: [Self.heartRate])
        )

        let (central, centralLink) = makeCentral(port: port, label: "host.e2e.redial.central")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        let before = try #require(try await Self.firstDiscovery(central))

        // ---- The link drops and redials at once, the provider staying up throughout ----
        //
        // The client keeps its `hostIdentifier`, so the new session registers the device the
        // old one had. The old session's close — `stopAdvertising`, `removeAllHostedServices`,
        // `eventHandler = nil` — runs asynchronously behind it, all of it keyed by that same
        // identifier. Without a generation on the handle, that teardown lands on the *new*
        // session's device and unadvertises, empties, or removes it outright.
        hostLink.dropLinkForTesting()
        // The drop and the 50 ms redial behind it are both asynchronous, and neither reports a
        // completion of its own — polling for the link to go down would race the reconnect
        // that is the whole point — so the brief's permitted fixed-delay fallback covers the
        // round trip before the reconnection is waited on.
        try await Task.sleep(for: .milliseconds(200))
        await waitFor(timeout: .seconds(10)) { hostLink.isProviderConnected && host.state == .poweredOn }

        // The session that held the GATT database died with the link, so the host republishes.
        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Sim Host", serviceUUIDs: [Self.heartRate])
        )

        // Advertising works after the reconnect: the device is still on the radio, under the
        // identifier it had, serving the database it just republished.
        let after = try #require(try await Self.firstDiscovery(central))
        #expect(after.peripheral.uuid == before.peripheral.uuid)
        let peripheral = try await bounded { try await central.connect(after.peripheral) }
        #expect(try await bounded { try await peripheral.discoverServices() } == [Self.heartRate])

        hostLink.shutdown()
        centralLink.shutdown()
        await provider.stop()
    }

    @Test("A host client claiming a fixture's identifier is hosted under a fresh one")
    func collidingHostIdentifierIsRefused() async throws {
        let fixtureJSON = """
        { "devices": [ { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "Fixture HRM",
          "advertisedServices": ["180D"], "services": [ { "uuid": "180D", "characteristics": [
            { "uuid": "2A37", "properties": ["read", "notify"], "value": "AEg=" } ] } ] } ] }
        """
        let fixtureID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.fixtures = try FixtureDocument.parse(Data(fixtureJSON.utf8)).devices
        let provider = Provider(configuration: configuration)
        try await provider.start()
        #expect(await provider.radio.services(of: fixtureID, matching: nil) == [Self.heartRate])

        // A peripheral-role client asking to be hosted under the fixture's own identifier.
        // Driven from a raw connection because no honest client can produce this: a
        // `LinkPeripheralManager` mints its identity itself.
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "host.e2e.collision")
        )
        let answer = Mutex<ServerHello?>(nil)
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .peripheral,
                clientName: "collider",
                hostIdentifier: fixtureID
            )))
        }
        connection.onMessage = { message in
            guard case .serverHello(let hello) = message else { return }
            answer.withLock { $0 = hello }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { answer.withLock { $0 } != nil }

        // The client is served — only its choice of identity was refused — and its own device
        // is registered under some other identifier, which the hello reports so the client can
        // say the provider overrode it.
        #expect(answer.withLock { $0?.accepted } == true)
        let assigned = try #require(answer.withLock { $0?.assignedHostIdentifier })
        #expect(assigned != fixtureID)
        await waitFor(timeout: .seconds(5)) { provider.radio.knownDeviceIDs.withLock { $0.count } == 2 }
        #expect(provider.radio.knownDeviceIDs.withLock { $0.count } == 2)

        // The fixture is untouched: still its own database, and still driven by the handle the
        // provider registered it with — a re-registration would have staled that handle, and
        // every mutation through it would have been ignored from then on.
        #expect(await provider.radio.services(of: fixtureID, matching: nil) == [Self.heartRate])
        let handle = try #require(await provider.handle(for: fixtureID))
        await handle.setServices([Self.service])
        #expect(await provider.radio.services(of: fixtureID, matching: nil) == [Self.heartRate])
        await handle.setServices([])
        #expect(await provider.radio.services(of: fixtureID, matching: nil) == [])

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    @Test("A redial reaching the provider before its old session was torn down keeps its identity")
    func aRedialBeforeTheOldSessionIsGoneKeepsItsIdentifier() async throws {
        let provider = try await makeProvider()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)
        let wanted = UUID()

        // Two peripheral-role sessions asking for the *same* identity, the second opened while
        // the first is still live — the extreme of a fast redial, where the old session's
        // asynchronous device removal has not merely lost the race but has not been started.
        // Driven from raw connections because a `LinkPeripheralManager` reconnect can only
        // *probably* produce this ordering, and the point is that the answer never depends on
        // which side wins.
        func handshake(_ label: String) async throws -> (LinkConnection, ServerHello) {
            let connection = LinkConnection.connect(
                to: endpoint,
                codec: .binaryPropertyList,
                queue: DispatchQueue(label: "host.e2e.redial.\(label)")
            )
            let answer = Mutex<ServerHello?>(nil)
            connection.onStateChange = { [weak connection] state in
                guard case .ready = state else { return }
                connection?.send(.clientHello(ClientHello(
                    protocolVersion: LinkProtocol.version,
                    role: .peripheral,
                    clientName: "redialer",
                    hostIdentifier: wanted
                )))
            }
            connection.onMessage = { message in
                guard case .serverHello(let hello) = message else { return }
                answer.withLock { $0 = hello }
            }
            connection.start()
            await waitFor(timeout: .seconds(5)) { answer.withLock { $0 } != nil }
            return (connection, try #require(answer.withLock { $0 }))
        }

        let (first, firstHello) = try await handshake("first")
        #expect(firstHello.assignedHostIdentifier == wanted)
        await waitFor(timeout: .seconds(5)) { provider.radio.knownDeviceIDs.withLock { $0.contains(wanted) } }

        let (second, secondHello) = try await handshake("second")
        // The identity is kept, and it is the client's own — not a fresh one minted because
        // the radio still held the device the first session registered.
        #expect(secondHello.assignedHostIdentifier == wanted)
        #expect(provider.radio.knownDeviceIDs.withLock { $0.contains(wanted) })
        #expect(provider.radio.knownDeviceIDs.withLock { $0.count } == 1)

        for connection in [first, second] {
            connection.onStateChange = nil
            connection.onMessage = nil
            connection.cancel()
        }
        await provider.stop()
    }

    /// Runs `make` until the port the previous provider released can be bound again — a
    /// just-closed listener may hold it for a moment.
    private static func rebind(port: UInt16, _ make: () async throws -> Provider) async throws -> Provider {
        for _ in 0..<20 {
            do { return try await make() } catch { try? await Task.sleep(for: .milliseconds(100)) }
        }
        return try await make()
    }
}
#endif
