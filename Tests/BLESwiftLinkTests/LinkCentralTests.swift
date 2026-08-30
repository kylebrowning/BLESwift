//
//  LinkCentralTests.swift
//  BLESwiftLinkTests
//

// Sockets in a CI simulator are unreliable — a runner's simulator network can wedge outright,
// leaving a loopback connect stuck in `.connecting` for tens of seconds — so every suite that
// opens one is compiled out there. The simulator-side path is covered by the two-simulator
// E2E, which runs on real simulators.
#if !targetEnvironment(simulator)
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
        // Generous, and asserted: a starved runner can take seconds to hand over a loopback
        // connection, and a rig that gave up early would leave every wait after it racing a
        // central that is not powered on yet.
        await waitFor(timeout: .seconds(30)) { central.state == .poweredOn }
        #expect(central.state == .poweredOn)
        return (central, link, provider)
    }

    /// How many `.connect` requests `provider` has received for `peripheral`.
    ///
    /// The observable a test waits on before emitting a `didConnect`: the client is in
    /// `.connecting` only once its request has actually arrived, and a completion emitted
    /// ahead of that has nowhere to land — the connect then waits out its own bound instead.
    private static func connectCount(_ provider: ScriptedProvider, for peripheral: UUID) -> Int {
        provider.requests.withLock { $0 }.filter { request in
            if case .connect(peripheral, _, _) = request { return true }
            return false
        }.count
    }

    /// Every event whose fields the client validates, made malformed — one per `handle(_:)`
    /// case that names a peripheral *and* carries an identifier of its own.
    ///
    /// The identifier is the same one in each: what matters is that it never reaches the
    /// mirror table, so the test can name it and then prove nothing was filed under it.
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

        // The session is dropped and redialed: the provider is faulty, not merely unlucky.
        await waitFor(timeout: .seconds(30)) { provider.helloCount.withLock { $0 } >= 2 }
        #expect(provider.helloCount.withLock { $0 } >= 2, "\(Self.malformedEvents[index].name)")
        // And the mirror table never heard of the peripheral it named. A mirror minted for an
        // event that then threw is `.disconnected`, so it survives the reconnect, is reported
        // to the caller as a peripheral this central knows, and can evict a real one.
        #expect(await onQueue(queue) { link.peripheralCount } == 0, "\(Self.malformedEvents[index].name)")
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

    @Test("A stale write acknowledgement cannot open the next connection's window")
    func staleWriteAcknowledgementIsIgnored() async throws {
        let (central, link, provider) = try await makeRig()
        defer { provider.stop(); link.shutdown() }
        let queue = link.queue
        let id = UUID()
        let window = LinkFlowControl.writeWithoutResponseWindow

        // Connect, then fill the flow-control window from the mirror itself: `Central` honors
        // the window, so only driving the peripheral directly gets it to the brim.
        //
        // Every wait below gates on something observable — a request the provider recorded, a
        // state the mirror reports — and is bounded widely enough for a badly starved runner.
        // Nothing here waits on elapsed time, and nothing is emitted before the request it
        // answers has arrived.
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

        // The connection resets. Its outstanding writes go with it — but the provider's
        // acknowledgements for them may already be on the wire.
        provider.emit(.didDisconnect(peripheral: id, error: nil))
        await waitFor(timeout: .seconds(30)) { await onQueue(queue) { peripheral.connectionState == .disconnected } }
        #expect(await onQueue(queue) { peripheral.connectionState == .disconnected })

        // A second connection fills the window again, with fresh sequences. The completion
        // waits for the second `connect` to arrive: emitted ahead of it, it would land on a
        // mirror that is not connecting yet and the reconnect would never finish.
        let reconnectTask = Task { try await central.connect(PeripheralIdentifier(uuid: id, name: nil)) }
        await waitFor(timeout: .seconds(30)) { Self.connectCount(provider, for: id) == 2 }
        #expect(Self.connectCount(provider, for: id) == 2)
        provider.emit(.didConnect(peripheral: id, name: nil, maximumWriteWithResponse: 512, maximumWriteWithoutResponse: 20))
        _ = try await bounded(seconds: 30) { try await reconnectTask.value }
        // The disconnect emptied the mirror's discovery cache along with everything else
        // per-connection, so the second connection discovers again.
        await discoverMeasurement(provider, peripheral, for: id, on: queue)
        await Self.fillWindow(peripheral, on: queue, count: window)
        #expect(await onQueue(queue) { !peripheral.canSendWriteWithoutResponse })
        await waitFor(timeout: .seconds(30)) { Self.writeSequences(provider, for: id).count == 2 * window }
        let live = Self.writeSequences(provider, for: id).filter { !stale.contains($0) }
        #expect(live.count == window)

        // Every acknowledgement from the first connection now lands. None of those sequences
        // is outstanding any more, so none of them may credit this connection's window.
        for sequence in stale {
            provider.emit(.writeWithoutResponseAccepted(peripheral: id, sequence: sequence))
        }
        // And one for a sequence that was never sent at all, for good measure.
        provider.emit(.writeWithoutResponseAccepted(peripheral: id, sequence: .max))

        // A barrier: the link is ordered, so an event behind those acknowledgements cannot be
        // observed until every one of them has been handled. The window must still be shut.
        provider.emit(.didUpdateANCSAuthorization(peripheral: id, authorized: true))
        await waitFor(timeout: .seconds(30)) { await onQueue(queue) { peripheral.ancsAuthorized } }
        #expect(await onQueue(queue) { peripheral.ancsAuthorized })
        #expect(await onQueue(queue) { !peripheral.canSendWriteWithoutResponse })

        // An acknowledgement this connection did earn opens it, and nothing else does.
        provider.emit(.writeWithoutResponseAccepted(peripheral: id, sequence: try #require(live.first)))
        await waitFor(timeout: .seconds(30)) { await onQueue(queue) { peripheral.canSendWriteWithoutResponse } }
        #expect(await onQueue(queue) { peripheral.canSendWriteWithoutResponse })
    }

    /// Issues `count` `.withoutResponse` writes straight at `peripheral`, filling the link's
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

        // Nothing was discovered, so nothing is sent — the same silence CoreBluetooth answers
        // a read on a characteristic it has no object for.
        await onQueue(queue) { peripheral.readValue(for: Self.measurement) }

        // A barrier behind it: the link is ordered, so once this request has been recorded the
        // read would have been too, had one been sent.
        await onQueue(queue) { peripheral.readRSSI() }
        await waitFor(timeout: .seconds(30)) { provider.requests.withLock { $0 }.contains(.readRSSI(peripheral: id)) }
        let reads = provider.requests.withLock { $0 }.filter { request in
            if case .readValue = request { return true }
            return false
        }
        #expect(reads.isEmpty)

        // Discovered, the very same read goes out: the guard is the cache, not the request.
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

    /// The descriptor the descriptor-side guards are exercised with — never discovered, so
    /// the mirror cache has no record of it or of the characteristic under it.
    private static let configuration = DescriptorIdentifier(uuid: "2902", characteristic: measurement)

    /// Runs `body` against a connected peripheral whose mirror cache is empty, puts a
    /// `readRSSI` barrier behind it, and returns every request the provider saw.
    ///
    /// The link is ordered, so once the barrier has been recorded, whatever `body` would have
    /// sent has been recorded too — the absence that follows is real, not a race.
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

    /// Puts ``measurement`` in `peripheral`'s mirror cache, the way a real provider would:
    /// a `PeripheralRemote` no-ops a write to a characteristic it has not seen discovered, so
    /// a test that drives one directly has to discover it first.
    ///
    /// The events are emitted unprompted — the mirror is updated from whatever the provider
    /// reports, request or no request — and the wait gates on the cache itself.
    private func discoverMeasurement(
        _ provider: ScriptedProvider,
        _ peripheral: LinkPeripheral,
        for identifier: UUID,
        on queue: DispatchSerialQueue
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

    private static func fillWindow(_ peripheral: LinkPeripheral, on queue: DispatchSerialQueue, count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                for _ in 0..<count {
                    peripheral.writeValue(Data([1]), for: Self.measurement, type: .withoutResponse)
                }
                continuation.resume()
            }
        }
    }

    /// The sequences of every `.withoutResponse` write `provider` has received for
    /// `peripheral`, in the order they arrived.
    private static func writeSequences(_ provider: ScriptedProvider, for peripheral: UUID) -> [UInt64] {
        provider.requests.withLock { $0 }.compactMap { request in
            guard case .writeValue(peripheral, _, _, .withoutResponse, let sequence) = request else { return nil }
            return sequence
        }
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

    @Test("The peripheral mirror cap evicts the least recently sighted disconnected mirror")
    func peripheralCapEvictsTheOldestMirror() async throws {
        let queue = DispatchSerialQueue(label: "LinkCentralTests.evict")
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
            // One over the cap, and the older mirror is disconnected, so it is the one to go.
            _ = link.retrievePeripherals(withIdentifiers: [newest])
            return link.retrievePeripherals(withIdentifiers: [oldest]).first as? LinkPeripheral === first
        }
        #expect(survived == false)
    }

    @Test("An evicted mirror is detached from its event handler before it is forgotten")
    func peripheralCapDetachesTheMirrorItEvicts() async throws {
        let queue = DispatchSerialQueue(label: "LinkCentralTests.evictDetach")
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
            // What `Central` installs on a mirror it is holding.
            first.eventHandler = { _ in }
            // One over the cap: the older, disconnected mirror is the one to go — and its
            // owner may well still be holding it.
            _ = link.retrievePeripherals(withIdentifiers: [newest])
            return first.eventHandler == nil
        }
        #expect(detached)
    }

    @Test("A table full of busy mirrors cannot make the cap evict the mirror it is minting")
    func peripheralCapNeverEvictsTheMirrorItJustCreated() async throws {
        let queue = DispatchSerialQueue(label: "LinkCentralTests.reserve")
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
            // The one slot the cap allows, occupied by a connect in flight — a mirror the cap
            // is never allowed to drop.
            if let held = link.retrievePeripherals(withIdentifiers: [busy]).first as? LinkPeripheral {
                link.connect(held, options: nil, requiresANCS: false)
            }
            // Retrieving a second identifier overflows a table with nothing evictable in it.
            // The mirror minted here must still be the one filed under `fresh`, or its owner
            // holds an object the provider's events can never reach.
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
        let queue = DispatchSerialQueue(label: "LinkCentralTests.evictedConnect")
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
        // Overflows the cap of one, evicting `held` between the retrieval and the connect —
        // the window a caller holding a perfectly valid peripheral cannot see.
        await onQueue(queue) { _ = link.retrievePeripherals(withIdentifiers: [UUID()]) }

        await onQueue(queue) { link.connect(held, options: nil, requiresANCS: false) }

        await waitFor(timeout: .seconds(10)) { Self.connectCount(provider, for: target) == 1 }
        #expect(Self.connectCount(provider, for: target) == 1)
        // Re-filed under its identifier, so the provider's events for it reach the very
        // object the caller is holding.
        #expect(await onQueue(queue) { link.retrievePeripherals(withIdentifiers: [target]).first as? LinkPeripheral === held })
        #expect(await onQueue(queue) { held.connectionState } == .connecting)
    }

    @Test("A connect to a mirror this central has replaced fails instead of being dropped")
    func connectToAStaleMirrorFails() async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "LinkCentralTests.staleConnect")
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
        // Evicted by the overflow, then re-minted: the central now files a *different* mirror
        // for `target`, and the provider's events for it would go there, not to `stale`.
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
        // Refused, not sent: the provider never saw a connect for the stale handle.
        #expect(Self.connectCount(provider, for: target) == 0)
        #expect(await onQueue(queue) { stale.connectionState } == .disconnected)
    }
}
#endif
