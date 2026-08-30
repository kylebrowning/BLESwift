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

    /// A handler whose subscription callback takes its time, so removing its device — which
    /// reports every subscription it still had — holds `stop()` at one of its suspension
    /// points for as long as this test needs it held.
    private struct SlowHandler: VirtualDeviceHandler {
        let delay: Duration

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.unlikelyError)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .failure(.unlikelyError)
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
            try? await Task.sleep(for: delay)
        }
    }

    @Test("A stop() that lands across addVirtualDevice leaves no device on the radio")
    func addVirtualDeviceRacingStopLeavesNothingRegistered() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let radio = provider.radio

        // A device that takes its time being removed: `stop()` reports its subscription as an
        // unsubscribe and waits for the handler, which parks the stop — with the provider's
        // own actor released — right between emptying the tables and finishing.
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
            handler: SlowHandler(delay: .milliseconds(500))
        )
        await provider.addVirtualDevice(blocker)
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        #expect(await radio.connect(session: session, device: blockerID, sink: { _ in }).error == nil)
        #expect(await radio.setNotify(true, device: blockerID, characteristic: Self.measurement, session: session).isNotifying)

        let stopping = Task { await provider.stop() }
        try await Task.sleep(for: .milliseconds(150))

        // Served while the stop is suspended: the tables this records into are emptied behind
        // it, so the device would be left on a radio another provider may share, with nothing
        // holding its handle and its identifier no longer defended.
        let identifier = UUID()
        _ = try await bounded { await provider.addVirtualDevice(Self.device(identifier: identifier)) }
        _ = try await bounded { await stopping.value }

        // The radio is left as the provider found it.
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
