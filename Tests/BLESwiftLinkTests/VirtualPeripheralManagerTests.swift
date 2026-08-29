//
//  VirtualPeripheralManagerTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
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
        // `Peripheral` publishes no "notifications are armed" signal of its own, so the wait is
        // on the radio's own subscription table — the very state the push consults — and on the
        // host's subscriber list behind it.
        await waitFor(timeout: .seconds(10)) { await radio.isSubscribed(characteristic: Self.measurement) }
        await waitFor(timeout: .seconds(10)) { await !host.subscribers(for: Self.measurement).isEmpty }
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

    @Test("A hosted host that never answers closes the write window, and answering reopens it once")
    func writeWithoutResponseWindowBoundsTheChain() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let hostQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.WindowHost")
        // Long enough that nothing times out while the window is being filled and asserted —
        // the subject here is the window, not the ATT timeout — but far short of the 30 s
        // default, which would leave the writes this test holds parked for the rest of the run.
        let backend = VirtualPeripheralManagerBackend(
            radio: radio,
            queue: hostQueue,
            identifier: identifier,
            attTimeout: .seconds(10)
        )
        let host = PeripheralHost(backend: backend, queue: hostQueue)
        try await host.add(Self.service)

        // A hosted host that is merely slow: every write is held, unanswered, until this test
        // decides to answer it.
        let answering = Mutex<Bool>(false)
        let held = Mutex<[WriteRequest]>([])
        let writeResponder = Task { @Sendable in
            for await request in await host.writeRequests() {
                if answering.withLock({ $0 }) {
                    await host.respond(to: request, with: .success(()))
                } else {
                    held.withLock { $0.append(request) }
                }
            }
        }
        defer { writeResponder.cancel() }

        // The backend is driven directly: `Peripheral`'s own writer honors the window, and the
        // window itself is what is under test.
        let centralQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.WindowCentral")
        let central = VirtualCentralBackend(radio: radio, queue: centralQueue)
        await waitFor { await Self.onQueue(centralQueue) { !central.retrievePeripherals(withIdentifiers: [identifier]).isEmpty } }
        let remote = try #require(await Self.onQueue(centralQueue) {
            central.retrievePeripherals(withIdentifiers: [identifier]).first as? VirtualPeripheralRemote
        })
        let ready = Mutex<Int>(0)
        await Self.onQueue(centralQueue) {
            remote.eventHandler = { event in
                if case .isReadyToSendWriteWithoutResponse = event { ready.withLock { $0 += 1 } }
            }
            central.connect(remote, options: nil, requiresANCS: false)
        }
        await waitFor { await Self.onQueue(centralQueue) { remote.connectionState == .connected } }
        // A service at a time: a characteristic discovery for a service the remote has not
        // discovered yet is a no-op, so the sweep has to land first — the order `Central`
        // issues them in.
        await Self.onQueue(centralQueue) { remote.discoverServices([Self.heartRate]) }
        await waitFor { await Self.onQueue(centralQueue) { remote.isDiscovered(Self.heartRate) } }
        await Self.onQueue(centralQueue) { remote.discoverCharacteristics([Self.control], for: Self.heartRate) }
        await waitFor { await Self.onQueue(centralQueue) { remote.isDiscovered(Self.control) } }

        // ---- Fill the window: the slots are taken synchronously, so this is exact ----
        let window = LinkFlowControl.writeWithoutResponseWindow
        await Self.onQueue(centralQueue) {
            #expect(remote.canSendWriteWithoutResponse)
            for _ in 0..<window {
                remote.writeValue(Data([0x01]), for: Self.control, type: .withoutResponse)
            }
        }
        // The window is shut, so the 65th write parks in `CentralSession.drainWrites` rather
        // than joining an unbounded chain behind a host that has answered none of the first 64.
        #expect(await Self.onQueue(centralQueue) { !remote.canSendWriteWithoutResponse })
        #expect(ready.withLock { $0 } == 0)

        // ---- The host starts answering: the chain drains and the window reopens ----
        answering.withLock { $0 = true }
        await waitFor(timeout: .seconds(10)) {
            for request in held.withLock({ let pending = $0; $0 = []; return pending }) {
                await host.respond(to: request, with: .success(()))
            }
            return await Self.onQueue(centralQueue) { remote.canSendWriteWithoutResponse }
        }
        #expect(await Self.onQueue(centralQueue) { remote.canSendWriteWithoutResponse })
        // Once, on the transition that reopened it — not once per write answered.
        #expect(ready.withLock { $0 } == 1)
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

    @Test("A write to a characteristic declaring no write property never reaches the host")
    func writeToAReadOnlyCharacteristicIsRefusedAtTheRadio() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let hostQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.ReadOnlyHost")
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, identifier: identifier),
            queue: hostQueue
        )
        try await host.add(Self.service)

        // A host that would happily acknowledge anything it is handed: the refusal has to come
        // from the radio's own ATT layer, or this responder answers the write successfully.
        let arrived = Mutex(0)
        let writeResponder = Task { @Sendable in
            for await request in await host.writeRequests() {
                arrived.withLock { $0 += 1 }
                await host.respond(to: request, with: .success(()))
            }
        }
        defer { writeResponder.cancel() }

        // The backend is driven directly: `Peripheral`'s own writer refuses a write to a
        // characteristic that declares no write property before it ever reaches a radio, and
        // the radio's refusal — what real hardware does at the ATT layer, for a host that has
        // no fixture handler to refuse for it — is what is under test.
        let centralQueue = DispatchSerialQueue(label: "VirtualPeripheralManagerTests.ReadOnlyCentral")
        let central = VirtualCentralBackend(radio: radio, queue: centralQueue)
        await waitFor { await Self.onQueue(centralQueue) { !central.retrievePeripherals(withIdentifiers: [identifier]).isEmpty } }
        let remote = try #require(await Self.onQueue(centralQueue) {
            central.retrievePeripherals(withIdentifiers: [identifier]).first as? VirtualPeripheralRemote
        })
        let writes = Mutex<[(CharacteristicIdentifier, NSError?)]>([])
        await Self.onQueue(centralQueue) {
            remote.eventHandler = { event in
                if case .didWriteValue(let characteristic, let error) = event {
                    writes.withLock { $0.append((characteristic, error)) }
                }
            }
            central.connect(remote, options: nil, requiresANCS: false)
        }
        await waitFor { await Self.onQueue(centralQueue) { remote.connectionState == .connected } }
        await Self.onQueue(centralQueue) { remote.discoverServices([Self.heartRate]) }
        await waitFor { await Self.onQueue(centralQueue) { remote.isDiscovered(Self.heartRate) } }
        await Self.onQueue(centralQueue) {
            remote.discoverCharacteristics([Self.measurement, Self.control], for: Self.heartRate)
        }
        await waitFor { await Self.onQueue(centralQueue) { remote.isDiscovered(Self.measurement) } }

        // `measurement` declares `.read` and `.notify` and nothing else, so ATT refuses.
        await Self.onQueue(centralQueue) {
            remote.writeValue(Data([0x2A]), for: Self.measurement, type: .withResponse)
        }
        await waitFor { writes.withLock { !$0.isEmpty } }
        let refused = try #require(writes.withLock { $0.first })
        #expect(refused.0 == Self.measurement)
        #expect(refused.1?.domain == "CBATTErrorDomain")
        #expect(refused.1?.code == ATTError.writeNotPermitted.rawValue)
        #expect(arrived.withLock { $0 } == 0)

        // The writable characteristic on the same device is unaffected: the refusal is the
        // permission check, not a blanket block on writes to this host.
        await Self.onQueue(centralQueue) {
            remote.writeValue(Data([0x2A]), for: Self.control, type: .withResponse)
        }
        await waitFor { writes.withLock { $0.count == 2 } }
        #expect(writes.withLock { $0.last?.1 } == nil)
        #expect(arrived.withLock { $0 } == 1)
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
        host: PeripheralHost,
        radio: VirtualRadio
    ) async throws -> VirtualPeripheralRemote {
        await waitFor { await onQueue(queue) { !backend.retrievePeripherals(withIdentifiers: [identifier]).isEmpty } }
        let remote = try #require(await onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [identifier]).first as? VirtualPeripheralRemote
        })
        await onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await waitFor { await onQueue(queue) { remote.connectionState == .connected } }
        // Discovered before it is subscribed: a `PeripheralRemote` no-ops a `setNotifyValue`
        // for a characteristic it has not discovered, exactly as CoreBluetooth does.
        await onQueue(queue) { remote.discoverServices([Self.heartRate]) }
        await waitFor { await onQueue(queue) { remote.isDiscovered(Self.heartRate) } }
        await onQueue(queue) { remote.discoverCharacteristics([Self.measurement], for: Self.heartRate) }
        await waitFor { await onQueue(queue) { remote.isDiscovered(Self.measurement) } }
        await onQueue(queue) { remote.setNotifyValue(true, for: Self.measurement) }
        // Both halves of the arming, each on a bound a starved runner cannot outrun: the
        // radio's own subscription table — which is what a `remove()` or a disconnect walks —
        // and the host's view of it behind that.
        await waitFor(timeout: .seconds(10)) {
            await radio.isSubscribed(session: backend.sessionID, characteristic: Self.measurement)
        }
        await waitFor(timeout: .seconds(10)) { await !host.subscribers(for: Self.measurement).isEmpty }
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
        let remote = try await Self.subscribedRemote(backend, on: queue, to: identifier, host: host, radio: radio)
        #expect(await host.subscribers(for: Self.measurement).map(\.id) == [backend.sessionID])

        // The central goes away without unsubscribing first, exactly as a real one does when
        // its connection is cancelled.
        await Self.onQueue(queue) { backend.cancelPeripheralConnection(remote) }

        await waitFor(timeout: .seconds(10)) { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        // The log is filled by a task of its own, so the event can still be in flight when the
        // host's list has already emptied.
        await waitFor(timeout: .seconds(10)) { log.lastUnsubscribe != nil }
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
            host: host,
            radio: radio
        )
        #expect(await host.subscribers(for: Self.measurement).map(\.id) == [session])

        // Released, not cancelled: `deinit` detaches the session from the radio, and the
        // subscriptions that go with it must still reach the host.
        remote = nil
        backend = nil
        #expect(remote == nil && backend == nil)

        await waitFor(timeout: .seconds(10)) { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        // The log is filled by a task of its own, so the event can still be in flight when the
        // host's list has already emptied.
        await waitFor(timeout: .seconds(10)) { log.lastUnsubscribe != nil }
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
        _ = try await Self.subscribedRemote(backend, on: queue, to: identifier, host: host, radio: radio)
        #expect(await host.subscribers(for: Self.measurement).map(\.id) == [backend.sessionID])

        let generation = try #require(await radio.generation(of: identifier))
        await radio.remove(device: identifier, generation: generation)

        await waitFor(timeout: .seconds(10)) { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        // The log is filled by a task of its own, so the event can still be in flight when the
        // host's list has already emptied.
        await waitFor(timeout: .seconds(10)) { log.lastUnsubscribe != nil }
        let departure = try #require(log.lastUnsubscribe)
        #expect(departure.central.id == backend.sessionID)
        #expect(departure.characteristic == Self.measurement)
    }
}
#endif
