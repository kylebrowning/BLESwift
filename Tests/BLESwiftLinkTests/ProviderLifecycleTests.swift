//
//  ProviderLifecycleTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
@testable import BLESwiftVirtualRadio
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// What the provider leaves on a shared radio when something interrupts its own lifecycle, for
/// example a `stop()` that races a registration or a `start()` whose listener never binds.
@Suite("Provider lifecycle")
struct ProviderLifecycleTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)

    /// A handler that answers nothing. These tests are about registration, not GATT.
    private struct InertHandler: VirtualDeviceHandler {
        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.unlikelyError)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .failure(.unlikelyError)
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
    }

    /// A device to hand to ``Provider/addVirtualDevice(_:advertising:)``.
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

    /// A one-way flag that two tasks can hand off on. The code polls it instead of using a
    /// continuation, because a handler may be called more than once and a continuation that resumes
    /// twice traps.
    private final class Latch: Sendable {
        private let flag = Mutex(false)

        /// Whether the code has called ``signal()``.
        var isSet: Bool { flag.withLock { $0 } }

        func signal() { flag.withLock { $0 = true } }

        /// Suspends until the code has called ``signal()``. It never blocks.
        func wait() async {
            while !isSet {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    /// A handler that parks the *removal* of its device until a test releases it. It announces on
    /// ``entered`` that it has been reached.
    ///
    /// The handler suspends and does not block, because a blocked thread would starve the
    /// cooperative pool of one that `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` gives it. The subscribe
    /// passes straight through, and only the unsubscribe that a removal reports parks.
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

        // A device whose removal parks. `stop()` reports its subscription as an unsubscribe and
        // waits for the handler, which holds the stop between emptying the tables and finishing.
        // The provider's own actor is free meanwhile.
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

        // The device is served while the stop is parked, and the stop empties the tables that this
        // records into. The device would then stay on a shared radio with nothing to hold its
        // handle or defend its identifier.
        let identifier = UUID()
        _ = try await bounded { await provider.addVirtualDevice(Self.device(identifier: identifier)) }

        release.signal()
        _ = try await bounded { await stopping.value }

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

        // The long stop is parked and reports the blocker's subscription as an unsubscribe. The
        // latch makes the rest of this ordering a fact. Everything below happens inside this stop's
        // window.
        let long = Task { await provider.stop() }
        try await bounded(seconds: 5) { await entered.wait() }

        // The short stop runs to completion inside it. The blocker is already off the radio, so it
        // has nothing to wait for. A window that a flag tracks is now closed, although the stop
        // that opened it has not returned.
        _ = try await bounded { await provider.stop() }

        // Only now comes the registration. It therefore begins and ends inside a window that is
        // still open.
        let identifier = UUID()
        _ = try await bounded { await provider.addVirtualDevice(Self.device(identifier: identifier)) }

        release.signal()
        _ = try await bounded { await long.value }

        await waitFor(timeout: .seconds(5)) { !radio.knownDeviceIDs.withLock { $0.contains(identifier) } }
        #expect(!radio.knownDeviceIDs.withLock { $0.contains(identifier) })
        #expect(!radio.knownDeviceIDs.withLock { $0.contains(blockerID) })

        await radio.detach(session: session)
    }

    @Test("A start() whose listener cannot bind registers no fixtures")
    func aFailedStartRegistersNoFixtures() async throws {
        // A port with a provider already on it. The second bind is refused. This is the documented
        // failure that `start()` propagates.
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

        // The attempt left nothing behind: no device on the shared radio and no vended handle. The
        // radio's generation guard would refuse a handle from a failed start once a retry
        // registered the fixture again.
        #expect(await provider.handle(for: identifier) == nil)
        #expect(!provider.radio.knownDeviceIDs.withLock { $0.contains(identifier) })

        // The retry, on a port that is free, registers the fixture and vends the handle that drives
        // it.
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
