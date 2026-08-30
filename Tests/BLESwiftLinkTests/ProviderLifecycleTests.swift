//
//  ProviderLifecycleTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
import Dispatch
import Foundation
import Synchronization
import Testing

/// What the provider leaves on a shared radio when its own lifecycle is interrupted — a
/// `stop()` racing a registration, and a `start()` whose listener never binds.
@Suite("Provider lifecycle")
struct ProviderLifecycleTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)

    /// A handler that answers nothing: these tests are about registration, not GATT.
    private struct InertHandler: VirtualDeviceHandler {
        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.unlikelyError)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .failure(.unlikelyError)
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
    }

    /// A device to hand ``Provider/addVirtualDevice(_:advertising:)``.
    private static func device(identifier: UUID) -> VirtualDevice {
        VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: identifier,
                name: "Lifecycle",
                advertisement: AdvertisementData(localName: "Lifecycle", serviceUUIDs: [service], isConnectable: true),
                services: [
                    GATTService(identifier: service, characteristics: [
                        GATTCharacteristic(identifier: measurement, properties: [.read], permissions: [.readable])
                    ])
                ]
            ),
            handler: InertHandler()
        )
    }

    /// The JSON for one fixture device under `identifier`.
    private static func fixtureJSON(_ identifier: UUID) -> String {
        """
        {
          "devices": [
            {
              "id": "\(identifier.uuidString)",
              "name": "Fixture Lifecycle",
              "advertisedServices": ["180D"],
              "services": [
                {
                  "uuid": "180D",
                  "characteristics": [
                    { "uuid": "2A37", "properties": ["read"], "value": "AEg=" }
                  ]
                }
              ]
            }
          ]
        }
        """
    }

    /// A one-way flag two tasks can hand off on, polled rather than continued: a handler may
    /// be called more than once, and a continuation resumed twice traps.
    private final class Latch: Sendable {
        private let flag = Mutex(false)

        /// Whether ``signal()`` has been called.
        var isSet: Bool { flag.withLock { $0 } }

        func signal() { flag.withLock { $0 = true } }

        /// Suspends — never blocks — until ``signal()`` has been called.
        func wait() async {
            while !isSet {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    /// A handler that parks its device's *removal* until a test releases it, announcing on
    /// ``entered`` that it has been reached.
    ///
    /// Suspends rather than blocking: a handler that slept its thread would starve a
    /// cooperative pool of one, which is exactly what `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`
    /// gives it. The subscribe that plants the subscription passes straight through — only
    /// the unsubscribe a removal reports parks.
    private struct ParkingHandler: VirtualDeviceHandler {
        let entered: Latch
        let release: Latch

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.unlikelyError)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .failure(.unlikelyError)
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
            guard !isSubscribed else { return }
            entered.signal()
            await release.wait()
        }
    }

    @Test("A stop() that lands across addVirtualDevice leaves no device on the radio")
    func addVirtualDeviceRacingStopLeavesNothingRegistered() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let radio = provider.radio

        // A device whose removal parks: `stop()` reports its subscription as an unsubscribe
        // and waits for the handler, which holds the stop — with the provider's own actor
        // released — right between emptying the tables and finishing.
        let entered = Latch()
        let release = Latch()
        let blockerID = UUID()
        let blocker = VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: blockerID,
                name: "Blocker",
                advertisement: AdvertisementData(localName: "Blocker", serviceUUIDs: [Self.service], isConnectable: true),
                services: [
                    GATTService(identifier: Self.service, characteristics: [
                        GATTCharacteristic(identifier: Self.measurement, properties: [.read, .notify], permissions: [.readable])
                    ])
                ]
            ),
            handler: ParkingHandler(entered: entered, release: release)
        )
        await provider.addVirtualDevice(blocker)
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        #expect(await radio.connect(session: session, device: blockerID, sink: { _ in }).error == nil)
        #expect(await radio.setNotify(true, device: blockerID, characteristic: Self.measurement, session: session).isNotifying)

        let stopping = Task { await provider.stop() }
        try await bounded(seconds: 5) { await entered.wait() }

        // Served while the stop is parked: the tables this records into are emptied behind it,
        // so the device would be left on a radio another provider may share, with nothing
        // holding its handle and its identifier no longer defended.
        let identifier = UUID()
        _ = try await bounded { await provider.addVirtualDevice(Self.device(identifier: identifier)) }

        release.signal()
        _ = try await bounded { await stopping.value }

        // The radio is left as the provider found it.
        await waitFor(timeout: .seconds(5)) { !radio.knownDeviceIDs.withLock { $0.contains(identifier) } }
        #expect(!radio.knownDeviceIDs.withLock { $0.contains(identifier) })
        #expect(!radio.knownDeviceIDs.withLock { $0.contains(blockerID) })

        await radio.detach(session: session)
    }

    @Test("A second stop() returning cannot clear the window an add began inside")
    func addVirtualDeviceInsideOverlappingStopsLeavesNothingRegistered() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let radio = provider.radio

        let entered = Latch()
        let release = Latch()
        let blockerID = UUID()
        let blocker = VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: blockerID,
                name: "Blocker",
                advertisement: AdvertisementData(localName: "Blocker", serviceUUIDs: [Self.service], isConnectable: true),
                services: [
                    GATTService(identifier: Self.service, characteristics: [
                        GATTCharacteristic(identifier: Self.measurement, properties: [.read, .notify], permissions: [.readable])
                    ])
                ]
            ),
            handler: ParkingHandler(entered: entered, release: release)
        )
        await provider.addVirtualDevice(blocker)
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        #expect(await radio.connect(session: session, device: blockerID, sink: { _ in }).error == nil)
        #expect(await radio.setNotify(true, device: blockerID, characteristic: Self.measurement, session: session).isNotifying)

        // The long stop, parked reporting the blocker's subscription as an unsubscribe. The
        // latch is what makes the rest of this ordering a fact rather than a hope: everything
        // below happens inside this stop's window.
        let long = Task { await provider.stop() }
        try await bounded(seconds: 5) { await entered.wait() }

        // The short stop runs to completion inside it — the blocker is already off the radio,
        // so it has nothing to wait for. A window tracked by a flag is now closed, though the
        // stop that opened it has not returned.
        _ = try await bounded { await provider.stop() }

        // And only now the registration, which therefore begins — and ends — inside a window
        // that is still open.
        let identifier = UUID()
        _ = try await bounded { await provider.addVirtualDevice(Self.device(identifier: identifier)) }

        release.signal()
        _ = try await bounded { await long.value }

        // The radio is left as this provider found it.
        await waitFor(timeout: .seconds(5)) { !radio.knownDeviceIDs.withLock { $0.contains(identifier) } }
        #expect(!radio.knownDeviceIDs.withLock { $0.contains(identifier) })
        #expect(!radio.knownDeviceIDs.withLock { $0.contains(blockerID) })

        await radio.detach(session: session)
    }

    @Test("A start() whose listener cannot bind registers no fixtures")
    func aFailedStartRegistersNoFixtures() async throws {
        // A port with a provider already on it: the second bind is refused, which is the
        // documented failure `start()` propagates.
        var occupying = ProviderConfiguration()
        occupying.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let holder = Provider(configuration: occupying)
        try await holder.start()
        let taken = await holder.port

        let identifier = UUID()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: taken)
        configuration.fixtures = try FixtureDocument.parse(Data(Self.fixtureJSON(identifier).utf8)).devices
        let provider = Provider(configuration: configuration)
        await #expect(throws: (any Error).self) { try await provider.start() }

        // Nothing was left behind by the attempt: no device on the shared radio, and no
        // handle vended for one — a handle from a failed start would be refused by the
        // radio's generation guard the moment a retry re-registered the fixture.
        #expect(await provider.handle(for: identifier) == nil)
        #expect(!provider.radio.knownDeviceIDs.withLock { $0.contains(identifier) })

        // The retry, on a port that is free, is what registers the fixture and vends the
        // handle that drives it.
        await holder.stop()
        var retry = ProviderConfiguration()
        retry.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        retry.fixtures = configuration.fixtures
        let second = Provider(configuration: retry)
        try await second.start()
        #expect(await second.handle(for: identifier) != nil)
        #expect(second.radio.knownDeviceIDs.withLock { $0.contains(identifier) })
        await second.stop()
    }
}
#endif
