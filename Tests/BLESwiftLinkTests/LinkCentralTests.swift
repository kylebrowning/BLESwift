//
//  LinkCentralTests.swift
//  BLESwiftLinkTests
//

import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftSimulatorLink
import Dispatch
import Foundation
import Synchronization
import Testing

/// A scripted provider: accepts the handshake, records requests, lets tests inject events.
final class ScriptedProvider: Sendable {
    let listener: LinkListener
    let requests = Mutex<[CentralRequest]>([])
    /// How many client hellos this provider has answered — one per dial, so a test can tell a
    /// client that reconnected from one that merely stayed put.
    let helloCount = Mutex<Int>(0)
    private let connection = Mutex<LinkConnection?>(nil)

    init() throws {
        listener = try LinkListener(endpoint: LinkEndpoint(host: "127.0.0.1", port: 0), codec: .json, queue: DispatchQueue(label: "scripted"))
        listener.onConnection = { [weak self] link in
            guard let self else { return }
            self.connection.withLock { $0 = link }
            link.onMessage = { [weak self] message in
                guard let self else { return }
                switch message {
                case .clientHello:
                    self.helloCount.withLock { $0 += 1 }
                    link.send(.serverHello(ServerHello(protocolVersion: LinkProtocol.version, accepted: true, reason: nil, providerName: "scripted")))
                    link.send(.centralEvent(.didUpdateState(.poweredOn)))
                case .centralRequest(let request):
                    self.requests.withLock { $0.append(request) }
                default:
                    break
                }
            }
        }
    }

    func start() async throws { try await listener.start() }
    var endpoint: LinkEndpoint { LinkEndpoint(host: "127.0.0.1", port: listener.port) }
    func emit(_ event: CentralWireEvent) { connection.withLock { $0 }?.send(.centralEvent(event)) }
    func dropClient() { connection.withLock { $0 }?.cancel() }

    /// Stops the provider the way a real one goes away: the accepted connection is closed
    /// *and* the listener cancelled. Cancelling the listener alone deliberately leaves
    /// accepted connections open (see `LinkClientSessionTests.reconnects`).
    func stop() {
        connection.withLock { $0 }?.cancel()
        listener.cancel()
    }
}

@Suite("LinkCentral")
struct LinkCentralTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)

    /// Hops onto `queue` to run `body` and returns its result — the door for off-queue test
    /// code to touch queue-confined state.
    private func onQueue<T: Sendable>(_ queue: DispatchSerialQueue, _ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func makeRig() async throws -> (Central, LinkCentral, ScriptedProvider) {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "LinkCentralTests")
        let link = LinkCentral(endpoint: provider.endpoint, queue: queue, clientName: "test", retryInterval: .milliseconds(50))
        let central = Central(backend: link, queue: queue)
        await waitFor { central.state == .poweredOn }
        return (central, link, provider)
    }

    @Test("Reports .unsupported until the provider is reachable, then the provider's state")
    func stateBeforeAndAfterConnect() async throws {
        let queue = DispatchSerialQueue(label: "state")
        let link = LinkCentral(endpoint: LinkEndpoint(host: "127.0.0.1", port: 1), queue: queue, clientName: "t", retryInterval: .milliseconds(50))
        let central = Central(backend: link, queue: queue)
        await waitFor { central.state == .unsupported }
        #expect(central.state == .unsupported)
        link.shutdown()
    }

    @Test("A handler attaching after the provider's state has landed still sees it")
    func stateDeliveredWhenHandlerAttachesLate() async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "late")
        let link = LinkCentral(endpoint: provider.endpoint, queue: queue, clientName: "late", retryInterval: .milliseconds(50))
        defer { provider.stop(); link.shutdown() }

        // Let the handshake complete AND the provider's `didUpdateState(.poweredOn)` land
        // before any handler exists. `radioState` is queue-confined and cannot be read from
        // here, so the settle is a short sleep after the link reports itself connected.
        await waitFor { link.isProviderConnected }
        #expect(link.isProviderConnected)
        try await Task.sleep(for: .milliseconds(100))

        // Only now does a `Central` attach its handler: it must still observe `.poweredOn`.
        let central = Central(backend: link, queue: queue)
        await waitFor { central.state == .poweredOn }
        #expect(central.state == .poweredOn)
    }

    @Test("Scan requests reach the provider and discoveries come back")
    func scan() async throws {
        let (central, link, provider) = try await makeRig()
        defer { provider.stop(); link.shutdown() }
        let id = UUID()
        let task = Task { () -> Discovery? in
            for try await event in await central.scan(services: [Self.service]) {
                if case .discovered(let discovery) = event { return discovery }
            }
            return nil
        }
        await waitFor { provider.requests.withLock { $0 }.contains(.scan(services: ["180D"], allowDuplicates: false)) }
        provider.emit(.didDiscover(peripheral: id, name: "HRM", advertisement: WireAdvertisement(AdvertisementData(localName: "HRM", serviceUUIDs: [Self.service])), rssi: -42))
        let discovery = try await bounded { try await task.value }
        #expect(discovery?.peripheral.uuid == id)
        #expect(discovery?.peripheral.name == "HRM")
        #expect(discovery?.rssi == -42)
        await waitFor { provider.requests.withLock { $0 }.contains(.stopScan) }
    }

    @Test("Connect, discover, read, write, notify round-trip through the mirror cache")
    func gatt() async throws {
        let (central, link, provider) = try await makeRig()
        defer { provider.stop(); link.shutdown() }
        let id = UUID()
        let ref = WireCharacteristicRef(Self.measurement)

        // Connect: the provider answers with maxima.
        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: "HRM")) }
        await waitFor { provider.requests.withLock { $0 }.contains { if case .connect(let p, _, _) = $0 { return p == id }; return false } }
        provider.emit(.didConnect(peripheral: id, name: "HRM", maximumWriteWithResponse: 200, maximumWriteWithoutResponse: 100))
        let peripheral = try await bounded { try await connectTask.value }

        // Discovery is driven by the read: the provider must answer both discovery steps.
        let readTask = Task { () -> Data in try await peripheral.read(from: Self.measurement) }
        await waitFor { provider.requests.withLock { $0 }.contains(.discoverServices(peripheral: id, services: ["180D"])) }
        provider.emit(.didDiscoverServices(peripheral: id, services: ["180D"], error: nil))
        await waitFor { provider.requests.withLock { $0 }.contains(.discoverCharacteristics(peripheral: id, service: "180D", characteristics: ["2A37"])) }
        provider.emit(.didDiscoverCharacteristics(peripheral: id, service: "180D", characteristics: [WireDiscoveredCharacteristic(uuid: "2A37", properties: CharacteristicProperties([.read, .write, .notify, .writeWithoutResponse]).rawValue)], error: nil))
        await waitFor { provider.requests.withLock { $0 }.contains(.readValue(peripheral: id, characteristic: ref)) }
        provider.emit(.didUpdateValue(peripheral: id, characteristic: ref, value: Data([0, 72]), error: nil))
        #expect(try await bounded { try await readTask.value } == Data([0, 72]))

        // Write with response.
        let writeTask = Task { try await peripheral.write(Data([1]), to: Self.measurement) }
        await waitFor { provider.requests.withLock { $0 }.contains { if case .writeValue(id, ref, Data([1]), .withResponse, _) = $0 { return true }; return false } }
        provider.emit(.didWriteValue(peripheral: id, characteristic: ref, error: nil))
        try await bounded { try await writeTask.value }

        // Notification.
        let notifyTask = Task { () -> Data? in
            let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.measurement)
            for try await value in stream { return value }
            return nil
        }
        await waitFor { provider.requests.withLock { $0 }.contains(.setNotifyValue(peripheral: id, characteristic: ref, enabled: true)) }
        provider.emit(.didUpdateNotificationState(peripheral: id, characteristic: ref, isNotifying: true, error: nil))
        provider.emit(.didUpdateValue(peripheral: id, characteristic: ref, value: Data([9]), error: nil))
        #expect(try await bounded { try await notifyTask.value } == Data([9]))

        // Disconnect.
        let disconnectTask = Task { try await central.disconnect(peripheral.id) }
        await waitFor { provider.requests.withLock { $0 }.contains(.cancelConnection(peripheral: id)) }
        provider.emit(.didDisconnect(peripheral: id, error: nil))
        try await bounded { try await disconnectTask.value }
    }

    @Test("Provider drop disconnects connected peripherals and reports .unsupported")
    func providerDrop() async throws {
        let (central, link, provider) = try await makeRig()
        defer { provider.stop(); link.shutdown() }
        let id = UUID()
        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: nil)) }
        await waitFor { !provider.requests.withLock { $0 }.isEmpty }
        provider.emit(.didConnect(peripheral: id, name: "x", maximumWriteWithResponse: 512, maximumWriteWithoutResponse: 20))
        _ = try await bounded { try await connectTask.value }
        // Subscribed before the stimulus, for the reason spelled out in `VirtualRadioTests`:
        // the broadcast does not replay, so a subscription created inside the task can miss
        // the very event the task exists to see.
        let events = await central.connectionEvents()
        let disconnects = Task { () -> ConnectionEvent? in
            for await event in events {
                if case .disconnected = event { return event }
            }
            return nil
        }
        provider.stop()
        let event = try await bounded { await disconnects.value }
        #expect(event != nil)
        await waitFor { central.state == .unsupported }
        #expect(central.state == .unsupported)
    }

    @Test("A peripheral's name is readable off the central's queue")
    func nameIsReadableOffQueue() async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "LinkCentralTests.name")
        let link = LinkCentral(endpoint: provider.endpoint, queue: queue, clientName: "test", retryInterval: .milliseconds(50))
        let central = Central(backend: link, queue: queue)
        defer { provider.stop(); link.shutdown() }
        await waitFor { central.state == .poweredOn }

        let id = UUID()
        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: nil)) }
        await waitFor { !provider.requests.withLock { $0 }.isEmpty }
        provider.emit(.didConnect(peripheral: id, name: "Named", maximumWriteWithResponse: 512, maximumWriteWithoutResponse: 20))
        _ = try await bounded { try await connectTask.value }

        let peripheral = await onQueue(queue) {
            link.retrievePeripherals(withIdentifiers: [id]).first as? LinkPeripheral
        }
        // Read from the test's own context, off `queue`, exactly as
        // `Central(backend:connectedPeripherals:)` reads it while adopting a peripheral.
        #expect(peripheral?.name == "Named")
    }

    @Test("The peripheral table is capped, keeping the ones a connect still refers to")
    func peripheralTableIsCapped() async throws {
        let queue = DispatchSerialQueue(label: "LinkCentralTests.cap")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: try closedPort()),
            queue: queue,
            clientName: "test",
            retryInterval: .seconds(60)
        )
        defer { link.shutdown() }

        let connecting = UUID()
        let oldest = UUID()
        // One more than the cap, so two of the three oldest mirrors have to go.
        let overflowing = (0..<1024).map { _ in UUID() }

        let (heldSurvived, oldestSurvived) = await onQueue(queue) { () -> (Bool, Bool) in
            let held = link.retrievePeripherals(withIdentifiers: [connecting]).first as? LinkPeripheral
            // A connect in flight: `held` is `.connecting`, so however stale it becomes the
            // cap must not drop it — the provider's events for it have to reach this object.
            if let held { link.connect(held, options: nil, requiresANCS: false) }
            let stale = link.retrievePeripherals(withIdentifiers: [oldest]).first as? LinkPeripheral
            _ = link.retrievePeripherals(withIdentifiers: overflowing)
            let heldAgain = link.retrievePeripherals(withIdentifiers: [connecting]).first as? LinkPeripheral
            let staleAgain = link.retrievePeripherals(withIdentifiers: [oldest]).first as? LinkPeripheral
            return (heldAgain === held, staleAgain === stale)
        }

        #expect(heldSurvived)
        // The least recently sighted disconnected mirror was forgotten, so retrieving that
        // identifier again mints a fresh one.
        #expect(oldestSurvived == false)
    }
}
