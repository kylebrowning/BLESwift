//
//  VirtualPeripheralManagerTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftProvider
import Dispatch
import Foundation
import Synchronization
import Testing

/// Sim-to-sim in one process: a real `PeripheralHost` driven by a
/// ``VirtualPeripheralManagerBackend`` and a real `Central` driven by a
/// ``VirtualCentralBackend``, both served by one ``VirtualRadio``, holding a full GATT
/// conversation with no CoreBluetooth and no hardware.
///
/// The peripheral-role mirror of `CrossRoleEndToEndTests.fullConversation`, with the virtual
/// radio standing in for the fake bridge.
@Suite("VirtualPeripheralManagerBackend")
struct VirtualPeripheralManagerTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: heartRate)

    /// The Heart Rate service the host publishes: a dynamic, readable/notifying measurement
    /// and a write-only control point.
    private static var service: GATTService {
        GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable]),
            GATTCharacteristic(identifier: control, properties: [.write], permissions: [.writeable])
        ])
    }

    @Test("Host publishes and advertises; central scans, connects, reads, writes, and is notified")
    func fullConversation() async throws {
        let radio = VirtualRadio()

        // ---- Peripheral role: its own queue, backed by the radio ----
        let hostQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.Host")
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue),
            queue: hostQueue
        )
        try await host.add(Self.service)

        // Subscribe to the request streams BEFORE advertising — they do not replay.
        let written = Mutex<Data?>(nil)
        let readResponder = Task { @Sendable in
            for await request in await host.readRequests() {
                await host.respond(to: request, with: .success(Data([0, 72])))
            }
        }
        let writeResponder = Task { @Sendable in
            for await request in await host.writeRequests() {
                written.withLock { $0 = request.entries.first?.value }
                await host.respond(to: request, with: .success(()))
            }
        }

        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Virtual HRM", serviceUUIDs: [Self.heartRate])
        )
        #expect(host.isAdvertising)

        // ---- Central role: a different queue, same radio ----
        let centralQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.Central")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await waitFor { central.state == .poweredOn }

        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(2)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        let discovery = try #require(found)
        #expect(discovery.advertisement.localName == "Virtual HRM")
        #expect(discovery.advertisement.serviceUUIDs == [Self.heartRate])

        let peripheral = try await central.connect(discovery.peripheral)

        // Read: answered by the host's `readRequests()` responder, not by any stored value.
        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 72]))

        // Write: reaches the host's `writeRequests()`, which acknowledges it.
        try await peripheral.write(Data([0x2A]), to: Self.control)
        #expect(written.withLock { $0 } == Data([0x2A]))

        // Notify: subscribing must surface on the host side as a real subscriber.
        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.measurement) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // `Peripheral` exposes no public "notifications are armed" signal, so the brief's
        // permitted fixed-delay fallback stands in for one.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !host.subscribers(for: Self.measurement).isEmpty)
        try await host.updateValue(Data([0, 99]), for: Self.measurement)
        #expect(try await bounded { try await notifications.value } == Data([0, 99]))

        try await central.disconnect(peripheral.id)

        // ---- Teardown: once the host stops advertising, a fresh scan finds nothing ----
        await host.stopAdvertising()
        // Same fixed-delay fallback: `stopAdvertising()` reaches the radio asynchronously and
        // reports no completion of its own.
        try await Task.sleep(for: .milliseconds(100))
        var again: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(1)) {
            if case .discovered(let discovery) = event { again = discovery; break }
        }
        #expect(again == nil)

        readResponder.cancel()
        writeResponder.cancel()
    }

    @Test("A read with no event handler attached fails promptly instead of parking forever")
    func readWithNoHandlerAttached() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.OrphanHost")
        let identifier = UUID()
        let backend = VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, identifier: identifier)
        let host = PeripheralHost(backend: backend, queue: hostQueue)
        try await host.add(Self.service)

        // Drop the handler *without* removing the device — the one state in which a request
        // would otherwise be parked with nothing left to answer it.
        await backend.detachEventHandlerForTesting()

        let centralQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.OrphanCentral")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await waitFor { central.state == .poweredOn }

        // The device is registered but never advertised, so connect by identifier.
        let peripheral = try await central.connect(PeripheralIdentifier(uuid: identifier, name: nil))
        do {
            let value: Data = try await peripheral.read(from: Self.measurement)
            Issue.record("Expected the read to fail, got \(value as NSData)")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "CBATTErrorDomain")
            #expect(nsError.code == ATTError.unlikelyError.rawValue)
        }
    }

    @Test("A host's ATT failure surfaces to the central as a CBATTErrorDomain error")
    func readFailure() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.FailingHost")
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue),
            queue: hostQueue
        )
        try await host.add(Self.service)

        let readResponder = Task { @Sendable in
            for await request in await host.readRequests() {
                await host.respond(to: request, with: .failure(.readNotPermitted))
            }
        }
        try await host.startAdvertising(PeripheralAdvertisement(localName: "Grumpy HRM", serviceUUIDs: [Self.heartRate]))

        let centralQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.FailingCentral")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await waitFor { central.state == .poweredOn }

        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(2)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        let peripheral = try await central.connect(try #require(found).peripheral)

        do {
            let value: Data = try await peripheral.read(from: Self.measurement)
            Issue.record("Expected the read to fail, got \(value as NSData)")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "CBATTErrorDomain")
            #expect(nsError.code == ATTError.readNotPermitted.rawValue)
        }

        readResponder.cancel()
    }

    @Test("The advertised local name becomes the discovered peripheral's name")
    func advertisedLocalNameBecomesPeripheralName() async throws {
        let radio = VirtualRadio()

        // Registered under a placeholder name, the way `Provider` names a host session's
        // device after its link client. CoreBluetooth reports the *advertised* local name, and
        // so must the radio: otherwise a scanner sees the placeholder, not the advertiser.
        let hostQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.RenamedHost")
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, name: "PlaceholderClient"),
            queue: hostQueue
        )
        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Renamed", serviceUUIDs: [Self.heartRate])
        )

        let centralQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.RenamedCentral")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await waitFor { central.state == .poweredOn }

        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(2)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        let discovery = try #require(found)
        #expect(discovery.peripheral.name == "Renamed")
        #expect(discovery.advertisement.localName == "Renamed")
    }
}
#endif
