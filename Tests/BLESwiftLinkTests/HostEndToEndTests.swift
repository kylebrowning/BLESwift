//
//  HostEndToEndTests.swift
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
    private func makeProvider() async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
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
        // No public "notifications are armed" signal, so a fixed delay stands in for one,
        // exactly as the in-process sim-to-sim tests do.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !host.subscribers(for: Self.measurement).isEmpty)
        try await host.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil)
        #expect(try await notifications.value == Data([0, 99]))

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
    /// A provider whose peripheral-role backend is composed with a fake that always reports a
    /// full transmit queue, so the provider parks every push and never acknowledges one — the
    /// only way to hold the client's window open long enough to drop the link under it.
    private func makeStallingProvider(port: UInt16) async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: port)
        configuration.passthrough = true
        configuration.peripheralManagerBackendFactory = { queue in
            let fake = FakePeripheralManager(queue: queue, state: .poweredOn)
            // Called inside the provider's `queue.sync`, so this is already on `queue`.
            fake.scriptedUpdateValueReturns = Array(repeating: false, count: 500)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    @Test("A provider drop empties the notification window, and the reconnect releases a blocked host")
    func windowSurvivesProviderDrop() async throws {
        let first = try await makeStallingProvider(port: 0)
        let port = await first.port
        let queue = DispatchSerialQueue(label: "host.e2e.drop")
        let link = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: queue,
            clientName: "drop-e2e",
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

        // The provider parks the very first push, so nothing is ever acknowledged and the
        // window fills for real.
        let results = await Self.onQueue(queue) {
            (0..<33).map { _ in link.updateValue(Data([0, 99]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(results.prefix(LinkFlowControl.updateValueWindow).allSatisfy { $0 })
        #expect(results[LinkFlowControl.updateValueWindow] == false)
        #expect(readyCount.withLock { $0 } == 0)

        // ---- Drop the provider with the window full ----
        await first.stop()
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .unsupported } }
        #expect(states.withLock { $0.last } == .unsupported)
        // The drop alone must not release the host: the radio it would push at is gone.
        #expect(readyCount.withLock { $0 } == 0)

        // ---- A new provider on the same port; the reconnect releases the blocked host ----
        let second = try await Self.rebind(port: port) { try await self.makeStallingProvider(port: port) }
        await waitFor(timeout: .seconds(10)) { states.withLock { $0.last == .poweredOn } }
        #expect(states.withLock { $0.last } == .poweredOn)
        await waitFor(timeout: .seconds(5)) { readyCount.withLock { $0 } == 1 }
        #expect(readyCount.withLock { $0 } == 1)
        #expect(await Self.onQueue(queue) { link.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil) })

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await second.sessionCount == 0 }
        await second.stop()
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
