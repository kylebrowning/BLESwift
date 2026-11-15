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

/// A queue-confined `L2CAPPublishing` backend that a test drives event by event. A publish
/// succeeds on PSM 0x0080. An unpublish delivers nothing until the test calls ``deliver(_:)``.
private final class ScriptedPublisher: L2CAPPublishing, Sendable {
    let queue: DispatchQueue
    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _radioState: CentralState = .poweredOn

    init(queue: DispatchQueue) { self.queue = queue }

    var eventHandler: ((PeripheralHostEvent) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _eventHandler }
        set { dispatchPrecondition(condition: .onQueue(queue)); _eventHandler = newValue }
    }
    var radioState: CentralState { dispatchPrecondition(condition: .onQueue(queue)); return _radioState }
    var isAdvertising: Bool { false }
    static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }
    func startAdvertising(_ advertisement: PeripheralAdvertisement) {}
    func stopAdvertising() {}
    func add(_ service: GATTService) {}
    func removeAllHostedServices() {}
    func respond(to token: RequestToken, value: Data?, error: ATTError?) {}
    func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool { true }

    /// When `true`, a publish delivers nothing until the test calls ``deliver(_:)``. Set it on
    /// ``queue``.
    nonisolated(unsafe) var holdsPublishes = false
    nonisolated(unsafe) private var _publishCalls = 0

    func publishL2CAPChannel(requiresEncryption: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        _publishCalls += 1
        guard !holdsPublishes else { return }
        queue.async { [self] in _eventHandler?(.didPublishL2CAPChannel(psm: L2CAPPSM(0x0080), error: nil)) }
    }

    /// The number of publish calls so far.
    func publishCalls() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            queue.async { [self] in continuation.resume(returning: _publishCalls) }
        }
    }

    nonisolated(unsafe) private var _unpublishCalls = 0

    func unpublishL2CAPChannel(_ psm: L2CAPPSM) {
        dispatchPrecondition(condition: .onQueue(queue))
        _unpublishCalls += 1
    }

    /// The number of unpublish calls so far.
    func unpublishCalls() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            queue.async { [self] in continuation.resume(returning: _unpublishCalls) }
        }
    }

    /// Delivers `event` asynchronously on ``queue``. A state change also updates the radio state.
    func deliver(_ event: PeripheralHostEvent) {
        queue.async { [self] in
            if case .didUpdateState(let state) = event { _radioState = state }
            _eventHandler?(event)
        }
    }

    /// Runs an empty block on ``queue``, so every delivery that is already scheduled has run.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }
}

/// A host over a ``ScriptedPublisher`` that has seen `.poweredOn`.
private func makeScriptedHost() async -> (PeripheralHost, ScriptedPublisher) {
    let queue = DispatchQueue(label: "BLESwiftTests.ScriptedPublisher")
    let backend = ScriptedPublisher(queue: queue)
    let host = PeripheralHost(backend: backend, queue: queue)
    backend.deliver(.didUpdateState(.poweredOn))
    await backend.flush()
    return (host, backend)
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

    @Test("A cancelled publish keeps its place: its failure is ignored, and the next caller gets the next success")
    func cancelledPublishKeepsItsPlace() async throws {
        let (host, fake, _) = await makePoweredOnHost()
        await fake.onQueue { fake.publishBehavior = .hold }

        let first = Task { try await host.publishL2CAPChannel() }
        await waitForPublishCalls(fake, count: 1)
        let second = Task { try await host.publishL2CAPChannel() }
        await waitForPublishCalls(fake, count: 2)
        first.cancel()
        await #expect(throws: BLESwiftError.operationCancelled) {
            _ = try await first.value
        }

        // The first event belongs to the cancelled call. The second event belongs to the second
        // call.
        fake.simulatePublishResult(psm: nil, error: NSError(domain: "BLESwiftTests", code: 1))
        fake.simulatePublishResult(psm: L2CAPPSM(0x0081), error: nil)

        #expect(try await second.value == L2CAPPSM(0x0081))
        #expect(await fake.onQueue { fake.unpublishL2CAPChannelCalls }.isEmpty)
    }

    @Test("Power off fails a pending unpublish with .bluetoothUnavailable")
    func powerOffFailsPendingUnpublish() async throws {
        let (host, backend) = await makeScriptedHost()
        let psm = try await host.publishL2CAPChannel()

        let unpublish = Task { try await host.unpublishL2CAPChannel(psm) }
        // The scripted backend never answers an unpublish. Wait until the host has made the call.
        await waitFor { await backend.unpublishCalls() == 1 }
        backend.deliver(.didUpdateState(.poweredOff))

        await #expect(throws: BLESwiftError.bluetoothUnavailable) {
            try await unpublish.value
        }
    }

    @Test("A failed unpublish keeps the PSM published, unless the error is code 12")
    func failedUnpublishKeepsThePSM() async throws {
        let (host, backend) = await makeScriptedHost()
        let psm = try await host.publishL2CAPChannel()

        let failure = NSError(domain: "BLESwiftTests", code: 5)
        let first = Task { try await host.unpublishL2CAPChannel(psm) }
        await waitFor { await backend.unpublishCalls() == 1 }
        backend.deliver(.didUnpublishL2CAPChannel(psm: psm, error: failure))
        await #expect(throws: failure) { try await first.value }

        // The PSM is still published, so a second unpublish reaches the backend.
        let notPublished = NSError(domain: "BLESwiftProvider", code: 12)
        let second = Task { try await host.unpublishL2CAPChannel(psm) }
        await waitFor { await backend.unpublishCalls() == 2 }
        backend.deliver(.didUnpublishL2CAPChannel(psm: psm, error: notPublished))
        await #expect(throws: notPublished) { try await second.value }

        // Code 12 says that nothing is published, so the host forgets the PSM.
        await #expect(throws: BLESwiftError.invalidArgument("PSM \(psm.rawValue) is not published")) {
            try await host.unpublishL2CAPChannel(psm)
        }
    }

    @Test("A failed open that carries a channel closes the channel")
    func failedOpenClosesItsChannel() async throws {
        let (host, backend) = await makeScriptedHost()
        let stream = await host.incomingL2CAPChannels()
        let channel = FakeL2CAPChannel(psm: L2CAPPSM(0x0080), queue: backend.queue)

        backend.deliver(.didOpenL2CAPChannel(channel: channel, central: UUID(), error: NSError(domain: "BLESwiftTests", code: 2)))
        await backend.flush()

        #expect(await channel.onQueue { channel.isClosed })
        withExtendedLifetime(stream) {}
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

    @Test("An incoming channel is closed when every stream was released, and kept when a stream that is not iterated yet exists")
    func incomingChannelCountsTakenStreams() async throws {
        let (host, fake, queue) = await makePoweredOnHost()

        // A stream that the code created and released takes nothing.
        do {
            let released = await host.incomingL2CAPChannels()
            withExtendedLifetime(released) {}
        }
        let first = FakeL2CAPChannel(psm: L2CAPPSM(0x0080), queue: queue)
        fake.simulateIncomingL2CAPChannel(first, central: UUID())
        await fake.onQueue {}
        #expect(await first.onQueue { first.isClosed })

        // A stream that exists and is not iterated yet takes the channel and buffers it.
        let waiting = await host.incomingL2CAPChannels()
        let second = FakeL2CAPChannel(psm: L2CAPPSM(0x0080), queue: queue)
        fake.simulateIncomingL2CAPChannel(second, central: UUID())
        await fake.onQueue {}
        #expect(await second.onQueue { !second.isClosed })
        var iterator = waiting.makeAsyncIterator()
        #expect(await iterator.next()?.psm == L2CAPPSM(0x0080))
    }

    @Test("An incoming channel is closed when its only consumer stopped iterating")
    func incomingChannelAfterConsumerStopped() async throws {
        let (host, fake, queue) = await makePoweredOnHost()
        let stream = await host.incomingL2CAPChannels()
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        _ = await consumer.value

        let channel = FakeL2CAPChannel(psm: L2CAPPSM(0x0080), queue: queue)
        fake.simulateIncomingL2CAPChannel(channel, central: UUID())
        await fake.onQueue {}
        #expect(await channel.onQueue { channel.isClosed })
    }

    @Test("A failed unpublish that power-off already failed does not restore the PSM")
    func lateFailedUnpublishDoesNotRestore() async throws {
        let (host, backend) = await makeScriptedHost()
        let psm = try await host.publishL2CAPChannel()
        let unpublish = Task { try await host.unpublishL2CAPChannel(psm) }
        await waitFor { await backend.unpublishCalls() == 1 }
        backend.deliver(.didUpdateState(.poweredOff))
        await #expect(throws: BLESwiftError.bluetoothUnavailable) { try await unpublish.value }

        // The backend answers late, with an error that would restore the PSM for a live call.
        backend.deliver(.didUnpublishL2CAPChannel(psm: psm, error: NSError(domain: "BLESwiftTests", code: 5)))
        backend.deliver(.didUpdateState(.poweredOn))
        await backend.flush()

        await #expect(throws: BLESwiftError.invalidArgument("PSM \(psm.rawValue) is not published")) {
            try await host.unpublishL2CAPChannel(psm)
        }
    }

    @Test("A cancelled unpublish that then fails restores the PSM, unless the error is code 12")
    func cancelledUnpublishTombstone() async throws {
        let (host, fake, _) = await makePoweredOnHost()
        let psm = try await host.publishL2CAPChannel()
        await fake.onQueue { fake.unpublishBehavior = .hold }

        // Cancel an unpublish, then let it fail with a retryable error. The PSM is still
        // published, so the host keeps it.
        let first = Task { try await host.unpublishL2CAPChannel(psm) }
        await waitFor { await fake.onQueue { fake.unpublishL2CAPChannelCalls.count == 1 } }
        first.cancel()
        await #expect(throws: BLESwiftError.operationCancelled) { try await first.value }
        fake.simulateUnpublishResult(psm: psm, error: NSError(domain: "BLESwiftTests", code: 5))
        await fake.onQueue {}

        // Cancel a second unpublish, then let it fail with code 12. Nothing is published, so
        // the host forgets the PSM.
        let second = Task { try await host.unpublishL2CAPChannel(psm) }
        await waitFor { await fake.onQueue { fake.unpublishL2CAPChannelCalls.count == 2 } }
        second.cancel()
        await #expect(throws: BLESwiftError.operationCancelled) { try await second.value }
        fake.simulateUnpublishResult(psm: psm, error: NSError(domain: "BLESwiftProvider", code: 12))
        await fake.onQueue {}

        await #expect(throws: BLESwiftError.invalidArgument("PSM \(psm.rawValue) is not published")) {
            try await host.unpublishL2CAPChannel(psm)
        }
        #expect(await fake.onQueue { fake.unpublishL2CAPChannelCalls.count } == 2)
    }

    @Test("A failed unpublish of a cancelled publish does not restore the PSM")
    func failedAutoUnpublishDoesNotRestore() async throws {
        let (host, backend) = await makeScriptedHost()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            backend.queue.async { backend.holdsPublishes = true; continuation.resume() }
        }
        let publish = Task { try await host.publishL2CAPChannel() }
        await waitFor { await backend.publishCalls() == 1 }
        publish.cancel()
        await #expect(throws: BLESwiftError.operationCancelled) { _ = try await publish.value }

        // The publish of the cancelled call succeeds, so the host unpublishes the PSM by itself.
        backend.deliver(.didPublishL2CAPChannel(psm: L2CAPPSM(0x0080), error: nil))
        await waitFor { await backend.unpublishCalls() == 1 }
        #expect(await backend.unpublishCalls() == 1)
        backend.deliver(.didUnpublishL2CAPChannel(psm: L2CAPPSM(0x0080), error: NSError(domain: "BLESwiftTests", code: 5)))
        await backend.flush()

        await #expect(throws: BLESwiftError.invalidArgument("PSM \(0x0080) is not published")) {
            try await host.unpublishL2CAPChannel(L2CAPPSM(0x0080))
        }
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
