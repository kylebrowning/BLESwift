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
import BLESwiftCompat17
import Testing

/// Tests for the client half of an L2CAP channel, driven over a real link against a provider whose
/// central backend is a ``BLESwiftTestSupport/FakeCentral``. Every byte, credit, and close crosses
/// a socket.
@Suite("L2CAP over the link")
struct L2CAPLinkTests {

    private static let psm = L2CAPPSM(0x0041)
    private static let deviceID = UUID(uuidString: "1D8E4A2C-0F1B-4C2D-9A7E-5B6C7D8E9F01")!

    /// Everything that one test rig holds: the client's `Central` and link, the provider, and the
    /// `FakePeripheral` that the provider's session serves.
    private struct Rig {
        let central: Central
        let link: LinkCentral
        let provider: Provider
        let fake: FakePeripheral
    }

    /// A `Sendable` hand-off for the `FakePeripheral` that the backend factory builds on the
    /// session's queue. `Mutex` is non-copyable, so it cannot live in ``Rig`` itself.
    private final class PeripheralBox: Sendable {
        private let storage = Mutex<FakePeripheral?>(nil)

        var peripheral: FakePeripheral? { storage.withLock { $0 } }

        func store(_ peripheral: FakePeripheral) { storage.withLock { $0 = peripheral } }
    }

    /// A provider whose passthrough central backend is a `FakeCentral` that serves one
    /// `FakePeripheral`. The result also has a `Central` that is linked to the provider and
    /// connected to that peripheral.
    ///
    /// The virtual radio hosts no fixtures here, so it vends no remote for the fake's identifier
    /// and the composite resolves the identifier to the fake. This is why `VirtualCentralBackend`
    /// must answer only for devices that it knows.
    private func makeRig(label: String) async throws -> (Rig, Peripheral) {
        let fakeBox = PeripheralBox()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            // The code runs on the session's queue, so the test can drive the fake's scripting
            // setters inline, because the queue confines them.
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: "Fake L2CAP", queue: queue)
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            fakeBox.store(peripheral)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchQueue(label: label)
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

    /// Tears a rig down. It closes the link first, then the provider after its session has gone.
    private func tearDown(_ rig: Rig) async {
        rig.link.shutdown()
        await waitFor(timeout: .seconds(5)) { await rig.provider.sessionCount == 0 }
        await rig.provider.stop()
    }

    /// The `FakeL2CAPChannel` that the provider's `FakePeripheral` vended for the open, after it
    /// exists.
    private func openedChannel(_ rig: Rig) async throws -> FakeL2CAPChannel {
        let fake = rig.fake
        await waitFor { await fake.onQueue { fake.lastOpenedL2CAPChannel != nil } }
        return try #require(await fake.onQueue { fake.lastOpenedL2CAPChannel })
    }

    // MARK: - Channel identity

    /// A raw central-role client. It shows every frame in and out, so a test can send what no
    /// honest `LinkCentral` would send: two opens that name the same channel id.
    private final class RawClient: Sendable {
        let connection: LinkConnection
        private let received = Mutex<[CentralWireEvent]>([])
        private let hello = Mutex<Bool>(false)

        /// Every central event that the provider has sent so far, in order.
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
            // The closure captures the boxes strongly, and ``shutdown()`` releases them. A `Mutex`
            // is non-copyable, so the closure cannot capture the two boxes by value.
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

    /// A provider that serves one `FakePeripheral` over `FakeCentral`, with no client attached. The
    /// raw-client tests below drive this rig by hand.
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
    // Sockets in a CI simulator are not reliable. The two-simulator E2E on real simulators covers
    // the simulator-side path.

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

        client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: Self.psm.rawValue, channel: 7))
        await waitFor(timeout: .seconds(5)) {
            client.events.contains { if case .didOpenL2CAPChannel = $0 { return true } else { return false } }
        }
        #expect(client.events.contains(.didOpenL2CAPChannel(
            peripheral: Self.deviceID, channel: 7, psm: Self.psm.rawValue, error: nil
        )))
        let fake = try #require(box.peripheral)
        let first = try #require(await fake.onQueue { fake.lastOpenedL2CAPChannel })

        // A second open names the same id. No honest client sends this. It would orphan the bridge
        // above, with its pump, transport, and credit window still live.
        client.send(.openL2CAPChannel(peripheral: Self.deviceID, psm: Self.psm.rawValue, channel: 7))
        await waitFor(timeout: .seconds(5)) {
            client.events.filter { if case .didOpenL2CAPChannel = $0 { return true } else { return false } }.count == 2
        }
        // `true` means that the provider refused the open. The result maps to `Bool` because
        // `compactMap` would swallow the `nil` of a successful open.
        let refusals = client.events.compactMap { event -> Bool? in
            guard case .didOpenL2CAPChannel(_, let channel, _, let error) = event, channel == 7 else { return nil }
            return error != nil
        }
        #expect(refusals == [false, true], "the first open takes the id and the duplicate is refused")
        // The provider closed the channel that the second open produced. It did not bridge this
        // channel, which is not the channel that still serves id 7.
        let second = try #require(await fake.onQueue { fake.lastOpenedL2CAPChannel })
        #expect(second !== first)
        await waitFor(timeout: .seconds(5)) { await second.onQueue { second.isClosed } }

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

    /// Runs `body` on `session`'s serial queue and returns its result. Tests use this to touch
    /// session state, which the queue confines and no lock protects.
    private func onSessionQueue<T: Sendable>(
        _ session: CentralSession,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            session.queue.async { continuation.resume(returning: body()) }
        }
    }

    /// The one central-role session that `provider` serves.
    private func centralSession(of provider: Provider) async throws -> CentralSession {
        try #require(await provider.liveSessions.compactMap { $0 as? CentralSession }.first)
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

        // The id goes back to the client and the provider hands it straight to another channel. The
        // pump's hop can land in this state: it passed its cancellation check just before the
        // teardown dropped its bridge.
        client.send(.l2capClose(channel: 7))
        await open()
        let live = try #require(await onSessionQueue(session) { session.channels[7] })
        #expect(live !== stale)

        // The bytes of the dead bridge must not reach the client under an id that is now another
        // channel's id.
        let staleBytes = Data([0xDE, 0xAD])
        await onSessionQueue(session) {
            session.sendFromPump(.l2capData(channel: 7, data: staleBytes), channel: 7, open: stale)
        }
        // The live bridge's own send bounds the wait. The queue is serial and the connection writes
        // in order, so a frame that arrives after this send was never sent at all.
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

        /// Opens channel id 7 and returns the transport that the provider bridged it to.
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

        // Each round parks writes on the channel behind id 7, closes the channel so every parked
        // write fails, and reuses the id at once. The failures name channel 7, which is by then
        // another bridge's channel.
        for _ in 0..<2 {
            let stale = try await open()
            await stale.onQueue { stale.writeBehavior = .hold }
            for _ in 0..<8 {
                client.send(.l2capData(channel: 7, data: Data([0x01, 0x02, 0x03, 0x04])))
            }
            await waitFor(timeout: .seconds(5)) { await stale.onQueue { !stale.writtenData.isEmpty } }
            client.send(.l2capClose(channel: 7))
            let live = try await open()

            // The live channel is never the stale channel. The stale channel's unwinding writes
            // never close it, and it still carries data in both directions.
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
        let queue = DispatchQueue(label: "l2cap.dealloc")
        // The test dials a port that nothing listens on. This central never connects, so no credit
        // can ever arrive from a provider. Only the central's teardown can resume a parked writer.
        var link: LinkCentral? = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: try closedPort()),
            queue: queue,
            clientName: "dealloc",
            retryInterval: .seconds(60)
        )
        weak let deallocated = link
        // The hop captures the value and releases it with the hop, so `link` stays the only strong
        // reference that this test holds.
        let channel: LinkL2CAPChannel = await withCheckedContinuation { continuation in
            queue.async { [link] in
                continuation.resume(returning: link!.registerChannel(1, psm: Self.psm, peripheral: Self.deviceID))
            }
        }

        try await bounded { try await channel.write(Data(repeating: 0x5A, count: LinkFlowControl.l2capInitialCredit)) }
        let parked = Task { try await channel.write(Data([0x01])) }
        await waitFor(timeout: .seconds(5)) { channel.suspendedWriterCount == 1 }
        #expect(channel.suspendedWriterCount == 1)

        // The test drains before the release. This is the test's whole synchronization. The send
        // closure that builds a channel holds a *strong* reference to the central, so blocks from
        // the window-filling write can still be queued when the test drops its last reference. One
        // hop onto the serial queue flushes them.
        _ = await Self.onQueue(queue) { true }

        // The test releases the central and does not shut it down, because `deinit` is under test.
        // A central that goes out of scope must not leave its writers parked forever.
        link = nil
        // The gate is the deallocation itself, which the test observes. Whichever thread holds the
        // last reference runs `deinit`.
        await waitFor(timeout: .seconds(5)) { deallocated == nil }
        #expect(deallocated == nil)

        do {
            try await bounded { try await parked.value }
            Issue.record("expected the parked write to fail")
        } catch let error as LinkL2CAPError {
            #expect(error == .closed)
        }
    }

    /// Hops onto `queue` to run `body` and returns its result. Test code that runs off the queue
    /// uses this to touch state that the queue confines.
    private static func onQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @Sendable @escaping () -> T) async -> T {
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

        // The chunks are 4 KiB. Each byte comes from its absolute offset, so a reorder or a dropped
        // chunk is visible in the comparison, not only in the length.
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

        // 8 x 64 KiB is 512 KiB against a 256 KiB window, so at least half the writers must suspend
        // for credit. They arrive concurrently, and each needs its own continuation.
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

        // Blocks may land in any order. Each block must survive as one contiguous run of its own
        // fill byte. A run-length pass finds exactly eight runs, one for each writer.
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

        // 600 KiB in 16 KiB pieces. The last piece is ragged, as a real transport's reads are.
        let pieceSize = 16 * 1024
        let expected = Data((0..<(600 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ ($0 >> 8)) })
        #expect(expected.count == 600 * 1024)
        var offset = 0
        while offset < expected.count {
            let end = min(offset + pieceSize, expected.count)
            fake.simulateInbound(expected[offset..<end])
            offset = end
        }

        // 600 KiB is more than twice the initial credit of 262 144 bytes, so the client must grant
        // credit back at least twice for this test to complete at all.
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

        // A zero-length payload must not reach the wire and come back as a credit of `0`. That
        // would cost the channel, because the client refuses a non-positive credit as a violation.
        try await channel.write(Data())
        #expect(await fake.onQueue { fake.writtenData.isEmpty })

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

        // The burst is deep enough that the provider still has writes chained behind the one it
        // performs when the close arrives. `tearDown` must cancel this chain with the pump, or it
        // outlives the transport.
        let payload = Data(repeating: 0x7E, count: 4096)
        let writer = Task {
            for _ in 0..<32 { try await channel.write(payload) }
        }
        await channel.close()
        _ = try? await bounded { try await writer.value }

        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.isClosed } }
        #expect(await fake.onQueue { fake.isClosed })
        // Every byte that the fake did take arrived whole. A cancelled chain truncates the stream
        // but never corrupts it.
        let written = await fake.onQueue { fake.writtenData }
        #expect(written.allSatisfy { $0 == payload })

        await tearDown(rig)
    }

    // MARK: - Inbound credit

    @Test("Bytes arriving after the channel closed are dropped, and dropped bytes earn no credit")
    func closedChannelCreditsNothing() async throws {
        // This is the client half on its own. The provider frames are what `LinkCentral` would feed
        // it, and `sent` is the link on which it would put its own requests.
        let sent = Mutex<[CentralRequest]>([])
        let channel = LinkL2CAPChannel(channel: 7, psm: Self.psm) { request in
            sent.withLock { $0.append(request) }
        }

        try channel.receive(Data([1, 2, 3]))
        #expect(sent.withLock { $0.count } == 1)
        if case .l2capCredit(let identifier, let bytes) = sent.withLock({ $0[0] }) {
            #expect(identifier == 7)
            #expect(bytes == 3)
        } else {
            Issue.record("expected an l2capCredit, got \(sent.withLock { $0 })")
        }

        // The provider closes the channel, then a frame that was already in flight arrives. The
        // channel must drop it without credit, because credit would hand the provider a window on a
        // channel that never reads again.
        channel.remoteClosed(error: nil)
        sent.withLock { $0.removeAll() }
        try channel.receive(Data([4, 5, 6, 7]))
        #expect(sent.withLock { $0 }.isEmpty)
    }

    @Test("An empty inbound frame earns no credit and leaves the channel open")
    func emptyInboundFrameCreditsNothing() async throws {
        let sent = Mutex<[CentralRequest]>([])
        let channel = LinkL2CAPChannel(channel: 11, psm: Self.psm) { request in
            sent.withLock { $0.append(request) }
        }
        let stream = channel.inbound()

        // A zero-length frame. Credit for it would put `l2capCredit(bytes: 0)` on the wire, which
        // the provider rejects as a protocol violation with a close.
        try channel.receive(Data())
        #expect(sent.withLock { $0 }.isEmpty)

        // The channel is untouched. The next real frame is delivered and credited, and a write
        // still goes out. Neither would happen on a channel that was torn down.
        try channel.receive(Data([1, 2, 3]))
        #expect(sent.withLock { $0 } == [.l2capCredit(channel: 11, bytes: 3)])
        channel.addCredit(bytes: 8)
        try await channel.write(Data([9]))
        #expect(sent.withLock { $0 }.contains(.l2capData(channel: 11, data: Data([9]))))

        let first = try await bounded(seconds: 5) { () -> Data? in
            for try await value in stream { return value }
            return nil
        }
        #expect(first == Data([1, 2, 3]))
    }

    @Test("An inbound frame larger than the chunk size is a protocol violation")
    func oversizedInboundFrameIsRejected() async throws {
        let sent = Mutex<[CentralRequest]>([])
        let channel = LinkL2CAPChannel(channel: 13, psm: Self.psm) { request in
            sent.withLock { $0.append(request) }
        }

        // Exactly the chunk size is the largest frame of an honest provider. The channel accepts it
        // and gives credit for every byte.
        let limit = LinkFlowControl.l2capInitialCredit / 4
        try channel.receive(Data(repeating: 0x11, count: limit))
        #expect(sent.withLock { $0 } == [.l2capCredit(channel: 13, bytes: limit)])

        // One byte more than the agreed chunk size. `LinkCentral` turns the throw into a dropped
        // session. The channel buffers nothing and gives no credit for bytes it refused.
        sent.withLock { $0.removeAll() }
        #expect(throws: LinkL2CAPError.frameTooLarge(limit + 1)) {
            try channel.receive(Data(repeating: 0x22, count: limit + 1))
        }
        #expect(sent.withLock { $0 }.isEmpty)
    }

    // MARK: - Credit validation

    @Test("A credit the scheme does not permit closes the client's channel", arguments: [0, -1, -8192, LinkFlowControl.l2capInitialCredit + 1, Int.max])
    func clientRejectsAnOutOfRangeCredit(bytes: Int) async throws {
        let sent = Mutex<[CentralRequest]>([])
        let channel = LinkL2CAPChannel(channel: 9, psm: Self.psm) { request in
            sent.withLock { $0.append(request) }
        }
        let stream = channel.inbound()

        channel.addCredit(bytes: bytes)

        #expect(sent.withLock { $0 } == [.l2capClose(channel: 9)])
        await #expect(throws: LinkL2CAPError.invalidCredit(bytes)) {
            for try await _ in stream {}
        }
        // Nothing was added to the window. A later write must not pass on credit that nobody
        // legitimately granted.
        await #expect(throws: LinkL2CAPError.closed) { try await channel.write(Data([1])) }
    }

    @Test("A credit the scheme does not permit closes the provider's channel")
    func providerRejectsAnOutOfRangeCredit() async throws {
        let (rig, peripheral) = try await makeRig(label: "l2cap.badcredit")
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .seconds(5))
        let fake = try await openedChannel(rig)
        #expect(await fake.onQueue { fake.isClosed } == false)

        // The ids start at 1, so the one channel that this rig opened is 1. The test sends straight
        // down the link, behind `Central`'s back. No honest client can produce this.
        let link = rig.link
        link.queue.async { link.send(.l2capCredit(channel: 1, bytes: -1)) }

        await waitFor(timeout: .seconds(5)) { await fake.onQueue { fake.isClosed } }
        #expect(await fake.onQueue { fake.isClosed })

        // The client hears the close, so its consumer does not wait on a channel that the provider
        // already tore down. The stream ends and does not hang.
        let stream = channel.incomingData
        try await bounded(seconds: 5) {
            do {
                for try await _ in stream {}
            } catch {
                // A close that carries the provider's rejection is exactly what the test expects
                // here.
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

        // The test opens the channel through the mirror directly, because a peripheral that this
        // client never connected has no `Peripheral`. The client must not connect it.
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
