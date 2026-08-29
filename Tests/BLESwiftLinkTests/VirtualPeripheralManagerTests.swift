//
//  VirtualPeripheralManagerTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
@testable import BLESwiftProvider
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

    @Test("A request the host never answers times out, and the remote keeps working")
    func unansweredRequestTimesOut() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.SilentHost")
        let identifier = UUID()
        // A short stand-in for `VirtualRadio.attTimeout`, so the test need not wait 30 s.
        let backend = VirtualPeripheralManagerBackend(
            radio: radio,
            queue: hostQueue,
            identifier: identifier,
            attTimeout: .milliseconds(200)
        )
        let host = PeripheralHost(backend: backend, queue: hostQueue)
        try await host.add(Self.service)

        // The first read is swallowed — a host wedged in its own handler — and every one
        // after it is answered.
        let seen = Mutex<Int>(0)
        let readResponder = Task { @Sendable in
            for await request in await host.readRequests() {
                let ordinal = seen.withLock { $0 += 1; return $0 }
                guard ordinal > 1 else { continue }
                await host.respond(to: request, with: .success(Data([0, 72])))
            }
        }

        let centralQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.SilentCentral")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await waitFor { central.state == .poweredOn }
        let peripheral = try await central.connect(PeripheralIdentifier(uuid: identifier, name: nil))

        do {
            let value: Data = try await peripheral.read(from: Self.measurement)
            Issue.record("Expected the unanswered read to time out, got \(value as NSData)")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "CBATTErrorDomain")
            #expect(nsError.code == ATTError.unlikelyError.rawValue)
        }

        // The timed-out request released the remote's serial chain: the next read still works.
        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 72]))
        #expect(seen.withLock { $0 } == 2)

        readResponder.cancel()
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

    // MARK: - Departing subscribers

    /// Runs `body` on `queue` and returns its result, without blocking a cooperative thread.
    private static func onQueue<T: Sendable>(
        _ queue: DispatchSerialQueue,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// A hosted `PeripheralHost` on `radio` publishing ``service``, with an observer already
    /// attached to its subscription events.
    ///
    /// The stream is created *before* this returns — `subscriptionEvents()` does not replay,
    /// so an observer started behind the first subscribe would miss it.
    private static func hostRig(
        radio: VirtualRadio,
        label: String,
        identifier: UUID
    ) async throws -> (host: PeripheralHost, log: SubscriptionLog, observer: Task<Void, Never>) {
        let hostQueue = DispatchSerialQueue(label: label)
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, identifier: identifier),
            queue: hostQueue
        )
        try await host.add(Self.service)
        let log = SubscriptionLog()
        let stream = await host.subscriptionEvents()
        let observer = Task { for await event in stream { log.append(event) } }
        return (host, log, observer)
    }

    /// Connects `backend` to `identifier` and subscribes it to ``measurement``, returning the
    /// remote so each test can control exactly how that central departs.
    ///
    /// The backend is driven directly rather than through a `Central`: a notification stream
    /// unsubscribes when it terminates, which is the one thing these tests must *not* do.
    private static func subscribedRemote(
        _ backend: VirtualCentralBackend,
        on queue: DispatchSerialQueue,
        to identifier: UUID,
        host: PeripheralHost
    ) async throws -> VirtualPeripheralRemote {
        await waitFor { await onQueue(queue) { !backend.retrievePeripherals(withIdentifiers: [identifier]).isEmpty } }
        let remote = try #require(await onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [identifier]).first as? VirtualPeripheralRemote
        })
        await onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await waitFor { await onQueue(queue) { remote.connectionState == .connected } }
        // Discovered before it is subscribed: a `PeripheralRemote` no-ops a `setNotifyValue`
        // for a characteristic it has not discovered, exactly as CoreBluetooth does.
        await onQueue(queue) {
            remote.discoverServices([Self.heartRate])
            remote.discoverCharacteristics([Self.measurement], for: Self.heartRate)
        }
        await waitFor { await onQueue(queue) { remote.isDiscovered(Self.measurement) } }
        await onQueue(queue) { remote.setNotifyValue(true, for: Self.measurement) }
        await waitFor { await !host.subscribers(for: Self.measurement).isEmpty }
        return remote
    }

    @Test("A subscribed central's disconnect reaches the host as an unsubscribe")
    func disconnectUnsubscribesTheHost() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let (host, log, observer) = try await Self.hostRig(
            radio: radio,
            label: "VirtualPeripheralManagerTests.DisconnectHost",
            identifier: identifier
        )
        defer { observer.cancel() }

        let queue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.DisconnectCentral")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let remote = try await Self.subscribedRemote(backend, on: queue, to: identifier, host: host)
        #expect(await host.subscribers(for: Self.measurement).map(\.id) == [backend.sessionID])

        // The central goes away without unsubscribing first, exactly as a real one does when
        // its connection is cancelled.
        await Self.onQueue(queue) { backend.cancelPeripheralConnection(remote) }

        await waitFor { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        let departure = try #require(log.lastUnsubscribe)
        #expect(departure.central.id == backend.sessionID)
        #expect(departure.characteristic == Self.measurement)
    }

    @Test("A subscribed central's backend going away reaches the host as an unsubscribe")
    func detachedBackendUnsubscribesTheHost() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let (host, log, observer) = try await Self.hostRig(
            radio: radio,
            label: "VirtualPeripheralManagerTests.DetachHost",
            identifier: identifier
        )
        defer { observer.cancel() }

        let queue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.DetachCentral")
        var backend: VirtualCentralBackend? = VirtualCentralBackend(radio: radio, queue: queue)
        let session = try #require(backend?.sessionID)
        var remote: VirtualPeripheralRemote? = try await Self.subscribedRemote(
            try #require(backend),
            on: queue,
            to: identifier,
            host: host
        )
        #expect(await host.subscribers(for: Self.measurement).map(\.id) == [session])

        // Released, not cancelled: `deinit` detaches the session from the radio, and the
        // subscriptions that go with it must still reach the host.
        remote = nil
        backend = nil
        #expect(remote == nil && backend == nil)

        await waitFor { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        let departure = try #require(log.lastUnsubscribe)
        #expect(departure.central.id == session)
        #expect(departure.characteristic == Self.measurement)
    }

    @Test("Removing the hosted device reaches the host as an unsubscribe")
    func removedDeviceUnsubscribesTheHost() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let (host, log, observer) = try await Self.hostRig(
            radio: radio,
            label: "VirtualPeripheralManagerTests.RemoveHost",
            identifier: identifier
        )
        defer { observer.cancel() }

        let queue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.RemoveCentral")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        _ = try await Self.subscribedRemote(backend, on: queue, to: identifier, host: host)
        #expect(await host.subscribers(for: Self.measurement).map(\.id) == [backend.sessionID])

        let generation = try #require(await radio.generation(of: identifier))
        await radio.remove(device: identifier, generation: generation)

        await waitFor { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        let departure = try #require(log.lastUnsubscribe)
        #expect(departure.central.id == backend.sessionID)
        #expect(departure.characteristic == Self.measurement)
    }
}
#endif
