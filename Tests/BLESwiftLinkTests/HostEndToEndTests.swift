//
//  HostEndToEndTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
@testable import BLESwiftVirtualRadio
import BLESwiftSimulatorLink
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// Simulator-to-simulator tests over a real socket. A ``LinkPeripheralManager`` drives a
/// `PeripheralHost` and a ``LinkCentral`` drives a `Central`. Both dial the same ``Provider``,
/// which hosts the device on its ``VirtualRadio``.
///
/// This is the socket-backed counterpart to `VirtualPeripheralManagerTests.fullConversation`.
@Suite("Peripheral role end to end over the link")
struct HostEndToEndTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: heartRate)

    /// The Heart Rate service that the host publishes. It has a dynamic measurement that is
    /// readable and notifying, and a write-only control point.
    private static var service: GATTService {
        GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable]),
            GATTCharacteristic(identifier: control, properties: [.write], permissions: [.writeable])
        ])
    }

    /// A provider that listens on a system-assigned loopback port and hosts no fixtures. Every
    /// device that it serves comes from a peripheral-role client.
    private func makeProvider(port: UInt16 = 0) async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: port)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    /// A `PeripheralHost` driven by a `LinkPeripheralManager` that dials `port`. The result
    /// includes the link.
    private func makeHost(port: UInt16, label: String) -> (PeripheralHost, LinkPeripheralManager) {
        let queue = DispatchQueue(label: label)
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "host-e2e",
            retryInterval: .milliseconds(50)
        )
        return (PeripheralHost(backend: link, queue: queue), link)
    }

    /// A `Central` driven by a `LinkCentral` that dials `port`. The result includes the link.
    private func makeCentral(port: UInt16, label: String) -> (Central, LinkCentral) {
        let queue = DispatchQueue(label: label)
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "central-e2e",
            retryInterval: .milliseconds(50)
        )
        return (Central(backend: link, queue: queue), link)
    }

    /// Runs `body` on `queue` and returns its result. It does not block a cooperative thread.
    private static func onQueue<T: Sendable>(
        _ queue: DispatchQueue,
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

        // Subscribe to the request streams BEFORE advertising. They do not replay.
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

        let (central, centralLink) = makeCentral(port: port, label: "host.e2e.central")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }

        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        let discovery = try #require(found)
        #expect(discovery.advertisement.localName == "Sim Host")

        let peripheral = try await central.connect(discovery.peripheral)

        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 72]))

        try await peripheral.write(Data([0x2A]), to: Self.control)
        #expect(written.withLock { $0 } == Data([0x2A]))

        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.measurement) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // On this path, the host's subscriber list is the arming signal. Wait on it, not on a fixed
        // delay.
        await waitFor(timeout: .seconds(5)) { await !host.subscribers(for: Self.measurement).isEmpty }
        #expect(await !host.subscribers(for: Self.measurement).isEmpty)
        try await host.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil)
        #expect(try await bounded { try await notifications.value } == Data([0, 99]))

        try await central.disconnect(peripheral.id)

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

    @Test("A start behind a stopped start still reaches a linked central's scan")
    func advertisingResumesAfterAStopBehindAStart() async throws {
        let provider = try await makeProvider()
        let port = await provider.port
        let queue = DispatchQueue(label: "host.e2e.restart")
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "restart-e2e",
            retryInterval: .milliseconds(50)
        )
        let host = PeripheralHost(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }

        let advertisement = PeripheralAdvertisement(localName: "Restarted Host", serviceUUIDs: [Self.heartRate])

        // Start and stop happen in one queue turn. The test drives them at the seam, because a
        // `PeripheralHost` awaits the completion that the stop has to overtake. The provider
        // applies both in order and answers the start anyway. The device ends up silent.
        await Self.onQueue(queue) {
            link.startAdvertising(advertisement)
            link.stopAdvertising()
        }
        // A barrier on the same ordered link. When it lands, the provider has handled the stray
        // completion.
        try await host.add(Self.service)
        #expect(await Self.onQueue(queue) { link.isAdvertising } == false)

        // The host asks again with nothing behind the request. If the cancelled start had latched a
        // flag that made the host skip this start, the session would stay silent. The scan below
        // reports that.
        try await host.startAdvertising(advertisement)

        let (central, centralLink) = makeCentral(port: port, label: "host.e2e.restart.central")
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        #expect(try #require(found).advertisement.localName == "Restarted Host")

        link.shutdown()
        centralLink.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("The updateValue window closes after 32 unacknowledged pushes and reopens on the acknowledgement")
    func updateValueWindow() async throws {
        let provider = try await makeProvider()
        let queue = DispatchQueue(label: "host.e2e.window")
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "window-e2e",
            retryInterval: .milliseconds(50)
        )

        // `PeripheralHost.updateValue` retries internally and hides the backend's `Bool`, so the
        // test drives the window at the seam with its own handler.
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

        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in
                link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil)
            }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)

        // The provider acknowledges every push, because the virtual radio never applies
        // back-pressure. The first acknowledgement reopens the window.
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
    /// The number of `updateValue` pushes that `provider` has received.
    private static func updateCount(_ provider: ScriptedHostProvider) -> Int {
        provider.requests.withLock { requests in
            requests.filter { if case .updateValue = $0 { return true }; return false }.count
        }
    }

    @Test("A provider drop empties the notification window, and the reconnect releases a blocked host")
    func windowSurvivesProviderDrop() async throws {
        // The peer is scripted, not a real provider, because only a peer that acknowledges nothing
        // can hold the client's window open. A `passthrough` provider cannot, since the virtual
        // child always takes a push and the session then acknowledges it.
        let scripted = try ScriptedHostProvider()
        try await scripted.start()
        let port = scripted.listener.port
        let queue = DispatchQueue(label: "host.e2e.drop")
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "drop-e2e",
            // The scripted peer speaks JSON. The real provider that replaces it on the same port
            // accepts either codec, so one codec serves both halves of the test.
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

        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)
        // Wait until the peer has received every push that fitted. The window is then known to be
        // full of pushes that really went out unacknowledged.
        await waitFor(timeout: .seconds(10)) { Self.updateCount(scripted) == LinkFlowControl.updateValueWindow }
        #expect(Self.updateCount(scripted) == LinkFlowControl.updateValueWindow)
        #expect(readyCount.withLock { $0 } == 0)

        scripted.stop()
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .unsupported } }
        #expect(states.withLock { $0.last } == .unsupported)
        // The drop emits no readiness of its own. A real host gets its release from the
        // `.unsupported` state change instead, because the radio it would push at is gone.
        #expect(readyCount.withLock { $0 } == 0)

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
        let queue = DispatchQueue(label: "host.e2e.downfill")
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

        await first.stop()
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .unsupported } }
        #expect(readyCount.withLock { $0 } == 0)

        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)
        #expect(readyCount.withLock { $0 } == 0)

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
        // Use a port that nothing listens on, so the link's first dial has nowhere to land. It
        // comes from below the ephemeral range, so no parallel test can receive it.
        let port = try closedPort()
        let queue = DispatchQueue(label: "host.e2e.prefill")
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

        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)
        #expect(readyCount.withLock { $0 } == 0)

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

        // Attach before anything can subscribe. `subscriptionEvents()` does not replay.
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

        await provider.stop()

        // The subscriber died with the session that created it. A reconnect issues fresh ids, so a
        // host that still holds this subscriber would push at a central that cannot receive.
        await waitFor(timeout: .seconds(5)) { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        let departure = try #require(log.lastUnsubscribe)
        #expect(departure.central == subscriber)
        #expect(departure.characteristic == Self.measurement)

        hostLink.shutdown()
        centralLink.shutdown()
    }

    /// The first peripheral that `central` sights while it advertises ``heartRate``, or `nil` if
    /// the scan ends without one.
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

        await first.stop()
        await waitFor(timeout: .seconds(5)) { host.state != .poweredOn }
        let second = try await Self.rebind(port: port) { try await self.makeProvider(port: port) }
        await waitFor(timeout: .seconds(10)) { host.state == .poweredOn }
        await waitFor(timeout: .seconds(10)) { central.state == .poweredOn }

        // The session that held the GATT database died with the provider, so the host publishes
        // again, as a CoreBluetooth host does after a power bounce. It is not a new device.
        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Sim Host", serviceUUIDs: [Self.heartRate])
        )

        let after = try #require(try await Self.firstDiscovery(central))
        #expect(after.peripheral.uuid == before.peripheral.uuid)

        // The identifier that the central noted before the drop still reaches the host. A connect
        // by the old identifier lands on the host that published again.
        let peripheral = try await bounded { try await central.connect(before.peripheral) }
        #expect(peripheral.id.uuid == before.peripheral.uuid)
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

        // ---- The link drops and redials at once, and the provider stays up throughout ----
        //
        // The client keeps its `hostIdentifier`, so the new session registers the same device. The
        // old session's close (`stopAdvertising`, `removeAllHostedServices`, `eventHandler = nil`)
        // runs asynchronously behind it and is keyed by the same identifier. Without a generation
        // on the handle, that teardown would hit the new session's device.
        hostLink.dropLinkForTesting()
        // The drop and the 50 ms redial are asynchronous and report no completion. Polling for the
        // link to go down would race the reconnect, so a fixed-delay fallback covers the round trip
        // before the test waits for the reconnection.
        try await Task.sleep(for: .milliseconds(200))
        await waitFor(timeout: .seconds(10)) { hostLink.isProviderConnected && host.state == .poweredOn }

        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Sim Host", serviceUUIDs: [Self.heartRate])
        )

        // Advertising works after the reconnect. The device is still on the radio with its old
        // identifier, and it serves the database that it just published again.
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

        // A peripheral-role client asks to be hosted under the fixture's identifier. The test uses
        // a raw connection, because `LinkPeripheralManager` creates its own identity.
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

        // The provider serves the client but refuses the choice of identity. The hello reports the
        // identifier it registered, so the client can tell that its choice was overridden.
        #expect(answer.withLock { $0?.accepted } == true)
        let assigned = try #require(answer.withLock { $0?.assignedHostIdentifier })
        #expect(assigned != fixtureID)
        await waitFor(timeout: .seconds(5)) { provider.radio.knownDeviceIDs.withLock { $0.count } == 2 }
        #expect(provider.radio.knownDeviceIDs.withLock { $0.count } == 2)

        // The fixture is untouched, and the handle that registered it still drives it. A second
        // registration would have made that handle stale.
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

    @Test("A device added at runtime is defended while it is hosted, and stop() removes it")
    func addedVirtualDeviceIsRemovedByStop() async throws {
        let addedJSON = """
        { "devices": [ { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C9", "name": "Added HRM",
          "advertisedServices": ["180D"], "services": [ { "uuid": "180D", "characteristics": [
            { "uuid": "2A37", "properties": ["read", "notify"], "value": "AEg=" } ] } ] } ] }
        """
        let addedID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C9")!
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()

        // The registration happens after start, through the runtime entry point and not through the
        // fixture document. This is the path that kept no handle.
        let fixture = try FixtureDocument.parse(Data(addedJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        let handle = await provider.addVirtualDevice(device)
        await handler.attach(handle)
        #expect(provider.radio.knownDeviceIDs.withLock { $0.contains(addedID) })

        // A peripheral-role client that claims that identifier is refused it, as a client that
        // claims a fixture's identifier is.
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "host.e2e.added")
        )
        let answer = Mutex<ServerHello?>(nil)
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .peripheral,
                clientName: "collider",
                hostIdentifier: addedID
            )))
        }
        connection.onMessage = { message in
            guard case .serverHello(let hello) = message else { return }
            answer.withLock { $0 = hello }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { answer.withLock { $0 } != nil }
        #expect(answer.withLock { $0?.accepted } == true)
        #expect(try #require(answer.withLock { $0?.assignedHostIdentifier }) != addedID)
        #expect(await provider.radio.services(of: addedID, matching: nil) == [Self.heartRate])

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()

        await provider.stop()
        #expect(provider.radio.knownDeviceIDs.withLock { !$0.contains(addedID) })
        #expect(await provider.radio.services(of: addedID, matching: nil).isEmpty)
    }

    @Test("Two fixtures declaring the same id fail the provider's start")
    func duplicateFixtureIdentifiersAreRejectedAtStart() async throws {
        let fixtureJSON = """
        { "devices": [
          { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "One",
            "advertisedServices": ["180D"], "services": [] },
          { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "Two",
            "advertisedServices": ["180F"], "services": [] } ] }
        """
        let duplicate = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.fixtures = try FixtureDocument.parse(Data(fixtureJSON.utf8)).devices
        let provider = Provider(configuration: configuration)

        await #expect(throws: ProviderFixtureError.duplicateIdentifier(duplicate)) {
            try await provider.start()
        }
        #expect("\(ProviderFixtureError.duplicateIdentifier(duplicate))".contains(duplicate.uuidString))

        // The provider registered nothing and bound no port. The second declaration would have
        // replaced the first on the radio and stranded the handle that the provider vended for it.
        #expect(provider.radio.knownDeviceIDs.withLock { $0.isEmpty })
        #expect(await provider.port == 0)
        await provider.stop()
    }

    @Test("stop() takes the fixtures off the radio and start() registers them afresh")
    func stopUnregistersFixturesAndStartRegistersThemAgain() async throws {
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
        #expect(provider.radio.knownDeviceIDs.withLock { $0 } == [fixtureID])
        let stale = try #require(await provider.handle(for: fixtureID))

        // A stopped provider hosts nothing and leaves the radio as it found it. There is no handle
        // to vend for a device that is no longer on the radio.
        await provider.stop()
        #expect(provider.radio.knownDeviceIDs.withLock { $0.isEmpty })
        #expect(await provider.handle(for: fixtureID) == nil)

        // When the provider starts again, it registers the same configured fixture again. This is a
        // new registration under the same id.
        try await provider.start()
        #expect(provider.radio.knownDeviceIDs.withLock { $0 } == [fixtureID])
        #expect(await provider.radio.services(of: fixtureID, matching: nil) == [Self.heartRate])

        // The handle from before the stop is stale for good. The radio's generation guard refuses
        // everything it asks for, so it cannot drive the device that replaced its own.
        await stale.setServices([])
        #expect(await provider.radio.services(of: fixtureID, matching: nil) == [Self.heartRate])

        let fresh = try #require(await provider.handle(for: fixtureID))
        await fresh.setServices([])
        #expect(await provider.radio.services(of: fixtureID, matching: nil).isEmpty)
        await provider.stop()
    }

    @Test("A redial reaching the provider before its old session was torn down keeps its identity")
    func aRedialBeforeTheOldSessionIsGoneKeepsItsIdentifier() async throws {
        let provider = try await makeProvider()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)
        let wanted = UUID()

        // Two peripheral-role sessions ask for the same identity, and the second opens while the
        // first is live. This is the extreme case of a fast redial: the old session's device
        // removal has not started. The test uses raw connections, because a reconnect only probably
        // produces this ordering and the answer must not depend on which side wins.
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
        // The session keeps the identity, which belongs to the client, even though the radio still
        // held the device that the first session registered.
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

    /// Runs `make` until the provider can bind again the port that the previous provider released.
    /// A listener that just closed may hold the port for a moment.
    private static func rebind(port: UInt16, _ make: () async throws -> Provider) async throws -> Provider {
        for _ in 0..<20 {
            do { return try await make() } catch { try? await Task.sleep(for: .milliseconds(100)) }
        }
        return try await make()
    }
}
#endif
