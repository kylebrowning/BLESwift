//
//  L2CAPLinkTests.swift
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

    // MARK: - Open failure

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
