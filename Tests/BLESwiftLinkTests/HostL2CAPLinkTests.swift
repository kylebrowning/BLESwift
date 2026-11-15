//
//  HostL2CAPLinkTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
@testable import BLESwiftSimulatorLink
@testable import BLESwiftTestSupport
@testable import BLESwiftVirtualRadio
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// A copyable box around a `Mutex`, so a test helper can return it in a tuple and take it as a
/// parameter. A `Mutex` is noncopyable.
private final class Log<Value: Sendable>: Sendable {
    private let box: Mutex<Value>

    init(_ value: Value) { box = Mutex(value) }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        box.withLock { body(&$0) }
    }
}

/// Peripheral-role L2CAP over the link. A ``LinkPeripheralManager`` drives a `PeripheralHost`
/// that publishes a channel, and a ``LinkCentral`` drives a `Central` that opens it. Both dial
/// one ``Provider``. Raw clients send what no honest client sends. The composite tests publish
/// over a real child and a virtual child together.
@Suite("Peripheral-role L2CAP over the link")
struct HostL2CAPLinkTests {

    // MARK: - Rigs

    /// A provider that listens on a system-assigned loopback port.
    private func makeProvider(handshakeTimeout: Duration? = nil) async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        if let handshakeTimeout { configuration.handshakeTimeout = handshakeTimeout }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    /// A linked host that published one channel and advertises as `name`, and a linked central
    /// that is connected to it.
    private struct Rig {
        let provider: Provider
        let host: PeripheralHost
        let hostLink: LinkPeripheralManager
        let central: Central
        let centralLink: LinkCentral
        let peripheral: Peripheral
        let psm: L2CAPPSM
        let incoming: AsyncStream<IncomingL2CAPChannel>
    }

    private func makeRig(_ name: String) async throws -> Rig {
        let provider = try await makeProvider()
        let port = await provider.port

        let hostQueue = DispatchQueue(label: "host.l2cap.\(name).host")
        let hostLink = LinkPeripheralManager(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: hostQueue,
            clientName: name,
            retryInterval: .milliseconds(50)
        )
        let host = PeripheralHost(backend: hostLink, queue: hostQueue)
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }
        let incoming = await host.incomingL2CAPChannels()
        let psm = try await host.publishL2CAPChannel()
        try await host.startAdvertising(PeripheralAdvertisement(localName: name, serviceUUIDs: []))

        let centralQueue = DispatchQueue(label: "host.l2cap.\(name).central")
        let centralLink = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: port),
            queue: centralQueue,
            clientName: "\(name)-central",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: centralLink, queue: centralQueue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: nil, timeout: .seconds(5)) {
            if case .discovered(let discovery) = event, discovery.advertisement.localName == name {
                found = discovery
                break
            }
        }
        let peripheral = try await central.connect(try #require(found).peripheral)
        return Rig(
            provider: provider,
            host: host,
            hostLink: hostLink,
            central: central,
            centralLink: centralLink,
            peripheral: peripheral,
            psm: psm,
            incoming: incoming
        )
    }

    private func tearDown(_ rig: Rig) async {
        rig.centralLink.shutdown()
        rig.hostLink.shutdown()
        await rig.provider.stop()
    }

    /// Opens a channel from the central and returns both ends.
    private func open(_ rig: Rig) async throws -> (L2CAPChannel, IncomingL2CAPChannel) {
        let channel = try await rig.peripheral.openL2CAPChannel(psm: rig.psm, timeout: .seconds(5))
        let incoming = rig.incoming
        let accepted = try await bounded {
            var iterator = incoming.makeAsyncIterator()
            return await iterator.next()
        }
        return (channel, try #require(accepted))
    }

    /// Reads `stream` until it has `count` bytes.
    private static func read(_ count: Int, from stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var bytes = Data()
        for try await chunk in stream {
            bytes.append(chunk)
            if bytes.count >= count { break }
        }
        return bytes
    }

    // MARK: - End to end

    @Test("A linked host and a linked central echo 1 MiB both ways, and the central's close finishes the host cleanly", .timeLimit(.minutes(1)))
    func echoAndCentralClose() async throws {
        let rig = try await makeRig("echo")
        #expect(rig.psm == L2CAPPSM(0x0080))
        let (channel, accepted) = try await open(rig)
        #expect(accepted.psm == rig.psm)

        // The host echoes every chunk back. Its loop ends when the central closes.
        let echo = Task {
            for try await chunk in accepted.incomingData {
                try await accepted.write(chunk)
            }
            return true
        }

        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let centralInbound = channel.incomingData
        let reader = Task { try await Self.read(payload.count, from: centralInbound) }
        try await bounded { try await channel.write(payload) }
        let echoed = try await bounded { try await reader.value }
        #expect(echoed == payload)

        await channel.close()
        #expect(try await bounded { try await echo.value })
        await tearDown(rig)
    }

    @Test("A host close finishes the central's stream cleanly", .timeLimit(.minutes(1)))
    func hostClose() async throws {
        let rig = try await makeRig("hostclose")
        let (channel, accepted) = try await open(rig)

        try await accepted.write(Data([7, 8]))
        let inbound = channel.incomingData
        let reader = Task { () -> (Data, Bool) in
            var bytes = Data()
            for try await chunk in inbound { bytes.append(chunk) }
            return (bytes, true)
        }
        try await Task.sleep(for: .milliseconds(50))
        accepted.close()

        let (bytes, finished) = try await bounded { try await reader.value }
        #expect(bytes == Data([7, 8]))
        #expect(finished)
        await tearDown(rig)
    }

    @Test("A dropped host link closes the central's channel with an error", .timeLimit(.minutes(1)))
    func hostLinkDropFailsTheCentral() async throws {
        let rig = try await makeRig("hostdrop")
        let (channel, accepted) = try await open(rig)
        let inbound = channel.incomingData
        let reader = Task { () -> Error? in
            do {
                for try await _ in inbound {}
                return nil
            } catch {
                return error
            }
        }
        let hostInbound = accepted.incomingData
        let hostReader = Task { () -> Error? in
            do {
                for try await _ in hostInbound {}
                return nil
            } catch {
                return error
            }
        }

        rig.hostLink.dropLinkForTesting()

        // The provider closes the host's end with `LinkError.providerDisconnected`. The central's
        // end is the peer of that close, so it throws the closed-channel error.
        let error = try await bounded { await reader.value }
        let central = try #require(error as NSError?)
        let closed = BLESwiftError.l2capChannelClosed as NSError
        #expect(central.domain == closed.domain)
        #expect(central.code == closed.code)
        // The host's own end closes with the link error.
        let hostError = try await bounded { await hostReader.value }
        let disconnected = LinkError.providerDisconnected.nsError
        #expect((hostError as NSError?)?.domain == disconnected.domain)
        #expect((hostError as NSError?)?.code == disconnected.code)
        await tearDown(rig)
    }

    // MARK: - Version

    @Test("The provider refuses a client of protocol version 1")
    func versionOneIsRefused() async throws {
        #expect(LinkProtocol.version == 2)
        let provider = try await makeProvider()
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "host.l2cap.version")
        )
        let answer = Mutex<ServerHello?>(nil)
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(protocolVersion: 1, role: .peripheral, clientName: "old")))
        }
        connection.onMessage = { message in
            guard case .serverHello(let hello) = message else { return }
            answer.withLock { $0 = hello }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { answer.withLock { $0 } != nil }

        // The client receives the refusal, and its reason names both versions.
        let refusal = try #require(answer.withLock { $0 })
        #expect(refusal.accepted == false)
        #expect(refusal.protocolVersion == 2)
        #expect(refusal.reason == "protocol version 1 is not 2")
        #expect(await provider.sessionCount == 0)
        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    // MARK: - Hostile frames

    /// A raw peripheral-role client. It shows every host event, so a test can send what no honest
    /// `LinkPeripheralManager` sends.
    private final class RawHost: Sendable {
        let connection: LinkConnection
        private let received = Mutex<[HostWireEvent]>([])

        var events: [HostWireEvent] { received.withLock { $0 } }

        init(port: UInt16, label: String) {
            connection = LinkConnection.connect(
                to: LinkEndpoint(host: "127.0.0.1", port: port),
                codec: .binaryPropertyList,
                queue: DispatchQueue(label: label)
            )
            connection.onStateChange = { [weak connection] state in
                guard case .ready = state else { return }
                connection?.send(.clientHello(ClientHello(
                    protocolVersion: LinkProtocol.version,
                    role: .peripheral,
                    clientName: label
                )))
            }
            connection.onMessage = { [self] message in
                guard case .hostEvent(let event) = message else { return }
                received.withLock { $0.append(event) }
            }
            connection.start()
        }

        func send(_ request: HostRequest) { connection.send(.hostRequest(request)) }

        func shutdown() {
            connection.onStateChange = nil
            connection.onMessage = nil
            connection.cancel()
        }
    }

    /// A raw host that published a channel, and a central on the provider's own radio that opened
    /// it. The raw host's channel id is 1.
    private func makeHostileRig(_ label: String) async throws -> (Provider, RawHost, L2CAPChannel, (Central, Peripheral)) {
        let provider = try await makeProvider()
        let raw = RawHost(port: await provider.port, label: label)
        await waitFor(timeout: .seconds(5)) { raw.events.contains(.didUpdateState(.poweredOn)) }
        raw.send(.publishL2CAPChannel(requiresEncryption: false))
        raw.send(.startAdvertising(localName: label, services: []))
        await waitFor(timeout: .seconds(5)) { raw.events.contains(.didStartAdvertising(error: nil)) }
        #expect(raw.events.contains(.didPublishL2CAPChannel(psm: 0x0080, error: nil)))

        let queue = DispatchQueue(label: "\(label).central")
        let central = Central(backend: VirtualCentralBackend(radio: provider.radio, queue: queue), queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: nil, timeout: .seconds(5)) {
            if case .discovered(let discovery) = event, discovery.advertisement.localName == label {
                found = discovery
                break
            }
        }
        let peripheral = try await central.connect(try #require(found).peripheral)
        let channel = try await peripheral.openL2CAPChannel(psm: L2CAPPSM(0x0080), timeout: .seconds(5))
        await waitFor(timeout: .seconds(5)) {
            raw.events.contains { if case .didOpenL2CAPChannel(1, 0x0080, _) = $0 { return true } else { return false } }
        }
        return (provider, raw, channel, (central, peripheral))
    }

    @Test("A host frame for an unknown channel id is ignored, and the session stays", .timeLimit(.minutes(1)))
    func unknownChannelIsIgnored() async throws {
        let (provider, raw, channel, _) = try await makeHostileRig("hostile-unknown")
        raw.send(.l2capData(channel: 99, data: Data([1])))
        raw.send(.l2capCredit(channel: 99, bytes: 1))
        raw.send(.l2capClose(channel: 99))

        // The real channel still carries data, so the session is alive.
        raw.send(.l2capData(channel: 1, data: Data([4, 2])))
        let inbound = channel.incomingData
        let first = try await bounded { () -> Data? in
            for try await chunk in inbound { return chunk }
            return nil
        }
        #expect(first == Data([4, 2]))
        #expect(await provider.sessionCount == 1)

        raw.shutdown()
        await provider.stop()
    }

    @Test("A bad host credit closes the channel with code 7", .timeLimit(.minutes(1)))
    func badCreditClosesTheChannel() async throws {
        let (provider, raw, channel, _) = try await makeHostileRig("hostile-credit")
        raw.send(.l2capCredit(channel: 1, bytes: -1))

        await waitFor(timeout: .seconds(5)) {
            raw.events.contains { if case .l2capClosed(1, let error) = $0 { return error?.code == 7 } else { return false } }
        }
        #expect(raw.events.contains { if case .l2capClosed(1, let error) = $0 { return error?.code == 7 } else { return false } })
        // The central's end finishes cleanly, because the provider closed the host's end.
        let inbound = channel.incomingData
        let finished = try await bounded { () -> Bool in
            for try await _ in inbound {}
            return true
        }
        #expect(finished)
        #expect(await provider.sessionCount == 1)

        raw.shutdown()
        await provider.stop()
    }

    @Test("An oversized host frame loses the client its session", .timeLimit(.minutes(1)))
    func oversizedFrameDropsTheSession() async throws {
        let (provider, raw, _, _) = try await makeHostileRig("hostile-frame")
        raw.send(.l2capData(channel: 1, data: Data(repeating: 0x5A, count: L2CAPChannelRelay.maximumChunk + 1)))

        await waitFor(timeout: .seconds(10)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)

        raw.shutdown()
        await provider.stop()
    }

    // MARK: - Composite

    /// A host over a composite of a real fake child and a virtual child, on one queue.
    private func makeCompositeHost(
        _ label: String,
        realState: CentralState
    ) async -> (PeripheralHost, FakePeripheralManager, VirtualPeripheralManagerBackend, VirtualRadio) {
        let radio = VirtualRadio()
        let queue = DispatchQueue(label: label)
        let real = FakePeripheralManager(queue: queue, state: realState)
        let virtual = VirtualPeripheralManagerBackend(radio: radio, queue: queue)
        let composite = CompositePeripheralManager(backends: [real, virtual], queue: queue)
        let host = PeripheralHost(backend: composite, queue: queue)
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }
        await waitFor(timeout: .seconds(5)) { await radio.generation(of: virtual.identifier) != nil }
        return (host, real, virtual, radio)
    }

    @Test("A composite publishes the real child's PSM on the virtual child too")
    func compositePublishesOnePSM() async throws {
        let (host, real, virtual, radio) = await makeCompositeHost("composite.l2cap.same", realState: .poweredOn)
        await real.onQueue { real.publishBehavior = .succeed(L2CAPPSM(0x0085)) }

        let psm = try await host.publishL2CAPChannel()

        #expect(psm == L2CAPPSM(0x0085))
        #expect(await real.onQueue { real.publishL2CAPChannelCalls } == [false])
        #expect(await radio.publishedL2CAP[virtual.identifier] == [L2CAPPSM(0x0085)])

        try await host.unpublishL2CAPChannel(psm)
        #expect(await real.onQueue { real.unpublishL2CAPChannelCalls } == [psm])
        #expect(await radio.publishedL2CAP[virtual.identifier] == nil)
    }

    /// Answers the `count`-th held publish call of `real` with `psm`.
    private func answerPublish(_ real: FakePeripheralManager, call count: Int, psm: UInt16) async {
        await waitFor(timeout: .seconds(5)) { await real.onQueue { real.publishL2CAPChannelCalls.count >= count } }
        real.simulatePublishResult(psm: L2CAPPSM(psm), error: nil)
    }

    @Test("A conflict on the virtual child makes the real child give another PSM, and the conflicting PSM is unpublished")
    func compositeConflictRetries() async throws {
        let (host, real, virtual, radio) = await makeCompositeHost("composite.l2cap.retry", realState: .poweredOn)
        await real.onQueue { real.publishBehavior = .hold }
        let generation = try #require(await radio.generation(of: virtual.identifier))
        _ = await radio.publishL2CAP(device: virtual.identifier, generation: generation, psm: L2CAPPSM(0x0080))

        let publish = Task { try await host.publishL2CAPChannel() }
        await answerPublish(real, call: 1, psm: 0x0080)
        await answerPublish(real, call: 2, psm: 0x0081)

        #expect(try await bounded { try await publish.value } == L2CAPPSM(0x0081))
        #expect(await real.onQueue { real.publishL2CAPChannelCalls.count } == 2)
        await waitFor(timeout: .seconds(5)) { await real.onQueue { !real.unpublishL2CAPChannelCalls.isEmpty } }
        #expect(await real.onQueue { real.unpublishL2CAPChannelCalls } == [L2CAPPSM(0x0080)])
        #expect(await radio.publishedL2CAP[virtual.identifier] == [L2CAPPSM(0x0080), L2CAPPSM(0x0081)])
    }

    @Test("Four conflicts fail the publish with code 13 and unpublish every PSM on the real child")
    func compositeFourConflictsFail() async throws {
        let (host, real, virtual, radio) = await makeCompositeHost("composite.l2cap.conflict", realState: .poweredOn)
        await real.onQueue { real.publishBehavior = .hold }
        let generation = try #require(await radio.generation(of: virtual.identifier))
        let taken: [UInt16] = [0x0080, 0x0081, 0x0082, 0x0083]
        for psm in taken {
            _ = await radio.publishL2CAP(device: virtual.identifier, generation: generation, psm: L2CAPPSM(psm))
        }

        let publish = Task { try await host.publishL2CAPChannel() }
        for (call, psm) in taken.enumerated() {
            await answerPublish(real, call: call + 1, psm: psm)
        }

        do {
            _ = try await bounded { try await publish.value }
            Issue.record("expected the publish to fail")
        } catch {
            #expect((error as NSError).domain == "BLESwiftProvider")
            #expect((error as NSError).code == 13)
        }
        #expect(await real.onQueue { real.publishL2CAPChannelCalls.count } == 4)
        await waitFor(timeout: .seconds(5)) { await real.onQueue { real.unpublishL2CAPChannelCalls.count == 4 } }
        #expect(Set(await real.onQueue { real.unpublishL2CAPChannelCalls }) == Set(taken.map(L2CAPPSM.init)))
    }

    @Test("With the real child off, the composite publishes on the virtual child alone")
    func compositeVirtualOnly() async throws {
        let (host, real, virtual, radio) = await makeCompositeHost("composite.l2cap.virtual", realState: .poweredOff)

        let psm = try await host.publishL2CAPChannel()

        #expect(psm == L2CAPPSM(0x0080))
        #expect(await real.onQueue { real.publishL2CAPChannelCalls }.isEmpty)
        #expect(await radio.publishedL2CAP[virtual.identifier] == [L2CAPPSM(0x0080)])
    }

    @Test("A real child that powers off during a publish fails the publish, and the next publish uses the virtual child")
    func compositePowerDownDuringPublish() async throws {
        let (host, real, virtual, radio) = await makeCompositeHost("composite.l2cap.powerdown", realState: .poweredOn)
        await real.onQueue { real.publishBehavior = .hold }

        let publish = Task { try await host.publishL2CAPChannel() }
        await waitFor(timeout: .seconds(5)) { await real.onQueue { real.publishL2CAPChannelCalls.count == 1 } }
        real.simulateStateChange(.poweredOff)

        do {
            _ = try await bounded { try await publish.value }
            Issue.record("expected the publish to fail")
        } catch {
            let expected = BLESwiftError.l2capPublishFailed as NSError
            #expect((error as NSError).domain == expected.domain)
            #expect((error as NSError).code == expected.code)
        }
        #expect(try await host.publishL2CAPChannel() == L2CAPPSM(0x0080))
        #expect(await radio.publishedL2CAP[virtual.identifier] == [L2CAPPSM(0x0080)])
    }

    /// A composite of a real fake child and a virtual child that a test drives directly. The
    /// returned log records every event that the composite emits.
    private func makeComposite(_ label: String) async -> (CompositePeripheralManager, FakePeripheralManager, VirtualPeripheralManagerBackend, VirtualRadio, Log<[PeripheralHostEvent]>, DispatchQueue) {
        let radio = VirtualRadio()
        let queue = DispatchQueue(label: label)
        let real = FakePeripheralManager(queue: queue, state: .poweredOn)
        let virtual = VirtualPeripheralManagerBackend(radio: radio, queue: queue)
        let composite = CompositePeripheralManager(backends: [real, virtual], queue: queue)
        let log = Log<[PeripheralHostEvent]>([])
        await Self.onQueue(queue) {
            composite.eventHandler = { event in
                switch event {
                case .didPublishL2CAPChannel, .didUnpublishL2CAPChannel: log.withLock { $0.append(event) }
                default: break
                }
            }
        }
        await waitFor(timeout: .seconds(5)) { await radio.generation(of: virtual.identifier) != nil }
        return (composite, real, virtual, radio, log, queue)
    }

    private static func onQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// The publish completions in `log`, as PSM values. A failed publish is `nil`.
    private static func publishes(_ log: Log<[PeripheralHostEvent]>) -> [UInt16?] {
        log.withLock { events in
            events.compactMap {
                guard case .didPublishL2CAPChannel(let psm, _) = $0 else { return nil }
                return .some(psm?.rawValue)
            }
        }
    }

    /// The unpublish completions in `log`, as error codes. A success is `nil`.
    private static func unpublishes(_ log: Log<[PeripheralHostEvent]>) -> [Int?] {
        log.withLock { events in
            events.compactMap {
                guard case .didUnpublishL2CAPChannel(_, let error) = $0 else { return nil }
                return .some(error?.code)
            }
        }
    }

    /// A real child for the composite that a test drives by hand. Its radio state changes with
    /// no state event, and it answers a publish only when the test calls ``answer(psm:)``.
    private final class HeldRealChild: L2CAPPublishing, Sendable {
        let queue: DispatchQueue
        nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
        nonisolated(unsafe) var state: CentralState = .poweredOn
        nonisolated(unsafe) private(set) var publishCalls = 0

        init(queue: DispatchQueue) { self.queue = queue }

        var eventHandler: ((PeripheralHostEvent) -> Void)? {
            get { dispatchPrecondition(condition: .onQueue(queue)); return _eventHandler }
            set { dispatchPrecondition(condition: .onQueue(queue)); _eventHandler = newValue }
        }
        var radioState: CentralState { dispatchPrecondition(condition: .onQueue(queue)); return state }
        var isAdvertising: Bool { false }
        static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }
        func startAdvertising(_ advertisement: PeripheralAdvertisement) {}
        func stopAdvertising() {}
        func add(_ service: GATTService) {}
        func removeAllHostedServices() {}
        func respond(to token: RequestToken, value: Data?, error: ATTError?) {}
        func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool { true }
        func publishL2CAPChannel(requiresEncryption: Bool) {
            dispatchPrecondition(condition: .onQueue(queue))
            publishCalls += 1
        }
        func unpublishL2CAPChannel(_ psm: L2CAPPSM) {}

        /// Delivers a successful publish answer on ``queue``.
        func answer(psm: L2CAPPSM) {
            queue.async { [self] in _eventHandler?(.didPublishL2CAPChannel(psm: psm, error: nil)) }
        }
    }

    @Test("A publish that settles first waits for the earlier publish before it completes")
    func compositePublishesInOrder() async throws {
        let radio = VirtualRadio()
        let queue = DispatchQueue(label: "composite.l2cap.order")
        let real = HeldRealChild(queue: queue)
        let virtual = VirtualPeripheralManagerBackend(radio: radio, queue: queue)
        let composite = CompositePeripheralManager(backends: [real, virtual], queue: queue)
        let log = Log<[PeripheralHostEvent]>([])
        await Self.onQueue(queue) {
            composite.eventHandler = { event in
                if case .didPublishL2CAPChannel = event { log.withLock { $0.append(event) } }
            }
        }
        await waitFor(timeout: .seconds(5)) { await radio.generation(of: virtual.identifier) != nil }

        // Batch 1 waits on the real child. Then the real child goes off with no state event, so
        // the virtual child leads batch 2 and settles it first.
        await Self.onQueue(queue) {
            composite.publishL2CAPChannel(requiresEncryption: false)
            real.state = .poweredOff
            composite.publishL2CAPChannel(requiresEncryption: false)
        }
        await waitFor(timeout: .seconds(5)) { await radio.publishedL2CAP[virtual.identifier] == [L2CAPPSM(0x0080)] }
        #expect(await radio.publishedL2CAP[virtual.identifier] == [L2CAPPSM(0x0080)])
        try? await Task.sleep(for: .milliseconds(50))
        await Self.onQueue(queue) {}
        // Batch 2 has settled, but its completion waits for batch 1.
        #expect(Self.publishes(log).isEmpty)

        // The real child comes back with no state event and answers batch 1.
        await Self.onQueue(queue) { real.state = .poweredOn }
        real.answer(psm: L2CAPPSM(0x0090))

        await waitFor(timeout: .seconds(5)) { Self.publishes(log).count == 2 }
        #expect(Self.publishes(log) == [0x0090, 0x0080])
        #expect(await Self.onQueue(queue) { real.publishCalls } == 1)
    }

    @Test("A child answer that matches no call is dropped, and a stale publish is unpublished on that child")
    func compositeDropsStaleAnswers() async throws {
        // Keep the composite: its children hold it weakly.
        let (composite, real, _, _, log, queue) = await makeComposite("composite.l2cap.stale")
        defer { withExtendedLifetime(composite) {} }
        real.simulatePublishResult(psm: L2CAPPSM(0x0090), error: nil)
        await waitFor(timeout: .seconds(5)) { await real.onQueue { !real.unpublishL2CAPChannelCalls.isEmpty } }
        #expect(await real.onQueue { real.unpublishL2CAPChannelCalls } == [L2CAPPSM(0x0090)])
        // The fake answers that unpublish too. The composite swallows the answer as a rollback.
        try? await Task.sleep(for: .milliseconds(50))
        await Self.onQueue(queue) {}
        #expect(log.withLock { $0 }.isEmpty)
    }

    @Test("An unpublish over two holders reaches both and completes once")
    func compositeUnpublishesEveryHolder() async throws {
        let (composite, real, virtual, radio, log, queue) = await makeComposite("composite.l2cap.holders")
        await real.onQueue { real.publishBehavior = .succeed(L2CAPPSM(0x0085)) }
        await Self.onQueue(queue) { composite.publishL2CAPChannel(requiresEncryption: false) }
        await waitFor(timeout: .seconds(5)) { Self.publishes(log).count == 1 }
        #expect(await radio.publishedL2CAP[virtual.identifier] == [L2CAPPSM(0x0085)])

        await Self.onQueue(queue) { composite.unpublishL2CAPChannel(L2CAPPSM(0x0085)) }
        await waitFor(timeout: .seconds(5)) { Self.unpublishes(log).count == 1 }
        // Give a second completion every chance to arrive. There must be none. This is a
        // negative assertion, so a short wait is the only bound.
        try? await Task.sleep(for: .milliseconds(100))
        await Self.onQueue(queue) {}

        #expect(Self.unpublishes(log) == [nil])
        #expect(await real.onQueue { real.unpublishL2CAPChannelCalls } == [L2CAPPSM(0x0085)])
        #expect(await radio.publishedL2CAP[virtual.identifier] == nil)
    }

    @Test("A child that fails an unpublish still holds the PSM, so a second unpublish reaches it")
    func compositeFailedUnpublishKeepsTheHolder() async throws {
        let (composite, real, virtual, radio, log, queue) = await makeComposite("composite.l2cap.failedunpublish")
        await real.onQueue { real.publishBehavior = .succeed(L2CAPPSM(0x0085)) }
        await Self.onQueue(queue) { composite.publishL2CAPChannel(requiresEncryption: false) }
        await waitFor(timeout: .seconds(5)) { Self.publishes(log).count == 1 }
        // Take the PSM off the virtual device behind the composite's back, so the virtual child's
        // unpublish fails with code 12.
        let generation = try #require(await radio.generation(of: virtual.identifier))
        #expect(await radio.unpublishL2CAP(device: virtual.identifier, generation: generation, psm: L2CAPPSM(0x0085)) == .unpublished)

        await Self.onQueue(queue) { composite.unpublishL2CAPChannel(L2CAPPSM(0x0085)) }
        await waitFor(timeout: .seconds(5)) { Self.unpublishes(log).count == 1 }
        #expect(Self.unpublishes(log) == [12])

        // The real child succeeded, so only the virtual child still holds the PSM.
        await Self.onQueue(queue) { composite.unpublishL2CAPChannel(L2CAPPSM(0x0085)) }
        await waitFor(timeout: .seconds(5)) { Self.unpublishes(log).count == 2 }
        #expect(Self.unpublishes(log) == [12, 12])
        #expect(await real.onQueue { real.unpublishL2CAPChannelCalls } == [L2CAPPSM(0x0085)])
    }

    // MARK: - Handshake deadline

    @Test("A refused client that stays connected is closed by the handshake deadline")
    func refusedClientIsClosedByTheDeadline() async throws {
        let provider = try await makeProvider(handshakeTimeout: .milliseconds(200))
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "host.l2cap.deadline")
        )
        let answer = Mutex<ServerHello?>(nil)
        let ended = Mutex(false)
        connection.onStateChange = { [weak connection] state in
            switch state {
            case .ready:
                connection?.send(.clientHello(ClientHello(protocolVersion: 1, role: .peripheral, clientName: "stays")))
            case .failed, .cancelled:
                ended.withLock { $0 = true }
            default:
                break
            }
        }
        // The client reads the refusal and does not close the connection. It records whether the
        // connection was still open when the refusal arrived.
        let openAtRefusal = Mutex<Bool?>(nil)
        connection.onMessage = { message in
            guard case .serverHello(let hello) = message else { return }
            answer.withLock { $0 = hello }
            openAtRefusal.withLock { $0 = !ended.withLock { $0 } }
        }
        let start = ContinuousClock.now
        connection.start()

        await waitFor(timeout: .seconds(5)) { answer.withLock { $0 } != nil }
        #expect(answer.withLock { $0?.accepted } == false)
        #expect(openAtRefusal.withLock { $0 } == true)
        // The refusal does not close the connection. Only the deadline does.
        if ContinuousClock.now - start < .milliseconds(150) {
            #expect(!ended.withLock { $0 })
        }

        await waitFor(timeout: .seconds(5)) { ended.withLock { $0 } }
        #expect(ended.withLock { $0 })
        #expect(ContinuousClock.now - start >= .milliseconds(200))
        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    // MARK: - Credit cap

    @Test("Repeated full credit grants close a host-side channel with code 7", .timeLimit(.minutes(1)))
    func hostFullCreditGrantsCloseTheChannel() async throws {
        let (provider, raw, _, _) = try await makeHostileRig("hostile-fullcredit")
        raw.send(.l2capCredit(channel: 1, bytes: LinkFlowControl.l2capInitialCredit))
        raw.send(.l2capCredit(channel: 1, bytes: LinkFlowControl.l2capInitialCredit))

        await waitFor(timeout: .seconds(5)) {
            raw.events.contains { if case .l2capClosed(1, let error) = $0 { return error?.code == 7 } else { return false } }
        }
        #expect(raw.events.contains { if case .l2capClosed(1, let error) = $0 { return error?.code == 7 } else { return false } })
        #expect(await provider.sessionCount == 1)
        raw.shutdown()
        await provider.stop()
    }

    /// A handler that accepts every channel and keeps it, so the channel stays open.
    private actor KeepingHandler: VirtualL2CAPAccepting {
        private var kept: [any L2CAPChannelRemote] = []
        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> { .failure(.readNotPermitted) }
        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> { .success(()) }
        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
        func acceptL2CAPChannel(_ channel: any L2CAPChannelRemote, psm: L2CAPPSM, from central: Subscriber) async {
            kept.append(channel)
        }
    }

    @Test("Repeated full credit grants close a central-side channel with code 7", .timeLimit(.minutes(1)))
    func centralFullCreditGrantsCloseTheChannel() async throws {
        let provider = try await makeProvider()
        let device = UUID()
        let handle = await provider.radio.register(VirtualDevice(
            descriptor: VirtualDeviceDescriptor(identifier: device, advertisement: AdvertisementData(isConnectable: true)),
            handler: KeepingHandler()
        ))
        _ = try await handle.publishL2CAPChannel(psm: L2CAPPSM(0x0080))

        let received = Mutex<[CentralWireEvent]>([])
        let connection = LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "host.l2cap.centralcredit")
        )
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(protocolVersion: LinkProtocol.version, role: .central, clientName: "credit")))
        }
        connection.onMessage = { message in
            guard case .centralEvent(let event) = message else { return }
            received.withLock { $0.append(event) }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { received.withLock { $0.contains(.didUpdateState(.poweredOn)) } }
        connection.send(.centralRequest(.connect(peripheral: device, options: nil, requiresANCS: false)))
        await waitFor(timeout: .seconds(5)) {
            received.withLock { $0.contains { if case .didConnect(device, _, _, _) = $0 { return true } else { return false } } }
        }
        connection.send(.centralRequest(.openL2CAPChannel(peripheral: device, psm: 0x0080, channel: 1)))
        await waitFor(timeout: .seconds(5)) {
            received.withLock { $0.contains(.didOpenL2CAPChannel(peripheral: device, channel: 1, psm: 0x0080, error: nil)) }
        }
        #expect(received.withLock { $0.contains(.didOpenL2CAPChannel(peripheral: device, channel: 1, psm: 0x0080, error: nil)) })

        connection.send(.centralRequest(.l2capCredit(channel: 1, bytes: LinkFlowControl.l2capInitialCredit)))
        connection.send(.centralRequest(.l2capCredit(channel: 1, bytes: LinkFlowControl.l2capInitialCredit)))
        await waitFor(timeout: .seconds(5)) {
            received.withLock { $0.contains { if case .l2capClosed(1, let error) = $0 { return error?.code == 7 } else { return false } } }
        }
        #expect(received.withLock { $0.contains { if case .l2capClosed(1, let error) = $0 { return error?.code == 7 } else { return false } } })

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        await provider.stop()
    }

    // MARK: - Channel limit

    @Test("A host session closes a channel that opens past the limit of 64", .timeLimit(.minutes(2)))
    func hostChannelLimit() async throws {
        let (provider, raw, first, (central, peripheral)) = try await makeHostileRig("hostile-limit")
        var channels: [L2CAPChannel] = [first]
        for _ in 1..<HostSession.maximumHostChannels {
            channels.append(try await peripheral.openL2CAPChannel(psm: L2CAPPSM(0x0080), timeout: .seconds(5)))
        }
        let opens = { raw.events.filter { if case .didOpenL2CAPChannel = $0 { return true } else { return false } }.count }
        await waitFor(timeout: .seconds(10)) { opens() == HostSession.maximumHostChannels }
        #expect(opens() == HostSession.maximumHostChannels)

        // One more. The session closes it at once and does not tell the client.
        let extra = try await peripheral.openL2CAPChannel(psm: L2CAPPSM(0x0080), timeout: .seconds(5))
        let inbound = extra.incomingData
        let finished = try await bounded { () -> Bool in
            for try await _ in inbound {}
            return true
        }
        #expect(finished)
        #expect(opens() == HostSession.maximumHostChannels)
        withExtendedLifetime(channels) {}
        withExtendedLifetime(central) {}

        raw.shutdown()
        await provider.stop()
    }

    // MARK: - LinkPeripheralManager refusals

    /// A link manager over a scripted provider. The log records every radio state and every
    /// channel that the manager delivers.
    private func makeScriptedLink(_ label: String) async throws -> (ScriptedHostProvider, LinkPeripheralManager, DispatchQueue, Log<[CentralState]>, Log<[any L2CAPChannelRemote]>) {
        let provider = try ScriptedHostProvider()
        try await provider.start()
        let queue = DispatchQueue(label: label)
        let link = LinkPeripheralManager(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: label,
            codec: .json,
            retryInterval: .milliseconds(50)
        )
        let states = Log<[CentralState]>([])
        let channels = Log<[any L2CAPChannelRemote]>([])
        await Self.onQueue(queue) {
            link.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .didOpenL2CAPChannel(let channel?, _, _): channels.withLock { $0.append(channel) }
                default: break
                }
            }
        }
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.contains(.poweredOn) } }
        return (provider, link, queue, states, channels)
    }

    /// Whether the link dropped after it first powered on.
    private static func dropped(_ states: Log<[CentralState]>) -> Bool {
        states.withLock { states in
            guard let on = states.firstIndex(of: .poweredOn) else { return false }
            return states[on...].contains(.unsupported)
        }
    }

    @Test("LinkPeripheralManager drops the session for an L2CAP event with PSM 0")
    func linkRefusesPSMZero() async throws {
        let (provider, link, _, states, _) = try await makeScriptedLink("link.l2cap.psmzero")
        defer { provider.stop() }
        provider.emit(.didOpenL2CAPChannel(channel: 1, psm: 0, central: UUID()))
        await waitFor(timeout: .seconds(5)) { Self.dropped(states) }
        #expect(Self.dropped(states))
        withExtendedLifetime(link) {}
    }

    @Test("LinkPeripheralManager drops the session for a duplicate channel id, and closes the first channel")
    func linkRefusesDuplicateChannel() async throws {
        let (provider, link, queue, states, channels) = try await makeScriptedLink("link.l2cap.duplicate")
        defer { provider.stop() }
        provider.emit(.didOpenL2CAPChannel(channel: 1, psm: 0x0080, central: UUID()))
        await waitFor(timeout: .seconds(5)) { channels.withLock { $0.count } == 1 }
        let first = try #require(channels.withLock { $0.first })
        let inbound = first.inbound()

        provider.emit(.didOpenL2CAPChannel(channel: 1, psm: 0x0080, central: UUID()))
        await waitFor(timeout: .seconds(5)) { Self.dropped(states) }
        #expect(Self.dropped(states))
        #expect(channels.withLock { $0.count } == 1)
        let failure = try await bounded { () -> Int? in
            do {
                for try await _ in inbound {}
                return nil
            } catch {
                return (error as NSError).code
            }
        }
        #expect(failure == LinkError.providerDisconnected.code)
        #expect(await Self.onQueue(queue) { link.channelCount } == 0)
    }

    @Test("LinkPeripheralManager ignores frames for an unknown channel id")
    func linkIgnoresUnknownChannel() async throws {
        let (provider, link, queue, states, _) = try await makeScriptedLink("link.l2cap.unknown")
        defer { provider.stop() }
        provider.emit(.l2capData(channel: 9, data: Data([1])))
        provider.emit(.l2capCredit(channel: 9, bytes: 1))
        provider.emit(.l2capClosed(channel: 9, error: nil))
        // A publish answer behind the frames shows that the manager handled them.
        let published = Mutex(false)
        await Self.onQueue(queue) {
            let previous = link.eventHandler
            link.eventHandler = { event in
                if case .didPublishL2CAPChannel = event { published.withLock { $0 = true } }
                previous?(event)
            }
        }
        provider.emit(.didPublishL2CAPChannel(psm: 0x0080, error: nil))
        await waitFor(timeout: .seconds(5)) { published.withLock { $0 } }
        #expect(published.withLock { $0 })
        #expect(!Self.dropped(states))
        #expect(await Self.onQueue(queue) { link.channelCount } == 0)
    }
}
#endif
