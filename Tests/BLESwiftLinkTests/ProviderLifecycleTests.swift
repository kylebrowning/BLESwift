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

/// What the provider leaves on a shared radio when its own lifecycle is interrupted.
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

}
#endif
