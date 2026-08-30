//
//  L2CAPLinkTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
@testable import BLESwiftSimulatorLink
import BLESwiftTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

/// The client half of an L2CAP channel driven over a real link against a provider whose
/// central backend is a ``BLESwiftTestSupport/FakeCentral`` — so every byte, credit, and
/// close in these tests crosses a socket and is bridged by `LinkL2CAPChannel` on one side
/// and `CentralSession`'s pump on the other.
@Suite("L2CAP over the link")
struct L2CAPLinkTests {

    private static let psm = L2CAPPSM(0x0041)
    private static let deviceID = UUID(uuidString: "1D8E4A2C-0F1B-4C2D-9A7E-5B6C7D8E9F01")!

    /// Everything one test rig holds: the client's `Central` and link, the provider, and the
    /// `FakePeripheral` the provider's session is serving.
    private struct Rig {
        let central: Central
        let link: LinkCentral
        let provider: Provider
        let fake: FakePeripheral
    }

    /// A `Sendable` hand-off for the `FakePeripheral` the backend factory builds on the
    /// session's queue — `Mutex` is non-copyable, so it cannot live in ``Rig`` itself.
    private final class PeripheralBox: Sendable {
        private let storage = Mutex<FakePeripheral?>(nil)

        var peripheral: FakePeripheral? { storage.withLock { $0 } }

        func store(_ peripheral: FakePeripheral) { storage.withLock { $0 = peripheral } }
    }

    /// A `Sendable` hand-off for the `FakeCentral` the backend factory builds on the
    /// session's queue, so a test can drive its scripting after the session exists.
    private final class CentralBox: Sendable {
        private let storage = Mutex<FakeCentral?>(nil)

        var central: FakeCentral? { storage.withLock { $0 } }

        func store(_ central: FakeCentral) { storage.withLock { $0 = central } }
    }

    /// A provider whose passthrough central backend is a `FakeCentral` serving one
    /// `FakePeripheral`, plus a `Central` linked to it and already connected to that
    /// peripheral.
    ///
    /// The virtual radio hosts no fixtures here, so it vends no remote for the fake's
    /// identifier and the composite resolves it to the fake — the reason
    /// `VirtualCentralBackend` must answer only for devices it knows.
    private func makeRig(label: String) async throws -> (Rig, Peripheral) {
        let fakeBox = PeripheralBox()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            // Called on the session's own queue, so the fake's queue-confined scripting
            // setters may be driven inline.
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: "Fake L2CAP", queue: queue)
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            fakeBox.store(peripheral)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchSerialQueue(label: label)
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "l2cap",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        #expect(central.state == .poweredOn)

        let peripheral = try await central.connect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fake L2CAP"))
        let fake = try #require(fakeBox.peripheral)
        return (Rig(central: central, link: link, provider: provider, fake: fake), peripheral)
    }

    /// Tears a rig down: the link first, then the provider once its session has gone.
    private func tearDown(_ rig: Rig) async {
        rig.link.shutdown()
        await waitFor(timeout: .seconds(5)) { await rig.provider.sessionCount == 0 }
        await rig.provider.stop()
    }

    /// The `FakeL2CAPChannel` the provider's `FakePeripheral` vended for the open, once it
    /// exists.
    private func openedChannel(_ rig: Rig) async throws -> FakeL2CAPChannel {
        let fake = rig.fake
        await waitFor { await fake.onQueue { fake.lastOpenedL2CAPChannel != nil } }
        return try #require(await fake.onQueue { fake.lastOpenedL2CAPChannel })
    }

    // MARK: - Channel identity

    /// A raw central-role client: every frame in and out, so a test can send what no honest
    /// `LinkCentral` would — two opens naming the same channel id.
    private final class RawClient: Sendable {
        let connection: LinkConnection
        private let received = Mutex<[CentralWireEvent]>([])
        private let hello = Mutex<Bool>(false)

        /// Every central event the provider has sent so far, in order.
        var events: [CentralWireEvent] { received.withLock { $0 } }

        /// Whether the provider has accepted this client's hello.
        var isAccepted: Bool { hello.withLock { $0 } }

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
                    role: .central,
                    clientName: "raw-l2cap"
                )))
            }
            // Strongly captured, and released by ``shutdown()``: a `Mutex` is non-copyable,
            // so the two boxes cannot be captured by value.
            connection.onMessage = { [self] message in
                switch message {
                case .serverHello(let answer) where answer.accepted: hello.withLock { $0 = true }
                case .centralEvent(let event): received.withLock { $0.append(event) }
                default: break
                }
            }
            connection.start()
        }

        func send(_ request: CentralRequest) { connection.send(.centralRequest(request)) }

        func shutdown() {
            connection.onStateChange = nil
            connection.onMessage = nil
            connection.cancel()
        }
    }

    /// A provider serving one `FakePeripheral` over `FakeCentral`, with no client attached —
    /// the rig the raw-client tests below drive by hand.
    private func makeProvider(_ box: PeripheralBox) async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: "Fake L2CAP", queue: queue)
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            box.store(peripheral)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are unreliable; the simulator-side path is covered by the
    // two-simulator E2E on real simulators.

    @Test("A second open naming a live channel id is refused, and the live channel survives")
    func aDuplicateChannelIdentifierIsRefused() async throws {
        let box = PeripheralBox()
        let provider = try await makeProvider(box)
        let client = RawClient(port: await provider.port, label: "l2cap.duplicate")
        await waitFor(timeout: .seconds(5)) { client.isAccepted }
        client.send(.connect(peripheral: Self.deviceID, options: nil, requiresANCS: false))
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didConnect = $0 { return true } else { return false } }
        }

        // The first open takes channel id 7.
        client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: Self.psm.rawValue, channel: 7))
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didOpenL2CAPChannel = $0 { return true } else { return false } }
        }
        #expect(client.events.contains(.didOpenL2CAPChannel(
            peripheral: Self.deviceID, channel: 7, psm: Self.psm.rawValue, error: nil
        )))
        let fake = try #require(box.peripheral)
        let first = try #require(await fake.onQueue { fake.lastOpenedL2CAPChannel })

        // A second open naming the same id — which no honest client sends, and which used to
        // orphan the bridge above with its pump, transport and credit window still live.
        client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: Self.psm.rawValue, channel: 7))
        await waitFor(timeout: .seconds(5)) {
            client.events.filter { if case .didOpenL2CAPChannel = $0 { return true } else { return false } }.count == 2
        }
        // `true` for an open that was refused. (Mapped to `Bool` rather than the optional
        // error: `compactMap` would swallow the successful open's `nil`.)
        let refusals = client.events.compactMap { event -> Bool? in
            guard case .didOpenL2CAPChannel(_, let channel, _, let error) = event, channel == 7 else { return nil }
            return error != nil
        }
        #expect(refusals == [false, true], "the first open takes the id and the duplicate is refused")
        // The channel the second open produced was closed rather than bridged, and it is not
        // the one still serving id 7.
        let second = try #require(await fake.onQueue { fake.lastOpenedL2CAPChannel })
        #expect(second !== first)
        await waitFor(timeout: .seconds(5)) { await second.onQueue { second.isClosed } }

        // The live channel is untouched: no `l2capClosed` for it, and it still carries data.
        #expect(!client.events.contains { if case .l2capClosed = $0 { return true } else { return false } })
        first.simulateInbound(Data([0xA1, 0xB2]))
        await waitFor(timeout: .seconds(5)) {
            client.events.contains(.l2capData(channel: 7, data: Data([0xA1, 0xB2])))
        }
        #expect(await first.onQueue { !first.isClosed })

        client.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    /// Runs `body` on `session`'s own serial queue and returns its result — the sanctioned
    /// way for a test to touch session state, which is queue-confined rather than locked.
    private func onSessionQueue<T: Sendable>(
        _ session: CentralSession,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            session.queue.async { continuation.resume(returning: body()) }
        }
    }

    /// The one central-role session `provider` is serving.
    private func centralSession(of provider: Provider) async throws -> CentralSession {
        try #require(await provider.liveSessions.compactMap { $0 as? CentralSession }.first)
    }

    @Test("A channel-open completion from a connection that has ended is not paired with the next open")
    func aStaleOpenCompletionIsNotPairedWithTheNextConnectionsOpen() async throws {
        let stalePSM = UInt16(0x0041)
        let livePSM = UInt16(0x0043)
        let box = PeripheralBox()
        let centralBox = CentralBox()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: "Fake L2CAP", queue: queue)
            // Every open is held, so this test decides when — and in which connection's
            // lifetime — each completion lands.
            peripheral.l2capOpenBehavior = .hold
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            box.store(peripheral)
            centralBox.store(fake)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let client = RawClient(port: await provider.port, label: "l2cap.staleopen")
        await waitFor(timeout: .seconds(5)) { client.isAccepted }

        /// Waits for the `didConnect` after the `connect` this sends.
        func connect() async {
            let before = client.events.filter {
                if case .didConnect = $0 { return true } else { return false }
            }.count
            client.send(.connect(peripheral: Self.deviceID, options: nil, requiresANCS: false))
            await waitFor(timeout: .seconds(5)) {
                client.events.filter {
                    if case .didConnect = $0 { return true } else { return false }
                }.count > before
            }
        }

        await connect()
        let fake = try #require(box.peripheral)
        // Issued on the first connection and never completed on it.
        client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: stalePSM, channel: 1))
        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.openL2CAPChannelCalls.count } == 1 }

        // The connection ends underneath it, and the client reconnects and opens again —
        // taking a fresh channel id, as a client that saw the disconnect does.
        let backend = try #require(centralBox.central)
        backend.simulateDisconnect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fake L2CAP"), error: nil)
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didDisconnect = $0 { return true } else { return false } }
        }
        await connect()
        client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: livePSM, channel: 2))
        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.openL2CAPChannelCalls.count } == 2 }

        // The *first* connection's completion lands now. It answers nothing: channel id 2
        // belongs to an open the live connection issued, and bridging it here would hand the
        // client the previous connection's transport.
        fake.simulateNextHeldL2CAPOpenCompletion()
        let firstChannel = try #require(await fake.onQueue { fake.lastOpenedL2CAPChannel })
        await waitFor(timeout: .seconds(5)) { await firstChannel.onQueue { firstChannel.isClosed } }
        #expect(await firstChannel.onQueue { firstChannel.isClosed }, "a stranded completion's channel is closed, not leaked")
        #expect(!client.events.contains { if case .didOpenL2CAPChannel = $0 { return true } else { return false } })

        // The live connection's own completion is what answers channel id 2 — and it carries
        // the PSM that open asked for, not the dead connection's.
        fake.simulateNextHeldL2CAPOpenCompletion()
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didOpenL2CAPChannel = $0 { return true } else { return false } }
        }
        #expect(client.events.contains(.didOpenL2CAPChannel(
            peripheral: Self.deviceID, channel: 2, psm: livePSM, error: nil
        )))

        client.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A completion the backend never delivers stops being owed, and the next open is answered")
    func anUnhonoredStrandedOpenExpiresRatherThanEatingTheNextCompletion() async throws {
        let stalePSM = UInt16(0x0041)
        let livePSM = UInt16(0x0043)
        let box = PeripheralBox()
        let centralBox = CentralBox()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        // Short enough to sit out in a test: the real deadline is ten seconds.
        configuration.strandedOpenLifetimePerCentralSession = .milliseconds(100)
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: "Fake L2CAP", queue: queue)
            peripheral.l2capOpenBehavior = .hold
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            box.store(peripheral)
            centralBox.store(fake)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let client = RawClient(port: await provider.port, label: "l2cap.expiredopen")
        await waitFor(timeout: .seconds(5)) { client.isAccepted }

        func connect() async {
            let before = client.events.filter {
                if case .didConnect = $0 { return true } else { return false }
            }.count
            client.send(.connect(peripheral: Self.deviceID, options: nil, requiresANCS: false))
            await waitFor(timeout: .seconds(5)) {
                client.events.filter {
                    if case .didConnect = $0 { return true } else { return false }
                }.count > before
            }
        }

        await connect()
        let fake = try #require(box.peripheral)
        // Issued on the first connection, and never completed on it or on any other — a
        // backend is not obliged to call back for a channel whose connection went away.
        client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: stalePSM, channel: 1))
        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.openL2CAPChannelCalls.count } == 1 }

        let backend = try #require(centralBox.central)
        backend.simulateDisconnect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fake L2CAP"), error: nil)
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didDisconnect = $0 { return true } else { return false } }
        }
        await connect()
        client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: livePSM, channel: 2))
        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.openL2CAPChannelCalls.count } == 2 }

        // Past the deadline, the debt is no longer owed — so the live connection's own
        // completion answers the client's open rather than being eaten by it. Left standing,
        // this client's `openL2CAPChannel` never returns.
        try await Task.sleep(for: .milliseconds(200))
        fake.simulateLastHeldL2CAPOpenCompletion()
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didOpenL2CAPChannel = $0 { return true } else { return false } }
        }
        #expect(client.events.contains(.didOpenL2CAPChannel(
            peripheral: Self.deviceID, channel: 2, psm: livePSM, error: nil
        )))

        client.send(.l2capClose(channel: 2))
        client.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A remote owed only an expired completion is evictable again")
    func aRemoteWithOnlyExpiredStrandedDebtIsEvicted() async throws {
        let stranded = UUID()
        let arriving = UUID()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        // A table of one, so the second connect must evict the first remote or keep it.
        configuration.maximumRemotesPerCentralSession = 1
        configuration.strandedOpenLifetimePerCentralSession = .milliseconds(100)
        let centralBox = CentralBox()
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            for identifier in [stranded, arriving] {
                let peripheral = FakePeripheral(identifier: identifier, name: "Fake", queue: queue)
                peripheral.l2capOpenBehavior = .hold
                fake.retrievablePeripherals[identifier] = peripheral
            }
            // Held: every remote stays `.disconnected`, which is what the cap evicts.
            fake.connectBehavior = .hang
            centralBox.store(fake)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let client = RawClient(port: await provider.port, label: "l2cap.evictexpired")
        await waitFor(timeout: .seconds(5)) { client.isAccepted }

        // A remote left owed one completion its connection never got.
        client.send(.connect(peripheral: stranded, options: nil, requiresANCS: false))
        client.send(.openL2CAPChannel(peripheral: stranded, psm: Self.psm.rawValue, channel: 1))
        let session = try await centralSession(of: provider)
        await waitFor(timeout: .seconds(5)) {
            await onSessionQueue(session) { !(session.pendingOpens[stranded] ?? []).isEmpty }
        }
        let backend = try #require(centralBox.central)
        backend.simulateDisconnect(PeripheralIdentifier(uuid: stranded, name: "Fake"), error: nil)
        await waitFor(timeout: .seconds(5)) {
            await onSessionQueue(session) { !(session.strandedOpens[stranded] ?? []).isEmpty }
        }

        // Past the deadline it pins nothing, so the arriving connect may have its slot.
        try await Task.sleep(for: .milliseconds(200))
        client.send(.connect(peripheral: arriving, options: nil, requiresANCS: false))
        await waitFor(timeout: .seconds(5)) {
            await onSessionQueue(session) { session.strandedOpens[stranded] == nil }
        }

        // Evicted: an open for a peripheral this session no longer has a remote for is
        // answered as unknown rather than held by the backend.
        client.send(.openL2CAPChannel(peripheral: stranded, psm: Self.psm.rawValue, channel: 3))
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didOpenL2CAPChannel = $0 { return true } else { return false } }
        }
        let answered = client.events.compactMap { event -> Bool? in
            guard case .didOpenL2CAPChannel(_, let channel, _, let error) = event, channel == 3 else { return nil }
            return error != nil
        }
        #expect(answered == [true], "the evicted remote's open is refused, not held")

        client.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A pump send from a bridge whose channel id was reused is dropped")
    func aStalePumpSendUnderAReusedIdentifierIsDropped() async throws {
        let box = PeripheralBox()
        let provider = try await makeProvider(box)
        let client = RawClient(port: await provider.port, label: "l2cap.stalepump")
        await waitFor(timeout: .seconds(5)) { client.isAccepted }
        client.send(.connect(peripheral: Self.deviceID, options: nil, requiresANCS: false))
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didConnect = $0 { return true } else { return false } }
        }

        /// Opens channel id 7 and waits for its completion.
        func open() async {
            let before = client.events.filter {
                if case .didOpenL2CAPChannel = $0 { return true } else { return false }
            }.count
            client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: Self.psm.rawValue, channel: 7))
            await waitFor(timeout: .seconds(5)) {
                client.events.filter {
                    if case .didOpenL2CAPChannel = $0 { return true } else { return false }
                }.count > before
            }
        }

        await open()
        let session = try await centralSession(of: provider)
        let stale = try #require(await onSessionQueue(session) { session.channels[7] })

        // The id goes back to the client and is handed straight to another channel — the
        // state the pump's hop can land in, having cleared its cancellation check just before
        // the teardown that dropped its bridge.
        client.send(.l2capClose(channel: 7))
        await open()
        let live = try #require(await onSessionQueue(session) { session.channels[7] })
        #expect(live !== stale)

        // The dead bridge's bytes must not reach the client under an id that is now another
        // channel's.
        let staleBytes = Data([0xDE, 0xAD])
        await onSessionQueue(session) {
            session.sendFromPump(.l2capData(channel: 7, data: staleBytes), channel: 7, open: stale)
        }
        // Bounded by the live bridge's own send: the queue is serial and the connection
        // writes in order, so a frame that arrives after this one was never sent at all.
        let liveBytes = Data([0xC0, 0xFF, 0xEE])
        await onSessionQueue(session) {
            session.sendFromPump(.l2capData(channel: 7, data: liveBytes), channel: 7, open: live)
        }
        await waitFor(timeout: .seconds(5)) {
            client.events.contains(.l2capData(channel: 7, data: liveBytes))
        }
        #expect(client.events.contains(.l2capData(channel: 7, data: liveBytes)))
        #expect(!client.events.contains(.l2capData(channel: 7, data: staleBytes)))

        client.send(.l2capClose(channel: 7))
        client.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }

    @Test("A stale write failure under a reused channel id leaves the live channel alone")
    func aStaleWriteFailureDoesNotTearDownAReusedIdentifier() async throws {
        let box = PeripheralBox()
        let provider = try await makeProvider(box)
        let client = RawClient(port: await provider.port, label: "l2cap.reuse")
        await waitFor(timeout: .seconds(5)) { client.isAccepted }
        client.send(.connect(peripheral: Self.deviceID, options: nil, requiresANCS: false))
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didConnect = $0 { return true } else { return false } }
        }
        let fake = try #require(box.peripheral)

        /// Opens channel id 7 and returns the transport the provider bridged it to.
        func open() async throws -> FakeL2CAPChannel {
            let before = client.events.filter {
                if case .didOpenL2CAPChannel = $0 { return true } else { return false }
            }.count
            client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: Self.psm.rawValue, channel: 7))
            await waitFor(timeout: .seconds(5)) {
                client.events.filter {
                    if case .didOpenL2CAPChannel = $0 { return true } else { return false }
                }.count > before
            }
            return try #require(await fake.onQueue { fake.lastOpenedL2CAPChannel })
        }

        // Each round: park writes on the channel behind id 7, close it — which fails every
        // parked write against the transport closing under it — and reuse the id at once. The
        // failures those writes report name channel 7, which by then is another channel's.
        for _ in 0..<2 {
            let stale = try await open()
            await stale.onQueue { stale.writeBehavior = .hold }
            for _ in 0..<8 {
                client.send(.l2capData(channel: 7, data: Data([0x01, 0x02, 0x03, 0x04])))
            }
            await waitFor(timeout: .seconds(5)) { await stale.onQueue { !stale.writtenData.isEmpty } }
            client.send(.l2capClose(channel: 7))
            let live = try await open()

            // The live channel is never the stale one, is never closed by the stale channel's
            // unwinding writes, and still carries data both ways.
            #expect(live !== stale)
            live.simulateInbound(Data([0xC3]))
            await waitFor(timeout: .seconds(5)) {
                client.events.contains(.l2capData(channel: 7, data: Data([0xC3])))
            }
            client.send(.l2capData(channel: 7, data: Data([0xD4])))
            await waitFor(timeout: .seconds(5)) { await live.onQueue { live.writtenData.contains(Data([0xD4])) } }
            #expect(await live.onQueue { !live.isClosed })
            #expect(!client.events.contains { if case .l2capClosed = $0 { return true } else { return false } })
            client.send(.l2capClose(channel: 7))
            await waitFor(timeout: .seconds(5)) { await live.onQueue { live.isClosed } }
        }

        client.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
    }
#endif

    // MARK: - Teardown

    @Test("A writer suspended for credit is resumed when its LinkCentral is deallocated")
    func deallocatingTheCentralResumesSuspendedWriters() async throws {
        let queue = DispatchSerialQueue(label: "l2cap.dealloc")
        // Dialing a port nothing is listening on: this central never connects, so no credit
        // can ever arrive from a provider and the only thing that can resume a parked writer
        // is the central's own teardown.
        var link: LinkCentral? = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: try closedPort()),
            queue: queue,
            clientName: "dealloc",
            retryInterval: .seconds(60)
        )
        weak let deallocated = link
        // Captured by value into the hop and released with it, so `link` stays the only
        // strong reference this test holds.
        let channel: LinkL2CAPChannel = await withCheckedContinuation { continuation in
            queue.async { [link] in
                continuation.resume(returning: link!.registerChannel(1, psm: Self.psm, peripheral: Self.deviceID))
            }
        }

        // The whole window in one write, so the next byte has nothing left to spend.
        try await bounded { try await channel.write(Data(repeating: 0x5A, count: LinkFlowControl.l2capInitialCredit)) }
        let parked = Task { try await channel.write(Data([0x01])) }
        await waitFor(timeout: .seconds(5)) { channel.suspendedWriterCount == 1 }
        #expect(channel.suspendedWriterCount == 1)

        // Drained before the release, and this is the whole of the test's synchronization:
        // every chunk that window-filling write put on the link handed the central a block of
        // its own — the send closure a channel is built with hops onto the central's queue
        // holding a *strong* reference to it — so the central cannot deallocate while any of
        // them is still pending. Under load they can still be queued at the moment the last
        // test-held reference goes, which is a queue that has not drained yet rather than a
        // reference this test forgot. One hop onto the serial queue flushes everything
        // enqueued before it.
        _ = await Self.onQueue(queue) { true }

        // Released, not shut down: `deinit` is the whole point — a central that simply goes
        // out of scope must not leave its writers parked forever.
        link = nil
        // The gate is the deallocation itself, observed rather than assumed to have happened
        // by the time the next statement runs: `deinit` is dropped by whichever thread holds
        // the last reference, which need not be this one.
        await waitFor(timeout: .seconds(5)) { deallocated == nil }
        #expect(deallocated == nil)

        do {
            try await bounded { try await parked.value }
            Issue.record("expected the parked write to fail")
        } catch let error as LinkL2CAPError {
            #expect(error == .closed)
        }
    }

    /// Hops onto `queue` to run `body` and returns its result — the door for off-queue test
    /// code to touch queue-confined state.
    private static func onQueue<T: Sendable>(_ queue: DispatchSerialQueue, _ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: - Throughput

    @Test("A megabyte written client-to-provider arrives byte for byte, in order")
    func outboundThroughput() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.outbound")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        #expect(channel.psm == Self.psm)
        let fake = try await openedChannel(rig)

        // 4 KiB chunks, each byte derived from its absolute offset, so a reorder or a
        // dropped chunk is visible in the comparison rather than only in the length.
        let chunkSize = 4 * 1024
        let chunkCount = 256
        var expected = Data(capacity: chunkSize * chunkCount)
        for index in 0..<chunkCount {
            let chunk = Data((0..<chunkSize).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0) })
            expected.append(chunk)
            try await channel.write(chunk)
        }
        #expect(expected.count == 1024 * 1024)

        await waitFor(timeout: .seconds(30)) {
            await fake.onQueue { fake.writtenData.reduce(0) { $0 + $1.count } } == expected.count
        }
        let received = await fake.onQueue { fake.writtenData.reduce(into: Data()) { $0.append($1) } }
        #expect(received.count == expected.count)
        #expect(received == expected)

        await tearDown(rig)
    }

    @Test("Eight concurrent writers overflow the credit window without losing a block")
    func concurrentWritersShareTheCreditWindow() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.concurrent")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)

        // 8 × 64 KiB is 512 KiB against a 256 KiB window, so at least half the writers must
        // suspend for credit. `L2CAPChannel` is a `Sendable` struct that reaches the transport
        // directly, so these really do arrive concurrently — each needs its own continuation.
        let blockSize = 64 * 1024
        let blockCount = 8
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<blockCount {
                group.addTask {
                    try await channel.write(Data(repeating: UInt8(index + 1), count: blockSize))
                }
            }
            try await group.waitForAll()
        }

        let expected = blockSize * blockCount
        await waitFor(timeout: .seconds(30)) {
            await fake.onQueue { fake.writtenData.reduce(0) { $0 + $1.count } } == expected
        }
        let combined = await fake.onQueue { fake.writtenData.reduce(into: Data()) { $0.append($1) } }
        #expect(combined.count == expected)

        // Blocks may land in any order, but each must survive as one contiguous run of its own
        // fill byte — a run-length pass finds exactly eight runs, one per writer.
        var runs: [(byte: UInt8, length: Int)] = []
        for byte in combined {
            if runs.last?.byte == byte {
                runs[runs.count - 1].length += 1
            } else {
                runs.append((byte: byte, length: 1))
            }
        }
        #expect(runs.count == blockCount)
        #expect(Set(runs.map(\.byte)) == Set((1...blockCount).map { UInt8($0) }))
        #expect(runs.allSatisfy { $0.length == blockSize })

        await tearDown(rig)
    }

    @Test("600 KiB pushed inbound reaches the client's stream, cycling credit")
    func inboundThroughput() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.inbound")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)

        // 600 KiB in 16 KiB pieces — the last one ragged, as a real transport's reads are.
        let pieceSize = 16 * 1024
        let expected = Data((0..<(600 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ ($0 >> 8)) })
        #expect(expected.count == 600 * 1024)
        var offset = 0
        while offset < expected.count {
            let end = min(offset + pieceSize, expected.count)
            fake.simulateInbound(expected[offset..<end])
            offset = end
        }

        // 600 KiB is more than twice the 262 144-byte initial credit, so the client must
        // grant credit back at least twice for this to complete at all.
        let collector = Task { () -> Data in
            var accumulated = Data()
            for try await piece in channel.incomingData {
                accumulated.append(piece)
                if accumulated.count >= expected.count { break }
            }
            return accumulated
        }
        let collected = try await bounded { try await collector.value }
        #expect(collected == expected)

        await tearDown(rig)
    }

    // MARK: - Close

    @Test("An empty write is a no-op that leaves the channel usable")
    func emptyWriteIsANoOp() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.emptyWrite")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)

        // A zero-length payload used to reach the wire, come back as a credit of `0`, and
        // cost the channel: the client refuses a non-positive credit as a violation.
        try await channel.write(Data())
        #expect(await fake.onQueue { fake.writtenData.isEmpty })

        // The channel is still open in both directions, and a real write still lands.
        try await channel.write(Data([1, 2, 3]))
        await waitFor(timeout: .seconds(5)) {
            await fake.onQueue { fake.writtenData.reduce(0) { $0 + $1.count } } == 3
        }
        #expect(await fake.onQueue { fake.writtenData.reduce(into: Data()) { $0.append($1) } } == Data([1, 2, 3]))
        #expect(await fake.onQueue { !fake.isClosed })

        let inbound = Task { () -> Data? in
            for try await piece in channel.incomingData { return piece }
            return nil
        }
        fake.simulateInbound(Data([9]))
        #expect(try await bounded { try await inbound.value } == Data([9]))

        await tearDown(rig)
    }

    @Test("Closing from the client closes the provider's channel")
    func clientCloseReachesProvider() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.clientClose")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)

        let finished = Task { () -> Error? in
            do {
                for try await _ in channel.incomingData {}
                return nil
            } catch {
                return error
            }
        }
        await channel.close()

        #expect(try await bounded { await finished.value } == nil)
        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.isClosed } }
        #expect(await fake.onQueue { fake.isClosed })

        await tearDown(rig)
    }

    @Test("A clean close on the provider finishes the client's stream without throwing")
    func providerCloseFinishesStream() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.providerClose")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)

        let finished = Task { () -> Error? in
            do {
                for try await _ in channel.incomingData {}
                return nil
            } catch {
                return error
            }
        }
        fake.close(error: nil)

        #expect(try await bounded { await finished.value } == nil)
        await tearDown(rig)
    }

    @Test("A failing close on the provider throws from the client's stream")
    func providerCloseWithErrorThrows() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.providerCloseError")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)

        let finished = Task { () -> Error? in
            do {
                for try await _ in channel.incomingData {}
                return nil
            } catch {
                return error
            }
        }
        fake.close(error: NSError(domain: "L2CAPLinkTests", code: 7))

        let error = try #require(try await bounded { await finished.value }) as NSError
        #expect(error.domain == "L2CAPLinkTests")
        #expect(error.code == 7)

        await tearDown(rig)
    }

    @Test("Closing with writes still in flight tears the bridge down cleanly")
    func closeWithWritesInFlight() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.closeMidWrite")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)

        // A burst deep enough that the provider still has writes chained behind the one it is
        // performing when the close arrives — the chain `tearDown` has to cancel along with
        // the pump, or it outlives the transport it was writing to.
        let payload = Data(repeating: 0x7E, count: 4096)
        let writer = Task {
            for _ in 0..<32 { try await channel.write(payload) }
        }
        await channel.close()
        // The writer either finished or was refused by the closed channel; neither hangs.
        _ = try? await bounded { try await writer.value }

        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.isClosed } }
        #expect(await fake.onQueue { fake.isClosed })
        // Every byte the fake did take arrived whole — a cancelled chain truncates the stream,
        // it never corrupts it.
        let written = await fake.onQueue { fake.writtenData }
        #expect(written.allSatisfy { $0 == payload })

        await tearDown(rig)
    }

    // MARK: - Inbound credit

    @Test("Bytes arriving after the channel closed are dropped, and dropped bytes earn no credit")
    func closedChannelCreditsNothing() async throws {
        // The client half on its own: the provider's frames are what `LinkCentral` would feed
        // it, and `sent` is the link it would put its own requests on.
        let sent = Mutex<[CentralRequest]>([])
        let channel = LinkL2CAPChannel(channel: 7, psm: Self.psm) { request in
            sent.withLock { $0.append(request) }
        }

        // Open: bytes land, and the provider is credited for them at once.
        try channel.receive(Data([1, 2, 3]))
        #expect(sent.withLock { $0.count } == 1)
        if case .l2capCredit(let identifier, let bytes) = sent.withLock({ $0[0] }) {
            #expect(identifier == 7)
            #expect(bytes == 3)
        } else {
            Issue.record("expected an l2capCredit, got \(sent.withLock { $0 })")
        }

        // Closed by the provider, then a frame that was already in flight arrives. It is
        // dropped — so crediting it would hand the provider back a window on a channel that
        // will never read another byte.
        channel.remoteClosed(error: nil)
        sent.withLock { $0.removeAll() }
        try channel.receive(Data([4, 5, 6, 7]))
        #expect(sent.withLock { $0 }.isEmpty)
    }

    @Test("An empty inbound frame earns no credit and leaves the channel open")
    func emptyInboundFrameCreditsNothing() async throws {
        // The client half on its own, as `closedChannelCreditsNothing` drives it.
        let sent = Mutex<[CentralRequest]>([])
        let channel = LinkL2CAPChannel(channel: 11, psm: Self.psm) { request in
            sent.withLock { $0.append(request) }
        }
        let stream = channel.inbound()

        // A zero-length frame: crediting it would put `l2capCredit(bytes: 0)` on the wire,
        // which the provider rejects as a protocol violation and answers by closing.
        try channel.receive(Data())
        #expect(sent.withLock { $0 }.isEmpty)

        // And the channel is untouched: the next real frame is delivered and credited, and a
        // write still goes out — neither would happen on a channel that had been torn down.
        try channel.receive(Data([1, 2, 3]))
        #expect(sent.withLock { $0 } == [.l2capCredit(channel: 11, bytes: 3)])
        channel.addCredit(bytes: 8)
        try await channel.write(Data([9]))
        #expect(sent.withLock { $0 }.contains(.l2capData(channel: 11, data: Data([9]))))

        // The consumer saw the real bytes and nothing for the empty frame.
        let first = try await bounded(seconds: 5) { () -> Data? in
            for try await value in stream { return value }
            return nil
        }
        #expect(first == Data([1, 2, 3]))
    }

    @Test("An inbound frame larger than the chunk size is a protocol violation")
    func oversizedInboundFrameIsRejected() async throws {
        // The client half on its own, as `closedChannelCreditsNothing` drives it.
        let sent = Mutex<[CentralRequest]>([])
        let channel = LinkL2CAPChannel(channel: 13, psm: Self.psm) { request in
            sent.withLock { $0.append(request) }
        }

        // Exactly the chunk size is what an honest provider's largest frame is: accepted, and
        // credited for every byte.
        let limit = LinkFlowControl.l2capInitialCredit / 4
        try channel.receive(Data(repeating: 0x11, count: limit))
        #expect(sent.withLock { $0 } == [.l2capCredit(channel: 13, bytes: limit)])

        // One byte more than both ends agreed to split their writes into. The throw is what
        // `LinkCentral` turns into a dropped session; nothing is buffered, and nothing is
        // credited, so the peer gets no window back for bytes this client refused.
        sent.withLock { $0.removeAll() }
        #expect(throws: LinkL2CAPError.frameTooLarge(limit + 1)) {
            try channel.receive(Data(repeating: 0x22, count: limit + 1))
        }
        #expect(sent.withLock { $0 }.isEmpty)
    }

    // MARK: - Credit validation

    @Test("A credit the scheme does not permit closes the client's channel", arguments: [0, -1, -8192, LinkFlowControl.l2capInitialCredit + 1, Int.max])
    func clientRejectsAnOutOfRangeCredit(bytes: Int) async throws {
        // The client half on its own, as `closedChannelCreditsNothing` drives it.
        let sent = Mutex<[CentralRequest]>([])
        let channel = LinkL2CAPChannel(channel: 9, psm: Self.psm) { request in
            sent.withLock { $0.append(request) }
        }
        let stream = channel.inbound()

        channel.addCredit(bytes: bytes)

        // The channel is torn down: the provider is told, and the consumer's stream throws.
        #expect(sent.withLock { $0 } == [.l2capClose(channel: 9)])
        await #expect(throws: LinkL2CAPError.invalidCredit(bytes)) {
            for try await _ in stream {}
        }
        // And nothing was added to the window: a later write must not be let through on
        // credit that was never legitimately granted.
        await #expect(throws: LinkL2CAPError.closed) { try await channel.write(Data([1])) }
    }

    @Test("A credit the scheme does not permit closes the provider's channel")
    func providerRejectsAnOutOfRangeCredit() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.badcredit")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)
        #expect(await fake.onQueue { fake.isClosed } == false)

        // Ids are allocated from 1, so the one channel this rig opened is 1. Sent straight
        // down the link, behind `Central`'s back: no honest client can produce this.
        let link = rig.link
        link.queue.async { link.send(.l2capCredit(channel: 1, bytes: -1)) }

        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.isClosed } }
        #expect(await fake.onQueue { fake.isClosed })

        // And the client hears the close, so its consumer is not left waiting on a channel
        // the provider has already torn down: the stream ends rather than hanging.
        let stream = channel.incomingData
        try await bounded(seconds: 5) {
            do {
                for try await _ in stream {}
            } catch {
                // A close carrying the provider's rejection is exactly what is expected here.
            }
        }

        await tearDown(rig)
    }

    // MARK: - Open failure

    @Test("An open for a peripheral the session never connected fails promptly")
    func openForAnUnknownPeripheralIsAnswered() async throws {
        let (rig, _) = try await makeRig(label: "l2cap.unknownPeripheral")
        let unknown = UUID(uuidString: "4C9E1B7A-3D5F-4E80-91A2-6B3C8D0E5F17")!
        let events = Mutex<[PeripheralEvent]>([])

        // Opened through the mirror directly: a peripheral this client never connected has no
        // `Peripheral` over it, and never connecting it is the point.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rig.link.queue.async {
                guard let remote = rig.link.retrievePeripherals(withIdentifiers: [unknown]).first else {
                    continuation.resume()
                    return
                }
                remote.eventHandler = { event in events.withLock { $0.append(event) } }
                remote.openL2CAPChannel(Self.psm)
                continuation.resume()
            }
        }

        // Promptly: the completion is the provider's answer, not an expiring timeout.
        await waitFor(timeout: .seconds(5)) { !events.withLock { $0 }.isEmpty }
        let event = try #require(events.withLock { $0 }.first)
        guard case .didOpenL2CAPChannel(let channel, let error) = event else {
            Issue.record("expected a didOpenL2CAPChannel, got \(event)")
            await tearDown(rig)
            return
        }
        #expect(channel == nil)
        let nsError = try #require(error as NSError?)
        #expect(nsError.domain == "BLESwiftProvider")
        #expect(nsError.code == 1)

        // And the half-channel the open filed is gone.
        let filed = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            rig.link.queue.async { continuation.resume(returning: rig.link.openChannelCount) }
        }
        #expect(filed == 0)

        await tearDown(rig)
    }

    @Test("A failed open on the provider throws from the client's openL2CAPChannel")
    func openFailurePropagates() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.openFailure")
        let fake = rig.fake
        await fake.onQueue {
            fake.l2capOpenBehavior = .fail(NSError(domain: "L2CAPLinkTests", code: 9))
        }

        do {
            _ = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
            Issue.record("expected the open to throw")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "L2CAPLinkTests")
            #expect(nsError.code == 9)
        }

        await tearDown(rig)
    }
}
#endif
