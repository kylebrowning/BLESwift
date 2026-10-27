//
//  InProcessTests.swift
//  BLESwiftVirtualRadioTests
//

import BLESwift
import BLESwiftCore
import BLESwiftVirtualRadio
import Dispatch
import Foundation
import Testing

/// A real `Central` against `VirtualCentralBackend`, in one process and on every platform —
/// the proof that the virtual radio runs on iOS, not only under the macOS provider.
@Suite("In-process virtual radio")
struct InProcessTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: service)

    /// A custom handler: the control point stores what it is written and notifies it back to
    /// every subscriber. Subscription changes are published on a stream, so a test can wait
    /// for the subscription to land instead of sleeping.
    private actor ControlHandler: VirtualDeviceHandler {
        private var handle: VirtualDeviceHandle?
        private(set) var written: [Data] = []
        private var subscribers: [Subscriber] = []
        let subscriptions: AsyncStream<Bool>
        private let subscriptionsContinuation: AsyncStream<Bool>.Continuation

        init() {
            (subscriptions, subscriptionsContinuation) = AsyncStream.makeStream()
        }

        func attach(_ handle: VirtualDeviceHandle) {
            self.handle = handle
        }

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.readNotPermitted)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            for entry in entries {
                written.append(entry.value)
                await handle?.notify(entry.value, for: entry.characteristic, to: nil)
            }
            return .success(())
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
            subscriptionsContinuation.yield(isSubscribed)
        }
    }

    /// Polls `condition` every 5 ms until it is `true` or `timeout` elapses, for the one thing
    /// the public surface offers no event for: the backend reaching `.poweredOn`.
    private func waitFor(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("A Central scans, connects, discovers, reads, writes through a handler, and is notified", .timeLimit(.minutes(1)))
    func fullConversation() async throws {
        let radio = VirtualRadio()
        let handler = ControlHandler()
        let device = VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                name: "In-process HRM",
                advertisement: AdvertisementData(localName: "In-process HRM", serviceUUIDs: [Self.service], isConnectable: true),
                services: [
                    GATTService(identifier: Self.service, characteristics: [
                        GATTCharacteristic(
                            identifier: Self.measurement,
                            properties: [.read],
                            permissions: [.readable],
                            value: Data([0, 72])
                        ),
                        GATTCharacteristic(
                            identifier: Self.control,
                            properties: [.write, .notify],
                            permissions: [.writeable]
                        )
                    ])
                ]
            ),
            handler: handler
        )
        let handle = await radio.register(device)
        await handler.attach(handle)

        let queue = DispatchQueue(label: "InProcessTests.central")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
        await waitFor { central.state == .poweredOn }
        #expect(central.state == .poweredOn)

        var found: Discovery?
        for try await event in await central.scan(services: [Self.service], timeout: .seconds(5)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        let discovery = try #require(found)
        #expect(discovery.peripheral.name == "In-process HRM")
        #expect(discovery.advertisement.serviceUUIDs == [Self.service])

        let peripheral = try await central.connect(discovery.peripheral)
        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 72]))

        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.control) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // The handler hears the subscription once the radio has recorded it, so the write
        // below cannot notify into an empty subscriber table.
        var subscribed = false
        for await isSubscribed in handler.subscriptions {
            subscribed = isSubscribed
            break
        }
        #expect(subscribed)

        try await peripheral.write(Data([0x2A]), to: Self.control)
        #expect(await handler.written == [Data([0x2A])])
        #expect(try await notifications.value == Data([0x2A]))

        try await central.disconnect(peripheral.id)
    }
}
