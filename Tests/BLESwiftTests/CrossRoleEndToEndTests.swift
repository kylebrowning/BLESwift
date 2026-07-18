//
//  CrossRoleEndToEndTests.swift
//  BLESwiftTests
//

import Dispatch
import Foundation
import Synchronization
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// A hardware-free, single-process **cross-role** end-to-end test: a real ``PeripheralHost``
/// (peripheral role) and a real ``Central`` (central role) hold a full GATT conversation over
/// nothing but the fakes, interconnected by a ``FakeGATTBridge``.
///
/// This is the interconnection the two fake families could not do on their own (issue #11): a
/// ``FakePeripheralManager``'s hosted database, responses, and notifications become observable to
/// a ``FakeCentral``/``FakePeripheral``. The flow exercised is the whole round trip — peripheral
/// hosts a service → central connects, discovers, reads, writes → peripheral answers → peripheral
/// notifies → central receives — with no CoreBluetooth and no radio, and it is deterministic
/// (queue-confined delivery, `waitFor` on observable state rather than sleeps).
@Suite("Cross-role end-to-end over fakes")
struct CrossRoleEndToEndTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

    /// A wired-up pair of roles: a `Central` and a `PeripheralHost` in one process, with a
    /// `FakeGATTBridge` interconnecting their fakes.
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
        // Central role — its own queue.
        let centralQueue = DispatchSerialQueue(label: "CrossRole.Central")
        let fakeCentral = FakeCentral(queue: centralQueue)
        let fakePeripheral = FakePeripheral(name: "Rig Peripheral", queue: centralQueue)
        let central = Central(backend: fakeCentral, queue: centralQueue)

        // Peripheral role — its own, distinct queue.
        let hostQueue = DispatchSerialQueue(label: "CrossRole.Host")
        let fakeManager = FakePeripheralManager(queue: hostQueue)
        let host = PeripheralHost(backend: fakeManager, queue: hostQueue)

        let bridge = await FakeGATTBridge.make(central: fakeCentral, peripheral: fakePeripheral, manager: fakeManager)
        return Rig(central: central, host: host, bridge: bridge, fakeCentral: fakeCentral, fakePeripheral: fakePeripheral, fakeManager: fakeManager)
    }

    @Test("Peripheral hosts a service; central connects, reads, writes, and receives a notification")
    func fullConversation() async throws {
        let rig = await makeRig()

        // ---- Peripheral role: host a dynamic characteristic and answer requests ----

        // The value the host serves. A read returns it; a write replaces it. Held in a Mutex so
        // the two responder tasks (below) can share it across their executors.
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

        // Subscribe to the request streams BEFORE advertising — they do not replay.
        let readResponder = Task {
            for await request in await rig.host.readRequests() {
                await rig.host.respond(to: request, with: .success(hostedValue.withLock { $0 }))
            }
        }
        let writeResponder = Task {
            for await request in await rig.host.writeRequests() {
                for entry in request.entries {
                    hostedValue.withLock { $0 = entry.value }
                }
                await rig.host.respond(to: request, with: .success(()))
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

        // Read: the central's result is the value the host answered with (its initial 0x00).
        let initial: Data = try await peripheral.read(from: Self.measurement)
        #expect(initial == Data([0x00]))

        // The read genuinely round-tripped through the host as a ReadRequest attributed to the
        // bridge's subscriber.
        let readRequestCount = await rig.fakeManager.onQueue { rig.fakeManager.respondCalls.count }
        #expect(readRequestCount == 1)

        // Write: reaches the host's writeRequests() and replaces the hosted value.
        try await peripheral.write(Data([0x2A]), to: Self.measurement, type: .withResponse)
        #expect(hostedValue.withLock { $0 } == Data([0x2A]))

        // Read again: now reflects the written value, proving the write reached the host.
        let afterWrite: Data = try await peripheral.read(from: Self.measurement)
        #expect(afterWrite == Data([0x2A]))

        // Discovery mirrored the hosted properties across the bridge.
        let properties = try await peripheral.properties(of: Self.measurement)
        #expect(properties.contains(.notify))

        // Notify: subscribe on the central; the subscription must surface on the host side.
        let notifications: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.measurement)
        let collector = Task { () -> Data? in
            for try await value in notifications { return value }
            return nil
        }

        // Wait until the host actually has our subscriber before pushing a notification.
        await waitFor {
            await rig.host.subscribers(for: Self.measurement).contains { $0.id == rig.bridge.subscriber.id }
        }

        // Host pushes a notification; the central receives it as a stream value.
        try await rig.host.updateValue(Data([0x99]), for: Self.measurement)

        let received = try await collector.value
        #expect(received == Data([0x99]))

        // ---- Teardown ----
        readResponder.cancel()
        writeResponder.cancel()
    }
}
