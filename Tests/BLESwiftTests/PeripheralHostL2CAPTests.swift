//
//  PeripheralHostL2CAPTests.swift
//  BLESwiftTests
//

@preconcurrency import CoreBluetooth
import Dispatch
import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Creates a `PeripheralHost` wired to a new `FakePeripheralManager` confined to a queue. It has
/// the same shape as the factory in `PeripheralHostTests.swift`, which is private to that file.
private func makeFakePeripheralHost(
    label: String = "BLESwiftTests.FakePeripheralManager.L2CAP"
) -> (PeripheralHost, FakePeripheralManager, DispatchQueue) {
    let queue = DispatchQueue(label: label)
    let fake = FakePeripheralManager(queue: queue)
    let host = PeripheralHost(backend: fake, queue: queue)
    return (host, fake, queue)
}

/// Creates a fake host and powers it on. It returns after the host has seen `.poweredOn`.
private func makePoweredOnHost() async -> (PeripheralHost, FakePeripheralManager, DispatchQueue) {
    let (host, fake, queue) = makeFakePeripheralHost()
    fake.simulateStateChange(.poweredOn)
    await fake.onQueue {} // Flush the state-change delivery.
    return (host, fake, queue)
}

/// Waits until `fake` has recorded `count` publish calls. It fails the test after many tries.
private func waitForPublishCalls(_ fake: FakePeripheralManager, count: Int) async {
    for _ in 0..<1_000 {
        if await fake.onQueue({ fake.publishL2CAPChannelCalls.count }) >= count { return }
        await Task.yield()
    }
    Issue.record("the fake did not record \(count) publish call(s)")
}

/// A backend that conforms to `PeripheralManaging` but not to `L2CAPPublishing`. It delivers
/// no events.
private final class NonPublishingBackend: PeripheralManaging {
    var eventHandler: ((PeripheralHostEvent) -> Void)?
    var radioState: CentralState { .poweredOn }
    var isAdvertising: Bool { false }
    static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }
    func startAdvertising(_ advertisement: PeripheralAdvertisement) {}
    func stopAdvertising() {}
    func add(_ service: GATTService) {}
    func removeAllHostedServices() {}
    func respond(to token: RequestToken, value: Data?, error: ATTError?) {}
    func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool { true }
}

@Suite("PeripheralHost L2CAP")
struct PeripheralHostL2CAPTests {

    // MARK: - Publish

    @Test("publishL2CAPChannel returns the PSM that the backend published")
    func publishReturnsPSM() async throws {
        let (host, fake, _) = await makePoweredOnHost()
        await fake.onQueue { fake.publishBehavior = .succeed(L2CAPPSM(0x0085)) }

        let psm = try await host.publishL2CAPChannel(requiresEncryption: true)

        #expect(psm == L2CAPPSM(0x0085))
        #expect(await fake.onQueue { fake.publishL2CAPChannelCalls } == [true])
    }

    @Test("publishL2CAPChannel throws the backend's error unchanged")
    func publishErrorThrows() async throws {
        let (host, fake, _) = await makePoweredOnHost()
        let expected = NSError(domain: "BLESwiftTests", code: 41)
        await fake.onQueue { fake.publishBehavior = .fail(expected) }

        await #expect(throws: expected) {
            _ = try await host.publishL2CAPChannel()
        }
    }

    @Test("publishL2CAPChannel throws .l2capPublishFailed for a backend that is not L2CAPPublishing")
    func nonConformingBackendThrows() async throws {
        let queue = DispatchQueue(label: "BLESwiftTests.NonPublishingBackend")
        let host = PeripheralHost(backend: NonPublishingBackend(), queue: queue)

        await #expect(throws: BLESwiftError.l2capPublishFailed) {
            _ = try await host.publishL2CAPChannel()
        }
    }

    @Test("publishL2CAPChannel throws .bluetoothUnavailable before the radio is powered on")
    func publishBeforePowerOnThrows() async throws {
        let (host, fake, _) = makeFakePeripheralHost()

        await #expect(throws: BLESwiftError.bluetoothUnavailable) {
            _ = try await host.publishL2CAPChannel()
        }
        #expect(await fake.onQueue { fake.publishL2CAPChannelCalls }.isEmpty)
    }

    @Test("A publish with neither a PSM nor an error throws .l2capPublishFailed")
    func publishWithNoPSMThrows() async throws {
        let (host, fake, _) = await makePoweredOnHost()
        await fake.onQueue { fake.publishBehavior = .hold }

        let publishTask = Task { try await host.publishL2CAPChannel() }
        await waitForPublishCalls(fake, count: 1)
        fake.simulatePublishResult(psm: nil, error: nil)

        await #expect(throws: BLESwiftError.l2capPublishFailed) {
            _ = try await publishTask.value
        }
    }

    @Test("Cancelling a held publish throws .operationCancelled, and a later success is unpublished")
    func cancelledPublishIsUnpublished() async throws {
        let (host, fake, _) = await makePoweredOnHost()
        await fake.onQueue { fake.publishBehavior = .hold }

        let publishTask = Task { try await host.publishL2CAPChannel() }
        await waitForPublishCalls(fake, count: 1)
        publishTask.cancel()

        await #expect(throws: BLESwiftError.operationCancelled) {
            _ = try await publishTask.value
        }

        fake.simulatePublishResult(psm: L2CAPPSM(0x0091), error: nil)
        await fake.onQueue {} // Flush the publish result.
        await fake.onQueue {} // Flush the unpublish result.

        #expect(await fake.onQueue { fake.unpublishL2CAPChannelCalls } == [L2CAPPSM(0x0091)])
        // The host did not keep the PSM, so an unpublish of it is not valid.
        await #expect(throws: BLESwiftError.invalidArgument("PSM \(0x0091) is not published")) {
            try await host.unpublishL2CAPChannel(L2CAPPSM(0x0091))
        }
    }

    @Test("Power off fails a held publish with .bluetoothUnavailable and forgets the published PSMs")
    func powerOffFailsPublishAndEmptiesSet() async throws {
        let (host, fake, _) = await makePoweredOnHost()
        let published = try await host.publishL2CAPChannel()
        #expect(published == L2CAPPSM(0x0080))

        await fake.onQueue { fake.publishBehavior = .hold }
        let publishTask = Task { try await host.publishL2CAPChannel() }
        await waitForPublishCalls(fake, count: 2)
        fake.simulateStateChange(.poweredOff)

        await #expect(throws: BLESwiftError.bluetoothUnavailable) {
            _ = try await publishTask.value
        }
        await #expect(throws: BLESwiftError.invalidArgument("PSM \(0x0080) is not published")) {
            try await host.unpublishL2CAPChannel(published)
        }
    }

    // MARK: - Unpublish

    @Test("unpublishL2CAPChannel removes a published PSM, and a second unpublish of it is not valid")
    func unpublishPublishedPSM() async throws {
        let (host, fake, _) = await makePoweredOnHost()
        let psm = try await host.publishL2CAPChannel()

        try await host.unpublishL2CAPChannel(psm)

        #expect(await fake.onQueue { fake.unpublishL2CAPChannelCalls } == [psm])
        await #expect(throws: BLESwiftError.invalidArgument("PSM \(psm.rawValue) is not published")) {
            try await host.unpublishL2CAPChannel(psm)
        }
    }

    @Test("unpublishL2CAPChannel of a PSM that is not published throws .invalidArgument")
    func unpublishUnknownPSMThrows() async throws {
        let (host, fake, _) = await makePoweredOnHost()

        await #expect(throws: BLESwiftError.invalidArgument("PSM \(0x00AA) is not published")) {
            try await host.unpublishL2CAPChannel(L2CAPPSM(0x00AA))
        }
        #expect(await fake.onQueue { fake.unpublishL2CAPChannelCalls }.isEmpty)
    }

    // MARK: - Incoming channels

    @Test("An incoming channel reaches two consumers, and its handle drives the transport")
    func incomingChannelReachesTwoConsumers() async throws {
        let (host, fake, queue) = await makePoweredOnHost()
        let first = await host.incomingL2CAPChannels()
        let second = await host.incomingL2CAPChannels()
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()

        let central = UUID()
        let channel = FakeL2CAPChannel(psm: L2CAPPSM(0x0080), queue: queue)
        fake.simulateIncomingL2CAPChannel(channel, central: central)

        let one = try #require(await firstIterator.next())
        let two = try #require(await secondIterator.next())
        #expect(one.psm == L2CAPPSM(0x0080))
        #expect(one.central == central)
        #expect(two.psm == L2CAPPSM(0x0080))
        #expect(two.central == central)

        try await one.write(Data([1, 2, 3]))
        #expect(await channel.onQueue { channel.writtenData } == [Data([1, 2, 3])])

        channel.simulateInbound(Data([9]))
        var inbound = one.incomingData.makeAsyncIterator()
        #expect(try await inbound.next() == Data([9]))

        two.close()
        #expect(await channel.onQueue { channel.isClosed })
        #expect(try await inbound.next() == nil)
    }

    @Test("An incoming channel with no consumer is closed")
    func incomingChannelWithoutConsumerIsClosed() async throws {
        let (_, fake, queue) = await makePoweredOnHost()
        let channel = FakeL2CAPChannel(psm: L2CAPPSM(0x0080), queue: queue)

        fake.simulateIncomingL2CAPChannel(channel, central: UUID())
        await fake.onQueue {} // Flush the delivery. The close then runs on the same queue.

        #expect(await channel.onQueue { channel.isClosed })
        #expect(await channel.onQueue { channel.closeError == nil })
    }

    @Test("stopAndExtractState() finishes the incoming-channel streams")
    func stopFinishesIncomingStream() async throws {
        // A fake backend cannot reach the body of `stopAndExtractState()` (see
        // `PeripheralHostCancellationTests`). A real `CBPeripheralManager` can, as the adopting
        // test in `RetrievalTests` does for `Central`.
        let queue = DispatchQueue(label: "BLESwiftTests.PeripheralHostL2CAP.Stop")
        let manager = CBPeripheralManager(delegate: nil, queue: queue)
        let host = PeripheralHost(backend: manager, queue: queue)
        let stream = await host.incomingL2CAPChannels()

        _ = try await host.stopAndExtractState()

        for await _ in stream {
            Issue.record("expected the stream to finish without an element")
        }
        for await _ in await host.incomingL2CAPChannels() {
            Issue.record("expected a stream after the stop to finish at once")
        }
    }
}
