//
//  LinkCentralTests.swift
//  BLESwiftLinkTests
//

// Sockets in a CI simulator are not reliable: a wedged simulator network leaves a loopback connect
// in `.connecting` for tens of seconds. So the compiler removes every socket suite from the
// simulator build. The two-simulator E2E covers that path.
#if !targetEnvironment(simulator)
import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftSimulatorLink
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// A scripted provider. It accepts the handshake, records requests, and lets tests inject events.
final class ScriptedProvider: Sendable {
    let listener: LinkListener
    let requests = Mutex<[CentralRequest]>([])
    /// The number of client hellos that this provider has answered, one for each dial. A test can
    /// tell a client that reconnected from one that only stayed in place.
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

    /// Stops the provider the way a real one goes away: it closes the accepted connection *and*
    /// cancels the listener, because cancelling the listener alone leaves accepted connections
    /// open. See `LinkClientSessionTests.reconnects`.
    func stop() {
        connection.withLock { $0 }?.cancel()
        listener.cancel()
    }
}

@Suite("LinkCentral")
struct LinkCentralTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)

    /// Hops onto `queue` to run `body` and returns its result. Test code that runs off the queue
    /// uses this to touch state that the queue confines.
    private func onQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func makeRig() async throws -> (Central, LinkCentral, ScriptedProvider) {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchQueue(label: "LinkCentralTests")
        let link = LinkCentral(endpoint: provider.endpoint, queue: queue, clientName: "test", retryInterval: .milliseconds(50))
        let central = Central(backend: link, queue: queue)
        // The wait is generous, and the test asserts it. A starved runner can take seconds to hand
        // over a loopback connection, and a short wait would race a central that is not powered on
        // yet.
        await waitFor(timeout: .seconds(30)) { central.state == .poweredOn }
        #expect(central.state == .poweredOn)
        return (central, link, provider)
    }

    /// The number of `.connect` requests that `provider` has received for `peripheral`.
    ///
    /// A test waits on this before it emits a `didConnect`. A completion that arrives before the
    /// request has nowhere to land.
    private static func connectCount(_ provider: ScriptedProvider, for peripheral: UUID) -> Int {
        provider.requests.withLock { $0 }.filter { request in
            if case .connect(peripheral, _, _) = request { return true }
            return false
        }.count
    }

    /// Every event whose fields the client validates, made malformed: one for each `handle(_:)`
    /// case that names a peripheral *and* carries an identifier of its own.
    ///
    /// The identifier is the same in each event and must never reach the mirror table.
    static let malformedEvents: [(name: String, event: CentralWireEvent)] = {
        let peripheral = UUID(uuidString: "1F2E3D4C-5B6A-4798-8877-665544332211")!
        let badCharacteristic = WireCharacteristicRef(service: "180D", uuid: "zz")
        let badDescriptor = WireDescriptorRef(service: "180D", characteristic: "2A37", uuid: "zz")
        return [
            ("didDiscoverServices", .didDiscoverServices(peripheral: peripheral, services: ["zz"], error: nil)),
            ("didDiscoverCharacteristics", .didDiscoverCharacteristics(
                peripheral: peripheral,
                service: "zz",
                characteristics: [],
                error: nil
            )),
            ("didDiscoverDescriptors", .didDiscoverDescriptors(
                peripheral: peripheral,
                characteristic: badCharacteristic,
                descriptors: [],
                error: nil
            )),
            ("didWriteValue", .didWriteValue(peripheral: peripheral, characteristic: badCharacteristic, error: nil)),
            ("didUpdateValue", .didUpdateValue(
                peripheral: peripheral,
                characteristic: badCharacteristic,
                value: Data([1]),
                error: nil
            )),
            ("didUpdateNotificationState", .didUpdateNotificationState(
                peripheral: peripheral,
                characteristic: badCharacteristic,
                isNotifying: true,
                error: nil
            )),
            ("didUpdateValueForDescriptor", .didUpdateValueForDescriptor(
                peripheral: peripheral,
                descriptor: badDescriptor,
                value: Data([1]),
                error: nil
            )),
            ("didWriteValueForDescriptor", .didWriteValueForDescriptor(
                peripheral: peripheral,
                descriptor: badDescriptor,
                error: nil
            )),
            ("didModifyServices", .didModifyServices(peripheral: peripheral, invalidated: ["zz"])),
            ("didDiscover", .didDiscover(
                peripheral: peripheral,
                name: nil,
                advertisement: WireAdvertisement(
                    localName: nil,
                    serviceUUIDs: ["zz"],
                    manufacturerData: nil,
                    serviceData: nil,
                    txPowerLevel: nil,
                    isConnectable: true,
                    overflowServiceUUIDs: nil,
                    solicitedServiceUUIDs: nil
                ),
                rssi: -50
            )),
        ]
    }()

    @Test(
        "A malformed event costs the session without filing a mirror for the peripheral it named",
        arguments: malformedEvents.map(\.name).indices
    )
    func malformedEventFilesNoMirror(index: Int) async throws {
        let (_, link, provider) = try await makeRig()
        defer { provider.stop(); link.shutdown() }
        let queue = link.queue
        #expect(await onQueue(queue) { link.peripheralCount } == 0)
        #expect(provider.helloCount.withLock { $0 } == 1)

        provider.emit(Self.malformedEvents[index].event)

        await waitFor(timeout: .seconds(30)) { provider.helloCount.withLock { $0 } >= 2 }
        #expect(provider.helloCount.withLock { $0 } >= 2, "\(Self.malformedEvents[index].name)")
        // The mirror table never heard of the peripheral that the event named. A mirror created for
        // an event that then threw would be `.disconnected`, survive the reconnect, be reported as
        // a known peripheral, and could evict a real mirror.
        #expect(await onQueue(queue) { link.peripheralCount } == 0, "\(Self.malformedEvents[index].name)")
    }

    @Test("Reports .unsupported until the provider is reachable, then the provider's state")
    func stateBeforeAndAfterConnect() async throws {
        let queue = DispatchQueue(label: "state")
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
        let queue = DispatchQueue(label: "late")
        let link = LinkCentral(endpoint: provider.endpoint, queue: queue, clientName: "late", retryInterval: .milliseconds(50))
        defer { provider.stop(); link.shutdown() }

        // Let the handshake complete AND the provider's `didUpdateState(.poweredOn)` land before
        // any handler exists. The test cannot read `radioState` off the queue, so it sleeps briefly
        // after the link reports connected.
        await waitFor { link.isProviderConnected }
        #expect(link.isProviderConnected)
        try await Task.sleep(for: .milliseconds(100))

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

        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: "HRM")) }
        await waitFor { provider.requests.withLock { $0 }.contains { if case .connect(let p, _, _) = $0 { return p == id }; return false } }
        provider.emit(.didConnect(peripheral: id, name: "HRM", maximumWriteWithResponse: 200, maximumWriteWithoutResponse: 100))
        let peripheral = try await bounded { try await connectTask.value }

        let readTask = Task { () -> Data in try await peripheral.read(from: Self.measurement) }
        await waitFor { provider.requests.withLock { $0 }.contains(.discoverServices(peripheral: id, services: ["180D"])) }
        provider.emit(.didDiscoverServices(peripheral: id, services: ["180D"], error: nil))
        await waitFor { provider.requests.withLock { $0 }.contains(.discoverCharacteristics(peripheral: id, service: "180D", characteristics: ["2A37"])) }
        provider.emit(.didDiscoverCharacteristics(peripheral: id, service: "180D", characteristics: [WireDiscoveredCharacteristic(uuid: "2A37", properties: CharacteristicProperties([.read, .write, .notify, .writeWithoutResponse]).rawValue)], error: nil))
        await waitFor { provider.requests.withLock { $0 }.contains(.readValue(peripheral: id, characteristic: ref)) }
        provider.emit(.didUpdateValue(peripheral: id, characteristic: ref, value: Data([0, 72]), error: nil))
        #expect(try await bounded { try await readTask.value } == Data([0, 72]))

        let writeTask = Task { try await peripheral.write(Data([1]), to: Self.measurement) }
        await waitFor { provider.requests.withLock { $0 }.contains { if case .writeValue(id, ref, Data([1]), .withResponse, _) = $0 { return true }; return false } }
        provider.emit(.didWriteValue(peripheral: id, characteristic: ref, error: nil))
        try await bounded { try await writeTask.value }

        let notifyTask = Task { () -> Data? in
            let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.measurement)
            for try await value in stream { return value }
            return nil
        }
        await waitFor { provider.requests.withLock { $0 }.contains(.setNotifyValue(peripheral: id, characteristic: ref, enabled: true)) }
        provider.emit(.didUpdateNotificationState(peripheral: id, characteristic: ref, isNotifying: true, error: nil))
        provider.emit(.didUpdateValue(peripheral: id, characteristic: ref, value: Data([9]), error: nil))
        #expect(try await bounded { try await notifyTask.value } == Data([9]))

        let disconnectTask = Task { try await central.disconnect(peripheral.id) }
        await waitFor { provider.requests.withLock { $0 }.contains(.cancelConnection(peripheral: id)) }
        provider.emit(.didDisconnect(peripheral: id, error: nil))
        try await bounded { try await disconnectTask.value }
    }

    @Test("shutdown fails an in-flight read instead of stranding it")
    func shutdownFailsAnInFlightRead() async throws {
        let (central, link, provider) = try await makeRig()
        defer { provider.stop() }
        let id = UUID()
        let ref = WireCharacteristicRef(Self.measurement)

        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: "HRM")) }
        await waitFor { provider.requests.withLock { $0 }.contains { if case .connect(let p, _, _) = $0 { return p == id }; return false } }
        provider.emit(.didConnect(peripheral: id, name: "HRM", maximumWriteWithResponse: 200, maximumWriteWithoutResponse: 100))
        let peripheral = try await bounded { try await connectTask.value }

        // The provider receives a read and never answers it. A consumer is in this state when it
        // decides to tear the link down.
        let readTask = Task { () -> Data in try await peripheral.read(from: Self.measurement) }
        await waitFor { provider.requests.withLock { $0 }.contains(.discoverServices(peripheral: id, services: ["180D"])) }
        provider.emit(.didDiscoverServices(peripheral: id, services: ["180D"], error: nil))
        await waitFor { provider.requests.withLock { $0 }.contains(.discoverCharacteristics(peripheral: id, service: "180D", characteristics: ["2A37"])) }
        provider.emit(.didDiscoverCharacteristics(
            peripheral: id,
            service: "180D",
            characteristics: [WireDiscoveredCharacteristic(uuid: "2A37", properties: CharacteristicProperties([.read]).rawValue)],
            error: nil
        ))
        await waitFor { provider.requests.withLock { $0 }.contains(.readValue(peripheral: id, characteristic: ref)) }

        // This is the teardown that the branch's tests use. It must fail what is in flight, as it
        // does when the provider goes away, instead of hanging on a completion that never comes.
        link.shutdown()
        await #expect(throws: BLESwiftError.unexpectedDisconnect) {
            try await bounded("read after shutdown", seconds: 1) { try await readTask.value }
        }
        await waitFor(timeout: .seconds(1)) { central.state == .unsupported }
        #expect(central.state == .unsupported)
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
        // Subscribe before the stimulus, as in `VirtualRadioTests`: the broadcast does not replay,
        // so a subscription created inside the task can miss the event.
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
        let queue = DispatchQueue(label: "LinkCentralTests.name")
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
        // The test reads from its own context, off `queue`, as
        // `Central(backend:connectedPeripherals:)` does when it adopts a peripheral.
        #expect(peripheral?.name == "Named")
    }

    @Test("A stale write acknowledgement cannot open the next connection's window")
    func staleWriteAcknowledgementIsIgnored() async throws {
        let (central, link, provider) = try await makeRig()
        defer { provider.stop(); link.shutdown() }
        let queue = link.queue
        let id = UUID()
        let window = LinkFlowControl.writeWithoutResponseWindow

        // Connect, then fill the flow-control window from the mirror itself. `Central` honors the
        // window, so only a direct drive gets it to the brim.
        //
        // Every wait gates on something observable (a recorded request or a mirror state) with a
        // bound wide enough for a starved runner. Nothing waits on elapsed time, and the test emits
        // nothing before the request that it answers has arrived.
        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: nil)) }
        await waitFor(timeout: .seconds(30)) { Self.connectCount(provider, for: id) == 1 }
        #expect(Self.connectCount(provider, for: id) == 1)
        provider.emit(.didConnect(peripheral: id, name: nil, maximumWriteWithResponse: 512, maximumWriteWithoutResponse: 20))
        _ = try await bounded(seconds: 30) { try await connectTask.value }

        let peripheral = try #require(await onQueue(queue) {
            link.retrievePeripherals(withIdentifiers: [id]).first as? LinkPeripheral
        })
        await discoverMeasurement(provider, peripheral, for: id, on: queue)
        await Self.fillWindow(peripheral, on: queue, count: window)
        #expect(await onQueue(queue) { !peripheral.canSendWriteWithoutResponse })
        await waitFor(timeout: .seconds(30)) { Self.writeSequences(provider, for: id).count == window }
        let stale = Self.writeSequences(provider, for: id)
        #expect(stale.count == window)

        // The connection resets and its outstanding writes go with it, but the provider's
        // acknowledgements for these writes may already be on the wire.
        provider.emit(.didDisconnect(peripheral: id, error: nil))
        await waitFor(timeout: .seconds(30)) { await onQueue(queue) { peripheral.connectionState == .disconnected } }
        #expect(await onQueue(queue) { peripheral.connectionState == .disconnected })

        // A second connection fills the window again with fresh sequences. The completion waits for
        // the second `connect`, or it would land on a mirror that is not connecting yet.
        let reconnectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: nil)) }
        await waitFor(timeout: .seconds(30)) { Self.connectCount(provider, for: id) == 2 }
        #expect(Self.connectCount(provider, for: id) == 2)
        provider.emit(.didConnect(peripheral: id, name: nil, maximumWriteWithResponse: 512, maximumWriteWithoutResponse: 20))
        _ = try await bounded(seconds: 30) { try await reconnectTask.value }
        // The disconnect emptied the mirror's discovery cache, together with everything else that
        // belongs to one connection. The second connection therefore discovers again.
        await discoverMeasurement(provider, peripheral, for: id, on: queue)
        await Self.fillWindow(peripheral, on: queue, count: window)
        #expect(await onQueue(queue) { !peripheral.canSendWriteWithoutResponse })
        await waitFor(timeout: .seconds(30)) { Self.writeSequences(provider, for: id).count == 2 * window }
        let live = Self.writeSequences(provider, for: id).filter { !stale.contains($0) }
        #expect(live.count == window)

        // Every acknowledgement from the first connection now lands. None of those sequences is
        // outstanding any more, so none may credit this connection's window.
        for sequence in stale {
            provider.emit(.writeWithoutResponseAccepted(peripheral: id, sequence: sequence))
        }
        provider.emit(.writeWithoutResponseAccepted(peripheral: id, sequence: .max))

        // A barrier. The link is ordered, so the test sees nothing behind those acknowledgements
        // until the session has handled all of them. The window must still be shut.
        provider.emit(.didUpdateANCSAuthorization(peripheral: id, authorized: true))
        await waitFor(timeout: .seconds(30)) { await onQueue(queue) { peripheral.ancsAuthorized } }
        #expect(await onQueue(queue) { peripheral.ancsAuthorized })
        #expect(await onQueue(queue) { !peripheral.canSendWriteWithoutResponse })

        provider.emit(.writeWithoutResponseAccepted(peripheral: id, sequence: try #require(live.first)))
        await waitFor(timeout: .seconds(30)) { await onQueue(queue) { peripheral.canSendWriteWithoutResponse } }
        #expect(await onQueue(queue) { peripheral.canSendWriteWithoutResponse })
    }

    /// Issues `count` `.withoutResponse` writes straight at `peripheral`, which fills the link's
    /// flow-control window.
    @Test("A read for a characteristic the mirror has not seen discovered is a no-op")
    func undiscoveredReadIsANoOp() async throws {
        let (central, link, provider) = try await makeRig()
        defer { provider.stop(); link.shutdown() }
        let queue = link.queue
        let id = UUID()

        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: nil)) }
        await waitFor(timeout: .seconds(30)) { Self.connectCount(provider, for: id) == 1 }
        provider.emit(.didConnect(peripheral: id, name: nil, maximumWriteWithResponse: 512, maximumWriteWithoutResponse: 20))
        _ = try await bounded(seconds: 30) { try await connectTask.value }

        let peripheral = try #require(await onQueue(queue) {
            link.retrievePeripherals(withIdentifiers: [id]).first as? LinkPeripheral
        })
        #expect(await onQueue(queue) { !peripheral.isDiscovered(Self.measurement) })

        // Nothing was discovered, so the client sends nothing. CoreBluetooth gives the same silence
        // to a read on a characteristic for which it has no object.
        await onQueue(queue) { peripheral.readValue(for: Self.measurement) }

        // A barrier behind it. The link is ordered, so when the provider has recorded this request,
        // it would also have recorded the read if the client had sent one.
        await onQueue(queue) { peripheral.readRSSI() }
        await waitFor(timeout: .seconds(30)) { provider.requests.withLock { $0 }.contains(.readRSSI(peripheral: id)) }
        let reads = provider.requests.withLock { $0 }.filter { request in
            if case .readValue = request { return true }
            return false
        }
        #expect(reads.isEmpty)

        // When the characteristic is discovered, the very same read goes out. The cache is the
        // guard, not the request.
        await discoverMeasurement(provider, peripheral, for: id, on: queue)
        await onQueue(queue) { peripheral.readValue(for: Self.measurement) }
        await waitFor(timeout: .seconds(30)) {
            provider.requests.withLock { $0 }.contains(
                .readValue(peripheral: id, characteristic: WireCharacteristicRef(Self.measurement))
            )
        }
        #expect(provider.requests.withLock { $0 }.contains(
            .readValue(peripheral: id, characteristic: WireCharacteristicRef(Self.measurement))
        ))
    }

    /// The descriptor that the test uses to exercise the descriptor-side guards. It was never
    /// discovered, so the mirror cache has no record of it or of the characteristic under it.
    private static let configuration = DescriptorIdentifier(uuid: "2902", characteristic: measurement)

    /// Runs `body` against a connected peripheral whose mirror cache is empty, then puts a
    /// `readRSSI` barrier behind it and returns every request that the provider saw.
    ///
    /// The link is ordered, so once the barrier is recorded, anything `body` would have sent is
    /// too. The absence is real, not a race.
    private func requestsAfterUndiscovered(
        _ body: @Sendable @escaping (LinkPeripheral) -> Void
    ) async throws -> [CentralRequest] {
        let (central, link, provider) = try await makeRig()
        defer { provider.stop(); link.shutdown() }
        let queue = link.queue
        let id = UUID()

        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: nil)) }
        await waitFor(timeout: .seconds(30)) { Self.connectCount(provider, for: id) == 1 }
        provider.emit(.didConnect(peripheral: id, name: nil, maximumWriteWithResponse: 512, maximumWriteWithoutResponse: 20))
        _ = try await bounded(seconds: 30) { try await connectTask.value }

        let peripheral = try #require(await onQueue(queue) {
            link.retrievePeripherals(withIdentifiers: [id]).first as? LinkPeripheral
        })
        #expect(await onQueue(queue) { !peripheral.isDiscovered(Self.service) })
        #expect(await onQueue(queue) { !peripheral.isDiscovered(Self.measurement) })
        #expect(await onQueue(queue) { !peripheral.isDiscovered(Self.configuration) })

        await onQueue(queue) { body(peripheral) }
        await onQueue(queue) { peripheral.readRSSI() }
        await waitFor(timeout: .seconds(30)) { provider.requests.withLock { $0 }.contains(.readRSSI(peripheral: id)) }
        return provider.requests.withLock { $0 }
    }

    @Test("A characteristic discovery for a service the mirror has not seen discovered is a no-op")
    func undiscoveredCharacteristicDiscoveryIsANoOp() async throws {
        let requests = try await requestsAfterUndiscovered { $0.discoverCharacteristics(nil, for: Self.service) }
        #expect(requests.allSatisfy { request in
            if case .discoverCharacteristics = request { return false }
            return true
        })
    }

    @Test("A descriptor discovery for a characteristic the mirror has not seen discovered is a no-op")
    func undiscoveredDescriptorDiscoveryIsANoOp() async throws {
        let requests = try await requestsAfterUndiscovered { $0.discoverDescriptors(for: Self.measurement) }
        #expect(requests.allSatisfy { request in
            if case .discoverDescriptors = request { return false }
            return true
        })
    }

    @Test("A read of a descriptor the mirror has not seen discovered is a no-op")
    func undiscoveredDescriptorReadIsANoOp() async throws {
        let requests = try await requestsAfterUndiscovered { $0.readValue(for: Self.configuration) }
        #expect(requests.allSatisfy { request in
            if case .readDescriptor = request { return false }
            return true
        })
    }

    @Test("A write to a descriptor the mirror has not seen discovered is a no-op")
    func undiscoveredDescriptorWriteIsANoOp() async throws {
        let requests = try await requestsAfterUndiscovered { $0.writeValue(Data([1]), for: Self.configuration) }
        #expect(requests.allSatisfy { request in
            if case .writeDescriptor = request { return false }
            return true
        })
    }

    /// Puts ``measurement`` in `peripheral`'s mirror cache, as a real provider would. A
    /// `PeripheralRemote` ignores a write to a characteristic that it has not seen discovered.
    ///
    /// The test emits the events unprompted and waits on the cache itself.
    private func discoverMeasurement(
        _ provider: ScriptedProvider,
        _ peripheral: LinkPeripheral,
        for identifier: UUID,
        on queue: DispatchQueue
    ) async {
        provider.emit(.didDiscoverServices(peripheral: identifier, services: [Self.service.uuidString], error: nil))
        provider.emit(.didDiscoverCharacteristics(
            peripheral: identifier,
            service: Self.service.uuidString,
            characteristics: [WireDiscoveredCharacteristic(
                uuid: Self.measurement.uuidString,
                properties: CharacteristicProperties([.write, .writeWithoutResponse, .notify, .read]).rawValue
            )],
            error: nil
        ))
        await waitFor(timeout: .seconds(30)) { await onQueue(queue) { peripheral.isDiscovered(Self.measurement) } }
    }

    private static func fillWindow(_ peripheral: LinkPeripheral, on queue: DispatchQueue, count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                for _ in 0..<count {
                    peripheral.writeValue(Data([1]), for: Self.measurement, type: .withoutResponse)
                }
                continuation.resume()
            }
        }
    }

    /// The sequences of every `.withoutResponse` write that `provider` has received for
    /// `peripheral`, in arrival order.
    private static func writeSequences(_ provider: ScriptedProvider, for peripheral: UUID) -> [UInt64] {
        provider.requests.withLock { $0 }.compactMap { request in
            guard case .writeValue(peripheral, _, _, .withoutResponse, let sequence) = request else { return nil }
            return sequence
        }
    }

    @Test("The peripheral table is capped, keeping the ones a connect still refers to")
    func peripheralTableIsCapped() async throws {
        let queue = DispatchQueue(label: "LinkCentralTests.cap")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: try closedPort()),
            queue: queue,
            clientName: "test",
            retryInterval: .seconds(60)
        )
        defer { link.shutdown() }

        let connecting = UUID()
        let oldest = UUID()
        let overflowing = (0..<1024).map { _ in UUID() }

        let (heldSurvived, oldestSurvived) = await onQueue(queue) { () -> (Bool, Bool) in
            let held = link.retrievePeripherals(withIdentifiers: [connecting]).first as? LinkPeripheral
            // A connect is in flight. `held` is `.connecting`, so the cap must not drop it, however
            // stale it becomes. The provider's events for it have to reach this object.
            if let held { link.connect(held, options: nil, requiresANCS: false) }
            let stale = link.retrievePeripherals(withIdentifiers: [oldest]).first as? LinkPeripheral
            _ = link.retrievePeripherals(withIdentifiers: overflowing)
            let heldAgain = link.retrievePeripherals(withIdentifiers: [connecting]).first as? LinkPeripheral
            let staleAgain = link.retrievePeripherals(withIdentifiers: [oldest]).first as? LinkPeripheral
            return (heldAgain === held, staleAgain === stale)
        }

        #expect(heldSurvived)
        // The central forgot the disconnected mirror that it sighted least recently. When the test
        // retrieves that identifier again, the central creates a fresh mirror.
        #expect(oldestSurvived == false)
    }

    @Test("The peripheral mirror cap evicts the least recently sighted disconnected mirror")
    func peripheralCapEvictsTheOldestMirror() async throws {
        let queue = DispatchQueue(label: "LinkCentralTests.evict")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: try closedPort()),
            queue: queue,
            clientName: "test",
            retryInterval: .seconds(60),
            maximumPeripherals: 1
        )
        defer { link.shutdown() }

        let oldest = UUID()
        let newest = UUID()
        let survived = await onQueue(queue) { () -> Bool in
            let first = link.retrievePeripherals(withIdentifiers: [oldest]).first as? LinkPeripheral
            _ = link.retrievePeripherals(withIdentifiers: [newest])
            return link.retrievePeripherals(withIdentifiers: [oldest]).first as? LinkPeripheral === first
        }
        #expect(survived == false)
    }

    @Test("An evicted mirror is detached from its event handler before it is forgotten")
    func peripheralCapDetachesTheMirrorItEvicts() async throws {
        let queue = DispatchQueue(label: "LinkCentralTests.evictDetach")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: try closedPort()),
            queue: queue,
            clientName: "test",
            retryInterval: .seconds(60),
            maximumPeripherals: 1
        )
        defer { link.shutdown() }

        let oldest = UUID()
        let newest = UUID()
        let detached = await onQueue(queue) { () -> Bool in
            guard let first = link.retrievePeripherals(withIdentifiers: [oldest]).first as? LinkPeripheral else {
                return false
            }
            first.eventHandler = { _ in }
            // One over the cap. The older, disconnected mirror is the one to go. Its owner may well
            // still hold it.
            _ = link.retrievePeripherals(withIdentifiers: [newest])
            return first.eventHandler == nil
        }
        #expect(detached)
    }

    @Test("A table full of busy mirrors cannot make the cap evict the mirror it is minting")
    func peripheralCapNeverEvictsTheMirrorItJustCreated() async throws {
        let queue = DispatchQueue(label: "LinkCentralTests.reserve")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: try closedPort()),
            queue: queue,
            clientName: "test",
            retryInterval: .seconds(60),
            maximumPeripherals: 1
        )
        defer { link.shutdown() }

        let busy = UUID()
        let fresh = UUID()
        let filed = await onQueue(queue) { () -> Bool in
            // The one slot that the cap allows holds a connect in flight. The cap may never drop
            // such a mirror.
            if let held = link.retrievePeripherals(withIdentifiers: [busy]).first as? LinkPeripheral {
                link.connect(held, options: nil, requiresANCS: false)
            }
            // Retrieving a second identifier overflows a table with nothing evictable. The mirror
            // created here must still be the one filed under `fresh`, or its owner holds an object
            // that the provider's events never reach.
            let created = link.retrievePeripherals(withIdentifiers: [fresh]).first as? LinkPeripheral
            let again = link.retrievePeripherals(withIdentifiers: [fresh]).first as? LinkPeripheral
            return created != nil && created === again
        }
        #expect(filed)
    }

    @Test("A connect to a peripheral the cap evicted re-files it instead of dropping the request")
    func connectRefilesAnEvictedPeripheral() async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchQueue(label: "LinkCentralTests.evictedConnect")
        let link = LinkCentral(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "test",
            retryInterval: .milliseconds(50),
            maximumPeripherals: 1
        )
        defer { link.shutdown(); provider.stop() }
        await waitFor(timeout: .seconds(30)) { link.isProviderConnected }
        #expect(link.isProviderConnected)

        let target = UUID()
        let held = try #require(await onQueue(queue) {
            link.retrievePeripherals(withIdentifiers: [target]).first as? LinkPeripheral
        })
        // The test overflows the cap of one, which evicts `held` between the retrieval and the
        // connect. A caller that holds a perfectly valid peripheral cannot see this window.
        await onQueue(queue) { _ = link.retrievePeripherals(withIdentifiers: [UUID()]) }

        await onQueue(queue) { link.connect(held, options: nil, requiresANCS: false) }

        await waitFor(timeout: .seconds(10)) { Self.connectCount(provider, for: target) == 1 }
        #expect(Self.connectCount(provider, for: target) == 1)
        // The central files the mirror again under its identifier, so the provider's events for it
        // reach the very object that the caller holds.
        #expect(await onQueue(queue) { link.retrievePeripherals(withIdentifiers: [target]).first as? LinkPeripheral === held })
        #expect(await onQueue(queue) { held.connectionState } == .connecting)
    }

    @Test("A connect to a mirror this central has replaced fails instead of being dropped")
    func connectToAStaleMirrorFails() async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchQueue(label: "LinkCentralTests.staleConnect")
        let link = LinkCentral(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "test",
            retryInterval: .milliseconds(50),
            maximumPeripherals: 1
        )
        defer { link.shutdown(); provider.stop() }
        await waitFor(timeout: .seconds(30)) { link.isProviderConnected }
        #expect(link.isProviderConnected)

        let failures = Mutex<[(peripheral: UUID, error: NSError?)]>([])
        await onQueue(queue) {
            link.eventHandler = { event in
                guard case .didFailToConnect(let peripheral, let error) = event else { return }
                failures.withLock { $0.append((peripheral.uuid, error as NSError?)) }
            }
        }

        let target = UUID()
        let stale = try #require(await onQueue(queue) {
            link.retrievePeripherals(withIdentifiers: [target]).first as? LinkPeripheral
        })
        // The overflow evicted the mirror and the central created it again, so the central files a
        // *different* mirror for `target`. The provider's events would go there, not to `stale`.
        await onQueue(queue) { _ = link.retrievePeripherals(withIdentifiers: [UUID()]) }
        let current = try #require(await onQueue(queue) {
            link.retrievePeripherals(withIdentifiers: [target]).first as? LinkPeripheral
        })
        #expect(current !== stale)

        await onQueue(queue) { link.connect(stale, options: nil, requiresANCS: false) }

        await waitFor(timeout: .seconds(10)) { failures.withLock { !$0.isEmpty } }
        let reported = failures.withLock { $0 }
        #expect(reported.count == 1)
        #expect(reported.first?.peripheral == target)
        #expect(reported.first?.error?.domain == "BLESwiftLink")
        #expect(reported.first?.error?.code == 7)
        // The client refused the connect and did not send it. The provider never saw a connect for
        // the stale handle.
        #expect(Self.connectCount(provider, for: target) == 0)
        #expect(await onQueue(queue) { stale.connectionState } == .disconnected)
    }
}
#endif
