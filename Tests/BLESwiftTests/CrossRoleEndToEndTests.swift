//
//  CrossRoleEndToEndTests.swift
//  BLESwiftTests
//

import Dispatch
import Foundation
import BLESwiftCompat17
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// A cross-role end-to-end test in one process, without hardware. A real ``PeripheralHost``
/// (peripheral role) and a real ``Central`` (central role) have a full GATT conversation over
/// fakes. A ``FakeGATTBridge`` connects the two fake families, which could not connect on their
/// own. The hosted database, responses, and notifications of a ``FakePeripheralManager`` become
/// observable to a ``FakeCentral`` and ``FakePeripheral``. The test covers the whole round trip:
/// - The peripheral hosts a service.
/// - The central connects, discovers, reads, and writes.
/// - The peripheral answers.
/// - The peripheral notifies.
/// - The central receives the notification.
///
/// The test uses no CoreBluetooth and no radio. It is deterministic: delivery is confined to
/// queues, and the test uses `waitFor` on observable state instead of sleeps.
@Suite("Cross-role end-to-end over fakes")
struct CrossRoleEndToEndTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

    /// A pair of roles in one process: a `Central` and a `PeripheralHost`, with their fakes
    /// connected by a `FakeGATTBridge`.
    private struct Rig {
        let central: Central
        let host: PeripheralHost
        let bridge: FakeGATTBridge
        let fakeCentral: FakeCentral
        let fakePeripheral: FakePeripheral
        let fakeManager: FakePeripheralManager
    }

    /// Builds both roles on their own serial queues and bridges them.
    private func makeRig() async -> Rig {
        // Central role, on its own queue.
        let centralQueue = DispatchQueue(label: "CrossRole.Central")
        let fakeCentral = FakeCentral(queue: centralQueue)
        let fakePeripheral = FakePeripheral(name: "Rig Peripheral", queue: centralQueue)
        let central = Central(backend: fakeCentral, queue: centralQueue)

        // Peripheral role, on a different queue.
        let hostQueue = DispatchQueue(label: "CrossRole.Host")
        let fakeManager = FakePeripheralManager(queue: hostQueue)
        let host = PeripheralHost(backend: fakeManager, queue: hostQueue)

        let bridge = await FakeGATTBridge.make(central: fakeCentral, peripheral: fakePeripheral, manager: fakeManager)
        return Rig(central: central, host: host, bridge: bridge, fakeCentral: fakeCentral, fakePeripheral: fakePeripheral, fakeManager: fakeManager)
    }

    @Test("Peripheral hosts a service; central connects, reads, writes, and receives a notification")
    func fullConversation() async throws {
        let rig = await makeRig()

        // ---- Peripheral role: host a dynamic characteristic and answer requests ----

        // The value that the host serves. A read returns it and a write replaces it. A Mutex lets
        // the two responder tasks (below) share it across their executors.
        let hostedValue = Mutex<Data>(Data([0x00]))

        rig.fakeManager.simulateStateChange(.poweredOn)

        let service = GATTService(identifier: Self.heartRate, characteristics: [
            GATTCharacteristic(
                identifier: Self.measurement,
                properties: [.read, .write, .notify],
                permissions: [.readable, .writeable]
            )
        ])
        try await rig.host.add(service)

        // Subscribe to the request streams BEFORE advertising, because they do not replay. The
        // tasks capture `host` alone. Capturing `rig.host` would capture the whole Rig, which is
        // not Sendable, and Swift 6.3 rejects it when it sends the closure.
        let host = rig.host
        let readResponder = Task { @Sendable in
            for await request in await host.readRequests() {
                await host.respond(to: request, with: .success(hostedValue.withLock { $0 }))
            }
        }
        let writeResponder = Task { @Sendable in
            for await request in await host.writeRequests() {
                for entry in request.entries {
                    hostedValue.withLock { $0 = entry.value }
                }
                await host.respond(to: request, with: .success(()))
            }
        }

        try await rig.host.startAdvertising(
            PeripheralAdvertisement(localName: "Rig Peripheral", serviceUUIDs: [Self.heartRate])
        )

        // ---- Central role: connect, discover, read/write, notify ----

        rig.fakeCentral.simulateStateChange(.poweredOn)
        await rig.fakeCentral.onQueue {
            rig.fakeCentral.retrievablePeripherals[rig.fakePeripheral.identifier] = rig.fakePeripheral
            rig.fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await rig.central.connect(rig.fakePeripheral.peripheralIdentifier)

        // Read: the central's result is the value that the host answered with (its initial 0x00).
        let initial: Data = try await peripheral.read(from: Self.measurement)
        #expect(initial == Data([0x00]))

        // The read made a real round trip through the host, which received it as a ReadRequest
        // attributed to the bridge's subscriber.
        let readRequestCount = await rig.fakeManager.onQueue { rig.fakeManager.respondCalls.count }
        #expect(readRequestCount == 1)

        // Write: it reaches the host's writeRequests() and replaces the hosted value.
        try await peripheral.write(Data([0x2A]), to: Self.measurement, type: .withResponse)
        #expect(hostedValue.withLock { $0 } == Data([0x2A]))

        // Read again: it now returns the written value, which proves the write reached the host.
        let afterWrite: Data = try await peripheral.read(from: Self.measurement)
        #expect(afterWrite == Data([0x2A]))

        // Discovery mirrored the hosted properties across the bridge.
        let properties = try await peripheral.properties(of: Self.measurement)
        #expect(properties.contains(.notify))

        // Notify: subscribe on the central. The subscription must show on the host side.
        let notifications: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.measurement)
        let collector = Task { () -> Data? in
            for try await value in notifications { return value }
            return nil
        }

        // Wait until the host has our subscriber before it pushes a notification.
        await waitFor {
            await rig.host.subscribers(for: Self.measurement).contains { $0.id == rig.bridge.subscriber.id }
        }

        // The host pushes a notification. The central receives it as a stream value.
        try await rig.host.updateValue(Data([0x99]), for: Self.measurement)

        let received = try await collector.value
        #expect(received == Data([0x99]))

        // ---- Teardown ----
        readResponder.cancel()
        writeResponder.cancel()
    }
}
