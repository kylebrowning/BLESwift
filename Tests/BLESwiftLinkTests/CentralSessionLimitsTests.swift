//
//  CentralSessionLimitsTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
@testable import BLESwiftSimulatorLink
import BLESwiftTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

/// What a central-role session refuses to hold on a misbehaving client's behalf.
@Suite("Central session limits")
struct CentralSessionLimitsTests {

    private static let deviceID = UUID(uuidString: "2C7F9A11-4E3B-4D5A-9C8E-7F6A5B4C3D2E")!
    private static let service = ServiceIdentifier(uuid: "180D")
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: service)

    /// A `Sendable` hand-off for the `FakePeripheral` the backend factory builds on the
    /// session's queue.
    private final class PeripheralBox: Sendable {
        private let storage = Mutex<FakePeripheral?>(nil)
        var peripheral: FakePeripheral? { storage.withLock { $0 } }
        func store(_ peripheral: FakePeripheral) { storage.withLock { $0 = peripheral } }
    }

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are unreliable; the simulator-side path is covered by the
    // two-simulator E2E on real simulators.

    @Test("A client that queues past the write window loses its session")
    func writeWindowOverrunClosesTheSession() async throws {
        let fakeBox = PeripheralBox()
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            // Back-pressured from the start: nothing this client queues is ever drained, so
            // the queue grows exactly as fast as the client fills it.
            let peripheral = FakePeripheral(
                identifier: Self.deviceID,
                name: "Fake",
                canSendWriteWithoutResponse: false,
                queue: queue
            )
            fake.retrievablePeripherals[Self.deviceID] = peripheral
            fake.connectBehavior = .succeed
            fakeBox.store(peripheral)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchSerialQueue(label: "centralsession.writewindow")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "greedy",
            retryInterval: .seconds(30)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        _ = try await central.connect(PeripheralIdentifier(uuid: Self.deviceID, name: "Fake"))
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        #expect(await provider.sessionCount == 1)

        // Straight down the link, behind `Peripheral`'s back: its own writer honors the
        // window, which is the whole point — only a client that has stopped honoring it can
        // reach this.
        let overrun = CentralSession.maximumPendingWrites + 1
        let reference = Self.control
        queue.async {
            for sequence in 0..<overrun {
                link.send(.writeValue(
                    peripheral: Self.deviceID,
                    characteristic: WireCharacteristicRef(reference),
                    value: Data([0x01]),
                    type: .withoutResponse,
                    sequence: UInt64(sequence)
                ))
            }
        }

        // The session goes, rather than the provider's memory.
        await waitFor(timeout: .seconds(10)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)

        link.shutdown()
        await provider.stop()
    }
#endif
}
#endif
