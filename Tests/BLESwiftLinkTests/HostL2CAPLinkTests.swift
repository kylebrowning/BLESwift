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

/// Peripheral-role L2CAP over the link. A ``LinkPeripheralManager`` drives a `PeripheralHost`
/// that publishes a channel, and a ``LinkCentral`` drives a `Central` that opens it. Both dial
/// one ``Provider``. Raw clients send what no honest client sends. The composite tests publish
/// over a real child and a virtual child together.
@Suite("Peripheral-role L2CAP over the link")
struct HostL2CAPLinkTests {

    // MARK: - Rigs

    /// A provider that listens on a system-assigned loopback port.
    private func makeProvider() async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
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

        let error = try await bounded { await reader.value }
        #expect(error != nil)
        // The host's own end closes with the link error.
        let hostError = try await bounded { await hostReader.value }
        #expect((hostError as NSError?)?.domain == LinkError.domain)
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
        await waitFor(timeout: .seconds(2)) { answer.withLock { $0 } != nil }

        // The provider sends a refusal and cancels the connection at once, so the refusal does
        // not always reach the client. Either way, the client is never accepted and no session
        // opens.
        #expect(answer.withLock { $0?.accepted } != true)
        if let refusal = answer.withLock({ $0 }) {
            #expect(refusal.protocolVersion == 2)
        }
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
    private func makeHostileRig(_ label: String) async throws -> (Provider, RawHost, L2CAPChannel, Central) {
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
        return (provider, raw, channel, central)
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
        // The central's end finishes, because the provider closed the host's end.
        let inbound = channel.incomingData
        _ = try? await bounded { for try await _ in inbound {} }
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

    @Test("A conflict on the virtual child rolls back the real child's publish")
    func compositeConflictRollsBack() async throws {
        let (host, real, virtual, radio) = await makeCompositeHost("composite.l2cap.conflict", realState: .poweredOn)
        await real.onQueue { real.publishBehavior = .succeed(L2CAPPSM(0x0085)) }
        let generation = try #require(await radio.generation(of: virtual.identifier))
        _ = await radio.publishL2CAP(device: virtual.identifier, generation: generation, psm: L2CAPPSM(0x0085))

        do {
            _ = try await host.publishL2CAPChannel()
            Issue.record("expected the publish to fail")
        } catch {
            #expect((error as NSError).domain == "BLESwiftProvider")
            #expect((error as NSError).code == 13)
        }
        await waitFor(timeout: .seconds(5)) { await real.onQueue { !real.unpublishL2CAPChannelCalls.isEmpty } }
        #expect(await real.onQueue { real.unpublishL2CAPChannelCalls } == [L2CAPPSM(0x0085)])
    }

    @Test("With the real child off, the composite publishes on the virtual child alone")
    func compositeVirtualOnly() async throws {
        let (host, real, virtual, radio) = await makeCompositeHost("composite.l2cap.virtual", realState: .poweredOff)

        let psm = try await host.publishL2CAPChannel()

        #expect(psm == L2CAPPSM(0x0080))
        #expect(await real.onQueue { real.publishL2CAPChannelCalls }.isEmpty)
        #expect(await radio.publishedL2CAP[virtual.identifier] == [L2CAPPSM(0x0080)])
    }
}
#endif
