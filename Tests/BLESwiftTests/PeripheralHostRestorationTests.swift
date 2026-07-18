//
//  PeripheralHostRestorationTests.swift
//  BLESwiftTests
//

import BLESwiftCore
import BLESwiftTestSupport
import Dispatch
import Foundation
import Testing
@testable import BLESwift

/// Exercises peripheral-role background restoration (issue #10): `willRestoreState` buffering
/// and replay, the restored services/advertisement surfacing on `restorationEvents()`, and the
/// `isAdvertising` snapshot reflecting a restored advertisement — all driven through
/// `FakePeripheralManager.simulateRestoration`, which delivers `willRestoreState` before the
/// state flip, mirroring CoreBluetooth's guaranteed ordering.
@Suite("PeripheralHost background restoration")
struct PeripheralHostRestorationTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")

    /// A `PeripheralHost` wired to a fresh queue-confined `FakePeripheralManager`, with
    /// peripheral-role restoration enabled via the internal seam (see the dual-access note in
    /// `RestorationConfiguration.swift`).
    private func makeRestorationHost(
        label: String = "BLESwiftTests.FakePeripheralManager.restoration"
    ) -> (PeripheralHost, FakePeripheralManager, DispatchSerialQueue) {
        let queue = DispatchSerialQueue(label: label)
        let fake = FakePeripheralManager(queue: queue)
        var configuration = Configuration()
        configuration.peripheralRestoration = PeripheralRestorationConfiguration(
            identifier: "BLESwiftTests.peripheral.restore"
        )
        let host = PeripheralHost(backend: fake, queue: queue, configuration: configuration)
        return (host, fake, queue)
    }

    /// Collects up to `count` restoration events, giving up (and returning what arrived) after
    /// `timeout` so a missing event fails the test's assertions instead of hanging it. Mirrors
    /// `RestorationTests.collectRestorationEvents`.
    private func collectRestorationEvents(
        _ host: PeripheralHost,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async -> [PeripheralRestorationEvent] {
        let stream = await host.restorationEvents()
        let collector = Task {
            var events: [PeripheralRestorationEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == count { break }
            }
            return events
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            collector.cancel()
        }
        let events = await collector.value
        deadline.cancel()
        return events
    }

    // MARK: - Replay

    @Test("willRestoreState delivered before any subscriber is replayed to the first restorationEvents() consumer")
    func replayToLateSubscriber() async throws {
        let (host, fake, _) = makeRestorationHost()

        let restored = RestoredPeripheralState(
            services: [Self.heartRate],
            advertisement: PeripheralAdvertisement(localName: "Rig", serviceUUIDs: [Self.heartRate])
        )

        // Deliver restoration and power-on BEFORE any subscriber exists — the buffered-replay
        // guarantee is the point of this test. CoreBluetooth delivers willRestoreState before
        // the first didUpdateState; the fake mirrors that ordering. The `onQueue {}` flush
        // ensures both deliveries have run through the actor (and been buffered) before we
        // subscribe.
        fake.simulateRestoration(restored)
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {}

        let events = await collectRestorationEvents(host, count: 1)
        try #require(events.count == 1)
        guard case .willRestore(let replayed) = events[0] else {
            Issue.record("expected .willRestore, got \(events[0])")
            return
        }
        #expect(replayed == restored)
        #expect(replayed.services == [Self.heartRate])
        #expect(replayed.advertisement?.localName == "Rig")
        #expect(replayed.advertisement?.serviceUUIDs == [Self.heartRate])
    }

    @Test("a subscriber already listening receives willRestore live")
    func liveSubscriberReceives() async throws {
        let (host, fake, _) = makeRestorationHost()
        var iterator = await host.restorationEvents().makeAsyncIterator()

        let restored = RestoredPeripheralState(services: [Self.heartRate], advertisement: nil)
        fake.simulateRestoration(restored)

        let event = try #require(await iterator.next())
        guard case .willRestore(let replayed) = event else {
            Issue.record("expected .willRestore, got \(event)")
            return
        }
        #expect(replayed == restored)
    }

    // MARK: - Advertising state

    @Test("a restored advertisement is reflected in the isAdvertising snapshot")
    func restoredAdvertisingReflected() async throws {
        let (host, fake, _) = makeRestorationHost()
        #expect(!host.isAdvertising)

        fake.simulateRestoration(RestoredPeripheralState(
            services: [Self.heartRate],
            advertisement: PeripheralAdvertisement(localName: "Rig", serviceUUIDs: [Self.heartRate])
        ))
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {}

        // CoreBluetooth resumes the restored advertisement itself; BLESwift brings the snapshot
        // back in line without re-issuing startAdvertising (no startAdvertising call recorded).
        #expect(host.isAdvertising)
        #expect(await fake.onQueue { fake.startAdvertisingCallCount } == 0)
    }

    @Test("a restoration with no advertisement leaves isAdvertising false but still surfaces the services")
    func restoredWithoutAdvertisement() async throws {
        let (host, fake, _) = makeRestorationHost()

        let restored = RestoredPeripheralState(services: [Self.heartRate], advertisement: nil)
        fake.simulateRestoration(restored)
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {}

        #expect(!host.isAdvertising)

        let events = await collectRestorationEvents(host, count: 1)
        try #require(events.count == 1)
        guard case .willRestore(let replayed) = events[0] else {
            Issue.record("expected .willRestore, got \(events[0])")
            return
        }
        #expect(replayed.services == [Self.heartRate])
        #expect(replayed.advertisement == nil)
    }
}
