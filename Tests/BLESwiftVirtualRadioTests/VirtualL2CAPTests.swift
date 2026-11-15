//
//  VirtualL2CAPTests.swift
//  BLESwiftVirtualRadioTests
//

import BLESwift
import BLESwiftCore
@testable import BLESwiftVirtualRadio
import Dispatch
import Foundation
import Testing

/// L2CAP channels on the virtual radio: the in-memory channel pair, the radio's publish and open
/// rules, and a `PeripheralHost` that serves a `Central` over one radio.
@Suite("Virtual radio L2CAP")
struct VirtualL2CAPTests {

    private static let psm = L2CAPPSM(0x0080)

    /// The byte limit of one FIFO: `LinkFlowControl.l2capInitialCredit`. This test target does
    /// not depend on `BLESwiftLink`, so the value is written here.
    private static let limit = 262_144

    /// A flag that a task sets and the test reads.
    private actor Flag {
        private(set) var value = false
        func set() { value = true }
    }

    /// How one inbound stream ended.
    private enum End: Equatable {
        case finished
        case failed(String)
    }

    /// Reads `stream` to its end. It returns every chunk joined together, and how the stream
    /// ended. A thrown error is recorded by its description.
    private static func drain(_ stream: AsyncThrowingStream<Data, Error>) async -> (Data, End) {
        var bytes = Data()
        do {
            for try await chunk in stream {
                bytes.append(chunk)
            }
            return (bytes, .finished)
        } catch {
            return (bytes, .failed(describe(error)))
        }
    }

    /// A description that tells the test errors apart.
    private static func describe(_ error: Error) -> String {
        if let error = error as? BLESwiftError { return "BLESwiftError.\(error)" }
        let error = error as NSError
        return "\(error.domain).\(error.code)"
    }

    /// The description of ``VirtualRadio/peripheralDisconnectedError``.
    private static let disconnected = "CBErrorDomain.7"

    /// A handler that accepts every channel and gives each one to a stream.
    private actor AcceptingHandler: VirtualL2CAPAccepting {
        let channels: AsyncStream<any L2CAPChannelRemote>
        private let continuation: AsyncStream<any L2CAPChannelRemote>.Continuation

        init() {
            (channels, continuation) = AsyncStream.makeStream()
        }

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.readNotPermitted)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .success(())
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}

        func acceptL2CAPChannel(_ channel: any L2CAPChannelRemote, psm: L2CAPPSM, from central: Subscriber) async {
            continuation.yield(channel)
        }
    }

    /// A radio with one device that accepts channels, and one session connected to it.
    private static func connectedRadio() async -> (radio: VirtualRadio, handle: VirtualDeviceHandle, handler: AcceptingHandler, session: UUID) {
        let radio = VirtualRadio()
        let handler = AcceptingHandler()
        let device = VirtualDevice(
            descriptor: VirtualDeviceDescriptor(advertisement: AdvertisementData(localName: "L2CAP", isConnectable: true)),
            handler: handler
        )
        let handle = await radio.register(device)
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        _ = await radio.connect(session: session, device: handle.identifier, sink: { _ in })
        return (radio, handle, handler, session)
    }

    // MARK: - The channel pair

    @Test("A pair carries data both ways")
    func pairEchoesBothWays() async throws {
        let (central, host) = VirtualL2CAPChannel.pair(psm: Self.psm)
        var centralInbound = central.inbound().makeAsyncIterator()
        var hostInbound = host.inbound().makeAsyncIterator()

        try await central.write(Data([1, 2, 3]))
        #expect(try await hostInbound.next() == Data([1, 2, 3]))
        try await host.write(Data([4, 5]))
        #expect(try await centralInbound.next() == Data([4, 5]))
        #expect(central.psm == Self.psm)
        #expect(host.psm == Self.psm)
    }

    @Test("Data written before inbound() arrives, and a second inbound() finishes at once")
    func dataBeforeInboundArrives() async throws {
        let (central, host) = VirtualL2CAPChannel.pair(psm: Self.psm)
        try await central.write(Data([1]))
        try await central.write(Data([2]))
        try await central.write(Data())

        var inbound = host.inbound().makeAsyncIterator()
        #expect(try await inbound.next() == Data([1]))
        #expect(try await inbound.next() == Data([2]))

        let second = await Self.drain(host.inbound())
        #expect(second.0.isEmpty)
        #expect(second.1 == .finished)
    }

    @Test("A write waits at the limit until the reader takes data", .timeLimit(.minutes(1)))
    func backPressure() async throws {
        let (central, host) = VirtualL2CAPChannel.pair(psm: Self.psm)
        let full = Data(repeating: 0xAB, count: Self.limit)
        try await central.write(full)

        let finished = Flag()
        let blocked = Task {
            try await central.write(Data([0x01]))
            await finished.set()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await finished.value == false)

        var inbound = host.inbound().makeAsyncIterator()
        #expect(try await inbound.next() == full)
        try await blocked.value
        #expect(await finished.value)
        #expect(try await inbound.next() == Data([0x01]))
    }

    @Test("A cancelled waiting write throws .operationCancelled", .timeLimit(.minutes(1)))
    func cancelledWriteThrows() async throws {
        let (central, _) = VirtualL2CAPChannel.pair(psm: Self.psm)
        try await central.write(Data(repeating: 0, count: Self.limit))

        let blocked = Task { try await central.write(Data([1])) }
        try await Task.sleep(for: .milliseconds(20))
        blocked.cancel()

        await #expect(throws: BLESwiftError.operationCancelled) {
            try await blocked.value
        }
    }

    @Test("A graceful close by either end finishes both inbounds cleanly after the buffered data", arguments: [0, 1])
    func gracefulClose(closer: Int) async throws {
        let (central, host) = VirtualL2CAPChannel.pair(psm: Self.psm)
        try await central.write(Data([1, 2]))
        try await host.write(Data([3]))
        // A writer that waits at the limit throws when the pair closes.
        try await central.write(Data(repeating: 0, count: Self.limit))
        let blocked = Task { try await central.write(Data([9])) }
        try await Task.sleep(for: .milliseconds(20))

        (closer == 0 ? central : host).close(error: nil)

        await #expect(throws: BLESwiftError.l2capChannelClosed) {
            try await blocked.value
        }
        let atHost = await Self.drain(host.inbound())
        #expect(atHost.0 == Data([1, 2]) + Data(repeating: 0, count: Self.limit))
        #expect(atHost.1 == .finished)
        let atCentral = await Self.drain(central.inbound())
        #expect(atCentral.0 == Data([3]))
        #expect(atCentral.1 == .finished)

        await #expect(throws: BLESwiftError.l2capChannelClosed) {
            try await central.write(Data([1]))
        }
        #expect(central.isClosed)
        #expect(host.isClosed)
    }

    @Test("An abort throws the error on the closer's end and .l2capChannelClosed on the peer, after the buffered data")
    func abortClose() async throws {
        let (central, host) = VirtualL2CAPChannel.pair(psm: Self.psm)
        try await central.write(Data([1]))
        try await host.write(Data([2]))

        host.close(error: BLESwiftError.timedOut)
        // A second close does nothing.
        central.close(error: nil)

        let atHost = await Self.drain(host.inbound())
        #expect(atHost.0 == Data([1]))
        #expect(atHost.1 == .failed("BLESwiftError.timedOut"))
        let atCentral = await Self.drain(central.inbound())
        #expect(atCentral.0 == Data([2]))
        #expect(atCentral.1 == .failed("BLESwiftError.l2capChannelClosed"))
    }

    @Test("fail(_:) throws the error on both ends after the buffered data, and fails a waiting writer with it")
    func failThrowsOnBothEnds() async throws {
        let (central, host) = VirtualL2CAPChannel.pair(psm: Self.psm)
        try await central.write(Data([1]))
        try await host.write(Data(repeating: 0, count: Self.limit))
        let blocked = Task { try await host.write(Data([9])) }
        try await Task.sleep(for: .milliseconds(20))

        central.fail(VirtualRadio.peripheralDisconnectedError)

        do {
            try await blocked.value
            Issue.record("expected the waiting write to throw")
        } catch {
            #expect(Self.describe(error) == Self.disconnected)
        }
        let atHost = await Self.drain(host.inbound())
        #expect(atHost.0 == Data([1]))
        #expect(atHost.1 == .failed(Self.disconnected))
        let atCentral = await Self.drain(central.inbound())
        #expect(atCentral.0.count == Self.limit)
        #expect(atCentral.1 == .failed(Self.disconnected))
    }

    // MARK: - The radio

    @Test("PSM allocation starts at 0x0080 and reuses a freed value")
    func allocationReusesFreedValue() async throws {
        let (radio, handle, _, _) = await Self.connectedRadio()
        defer { withExtendedLifetime(radio) {} }

        #expect(await handle.publishL2CAP(psm: nil) == .success(L2CAPPSM(0x0080)))
        #expect(await handle.publishL2CAP(psm: nil) == .success(L2CAPPSM(0x0081)))
        #expect(await handle.unpublishL2CAP(L2CAPPSM(0x0080)))
        #expect(await handle.unpublishL2CAP(L2CAPPSM(0x0080)) == false)
        #expect(await handle.publishL2CAP(psm: nil) == .success(L2CAPPSM(0x0080)))
        #expect(await handle.publishL2CAP(psm: nil) == .success(L2CAPPSM(0x0082)))
    }

    @Test("A fixed PSM that is already published fails with code 13")
    func fixedPSMConflict() async throws {
        // The handle holds its radio weakly, so the test keeps the radio alive.
        let (radio, handle, _, _) = await Self.connectedRadio()
        defer { withExtendedLifetime(radio) {} }

        #expect(await handle.publishL2CAP(psm: L2CAPPSM(0x0090)) == .success(L2CAPPSM(0x0090)))
        guard case .failure(let error) = await handle.publishL2CAP(psm: L2CAPPSM(0x0090)) else {
            Issue.record("expected the second publish to fail")
            return
        }
        #expect(error.domain == "BLESwiftProvider")
        #expect(error.code == 13)
    }

    @Test("Every free PSM used fails an automatic publish with code 13")
    func noFreePSM() async throws {
        let (radio, handle, _, _) = await Self.connectedRadio()
        defer { withExtendedLifetime(radio) {} }
        for _ in 0x0080...0x00FF {
            guard case .success = await handle.publishL2CAP(psm: nil) else {
                Issue.record("expected the publish to succeed")
                return
            }
        }
        guard case .failure(let error) = await handle.publishL2CAP(psm: nil) else {
            Issue.record("expected the publish to fail")
            return
        }
        #expect(error.code == 13)
    }

    @Test("An open on a PSM that is not published fails with code 12")
    func openUnpublishedFails() async throws {
        let (radio, handle, _, session) = await Self.connectedRadio()

        guard case .failure(let error) = await radio.openL2CAP(session: session, device: handle.identifier, psm: Self.psm) else {
            Issue.record("expected the open to fail")
            return
        }
        #expect(error.domain == "BLESwiftProvider")
        #expect(error.code == 12)
    }

    @Test("An open from a session that is not connected fails with the disconnect error")
    func openNotConnectedFails() async throws {
        let (radio, handle, _, _) = await Self.connectedRadio()
        _ = await handle.publishL2CAP(psm: Self.psm)

        guard case .failure(let error) = await radio.openL2CAP(session: UUID(), device: handle.identifier, psm: Self.psm) else {
            Issue.record("expected the open to fail")
            return
        }
        #expect(Self.describe(error) == Self.disconnected)
    }

    @Test("A disconnect fails both ends of an open channel with the disconnect error")
    func disconnectFailsBothEnds() async throws {
        let (radio, handle, handler, session) = await Self.connectedRadio()
        _ = await handle.publishL2CAP(psm: Self.psm)
        let central = try await radio.openL2CAP(session: session, device: handle.identifier, psm: Self.psm).get()
        var accepted = handler.channels.makeAsyncIterator()
        let host = try #require(await accepted.next())

        await radio.disconnect(session: session, device: handle.identifier)

        #expect(await Self.drain(central.inbound()).1 == .failed(Self.disconnected))
        #expect(await Self.drain(host.inbound()).1 == .failed(Self.disconnected))
    }

    @Test("A removal fails the open channels and forgets the published PSMs of the device")
    func removalFailsChannelsAndForgetsPSMs() async throws {
        let (radio, handle, handler, session) = await Self.connectedRadio()
        _ = await handle.publishL2CAP(psm: Self.psm)
        let central = try await radio.openL2CAP(session: session, device: handle.identifier, psm: Self.psm).get()
        var accepted = handler.channels.makeAsyncIterator()
        _ = try #require(await accepted.next())

        await handle.remove()

        #expect(await Self.drain(central.inbound()).1 == .failed(Self.disconnected))
        #expect(await radio.publishedL2CAP[handle.identifier] == nil)
        #expect(await radio.l2capChannels[handle.identifier] == nil)
    }

    @Test("A re-registration fails the open channels and starts with no published PSMs")
    func reregistrationForgetsPSMs() async throws {
        let (radio, handle, handler, session) = await Self.connectedRadio()
        _ = await handle.publishL2CAP(psm: Self.psm)
        let central = try await radio.openL2CAP(session: session, device: handle.identifier, psm: Self.psm).get()
        var accepted = handler.channels.makeAsyncIterator()
        _ = try #require(await accepted.next())

        let successor = await radio.register(VirtualDevice(
            descriptor: VirtualDeviceDescriptor(identifier: handle.identifier, advertisement: AdvertisementData(isConnectable: true)),
            handler: AcceptingHandler()
        ))

        #expect(await Self.drain(central.inbound()).1 == .failed(Self.disconnected))
        #expect(await successor.publishL2CAP(psm: nil) == .success(L2CAPPSM(0x0080)))
    }

    // MARK: - PeripheralHost and Central

    /// Polls `condition` every 5 ms until it is `true` or 5 seconds elapse.
    private static func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("A PeripheralHost publishes, a Central opens, the two echo, and the host closes", .timeLimit(.minutes(1)))
    func hostAndCentralEcho() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchQueue(label: "VirtualL2CAPTests.host")
        let host = PeripheralHost(backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, name: "Echo"), queue: hostQueue)
        await Self.waitFor { host.state == .poweredOn }
        let incoming = await host.incomingL2CAPChannels()
        let psm = try await host.publishL2CAPChannel()
        #expect(psm == L2CAPPSM(0x0080))
        try await host.startAdvertising(PeripheralAdvertisement(localName: "Echo", serviceUUIDs: []))

        let centralQueue = DispatchQueue(label: "VirtualL2CAPTests.central")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await Self.waitFor { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: nil, timeout: .seconds(5)) {
            if case .discovered(let discovery) = event, discovery.peripheral.name == "Echo" { found = discovery; break }
        }
        let peripheral = try await central.connect(try #require(found).peripheral)

        let channel = try await peripheral.openL2CAPChannel(psm: psm)
        var incomingIterator = incoming.makeAsyncIterator()
        let accepted = try #require(await incomingIterator.next())
        #expect(accepted.psm == psm)

        // The host echoes each chunk back.
        let echo = Task {
            for try await chunk in accepted.incomingData {
                try await accepted.write(chunk)
            }
        }

        try await channel.write(Data([1, 2, 3]))
        var centralInbound = channel.incomingData.makeAsyncIterator()
        #expect(try await centralInbound.next() == Data([1, 2, 3]))

        accepted.close()
        #expect(try await centralInbound.next() == nil)
        try await echo.value

        try await central.disconnect(peripheral.id)
    }

    @Test("A Central open on an unpublished PSM fails with code 12", .timeLimit(.minutes(1)))
    func centralOpenUnpublishedFails() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchQueue(label: "VirtualL2CAPTests.host.unpublished")
        let host = PeripheralHost(backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, name: "Closed"), queue: hostQueue)
        await Self.waitFor { host.state == .poweredOn }
        try await host.startAdvertising(PeripheralAdvertisement(localName: "Closed", serviceUUIDs: []))

        let centralQueue = DispatchQueue(label: "VirtualL2CAPTests.central.unpublished")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await Self.waitFor { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: nil, timeout: .seconds(5)) {
            if case .discovered(let discovery) = event, discovery.peripheral.name == "Closed" { found = discovery; break }
        }
        let peripheral = try await central.connect(try #require(found).peripheral)

        do {
            _ = try await peripheral.openL2CAPChannel(psm: L2CAPPSM(0x0080))
            Issue.record("expected the open to fail")
        } catch {
            #expect(Self.describe(error) == "BLESwiftProvider.12")
        }
        try await central.disconnect(peripheral.id)
    }
}
