//
//  VirtualPeripheralManagerTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
@testable import BLESwiftVirtualRadio
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// Simulator-to-simulator in one process. A real `PeripheralHost` is driven by a
/// ``VirtualPeripheralManagerBackend`` and a real `Central` by a ``VirtualCentralBackend``. One
/// ``VirtualRadio`` serves both, so they hold a full GATT conversation with no CoreBluetooth and no
/// hardware.
///
/// This is the peripheral-role mirror of `CrossRoleEndToEndTests.fullConversation`.
@Suite("VirtualPeripheralManagerBackend")
struct VirtualPeripheralManagerTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: heartRate)

    /// The Heart Rate service that the host publishes. It has a dynamic measurement that is
    /// readable and notifying, and a write-only control point.
    private static var service: GATTService {
        GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable]),
            GATTCharacteristic(identifier: control, properties: [.write], permissions: [.writeable])
        ])
    }

    @Test("Host publishes and advertises; central scans, connects, reads, writes, and is notified")
    func fullConversation() async throws {
        let radio = VirtualRadio()

        let hostQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.Host")
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue),
            queue: hostQueue
        )
        try await host.add(Self.service)

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

        let centralQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.Central")
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

        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 72]))

        try await peripheral.write(Data([0x2A]), to: Self.control)
        #expect(written.withLock { $0 } == Data([0x2A]))

        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.measurement) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // `Peripheral` has no "notifications are armed" signal, so the test waits on the radio's
        // subscription table, which the push consults, and then on the host's subscriber list
        // behind it.
        await waitFor(timeout: .seconds(10)) { await radio.isSubscribed(characteristic: Self.measurement) }
        await waitFor(timeout: .seconds(10)) { await !host.subscribers(for: Self.measurement).isEmpty }
        #expect(await !host.subscribers(for: Self.measurement).isEmpty)
        try await host.updateValue(Data([0, 99]), for: Self.measurement)
        #expect(try await bounded { try await notifications.value } == Data([0, 99]))

        try await central.disconnect(peripheral.id)

        await host.stopAdvertising()
        // This is the same fixed-delay fallback. `stopAdvertising()` reaches the radio
        // asynchronously and reports no completion of its own.
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
        let hostQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.OrphanHost")
        let identifier = UUID()
        let backend = VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, identifier: identifier)
        let host = PeripheralHost(backend: backend, queue: hostQueue)
        try await host.add(Self.service)

        // Drop the handler *without* removing the device. This is the one state in which a request
        // would otherwise be parked with nothing left to answer it.
        await backend.detachEventHandlerForTesting()

        let centralQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.OrphanCentral")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await waitFor { central.state == .poweredOn }

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
        let hostQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.SilentHost")
        let identifier = UUID()
        let backend = VirtualPeripheralManagerBackend(
            radio: radio,
            queue: hostQueue,
            identifier: identifier,
            attTimeout: .milliseconds(200),
            clock: radio.clock
        )
        let host = PeripheralHost(backend: backend, queue: hostQueue)
        try await host.add(Self.service)

        // The host swallows the first read, as a host that is wedged in its own handler does. The
        // host answers every read after it.
        let seen = Mutex<Int>(0)
        let readResponder = Task { @Sendable in
            for await request in await host.readRequests() {
                let ordinal = seen.withLock { $0 += 1; return $0 }
                guard ordinal > 1 else { continue }
                await host.respond(to: request, with: .success(Data([0, 72])))
            }
        }

        let centralQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.SilentCentral")
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

        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 72]))
        #expect(seen.withLock { $0 } == 2)

        readResponder.cancel()
    }

    @Test("A hosted host that never answers closes the write window, and answering reopens it once")
    func writeWithoutResponseWindowBoundsTheChain() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let hostQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.WindowHost")
        // Long enough that nothing times out while the test fills the window and asserts on it. The
        // subject is the window, not the ATT timeout. It is short of the 30 s default, which would
        // leave the held writes parked for the rest of the run.
        let backend = VirtualPeripheralManagerBackend(
            radio: radio,
            queue: hostQueue,
            identifier: identifier,
            attTimeout: .seconds(10),
            clock: radio.clock
        )
        let host = PeripheralHost(backend: backend, queue: hostQueue)
        try await host.add(Self.service)

        // A hosted host that is only slow. It holds every write, unanswered, until this test
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

        // The test drives the backend directly. `Peripheral`'s own writer honors the window, and
        // the window itself is what the test examines.
        let centralQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.WindowCentral")
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
        // One service at a time: a characteristic discovery for an undiscovered service does
        // nothing, so the sweep must land first. `Central` issues them in the same order.
        await Self.onQueue(centralQueue) { remote.discoverServices([Self.heartRate]) }
        await waitFor { await Self.onQueue(centralQueue) { remote.isDiscovered(Self.heartRate) } }
        await Self.onQueue(centralQueue) { remote.discoverCharacteristics([Self.control], for: Self.heartRate) }
        await waitFor { await Self.onQueue(centralQueue) { remote.isDiscovered(Self.control) } }

        let window = LinkFlowControl.writeWithoutResponseWindow
        await Self.onQueue(centralQueue) {
            #expect(remote.canSendWriteWithoutResponse)
            for _ in 0..<window {
                remote.writeValue(Data([0x01]), for: Self.control, type: .withoutResponse)
            }
        }
        // The window is shut, so the 65th write parks in `CentralSession.drainWrites`. It does not
        // join an unbounded chain behind a host that has answered none of the first 64.
        #expect(await Self.onQueue(centralQueue) { !remote.canSendWriteWithoutResponse })
        #expect(ready.withLock { $0 } == 0)

        answering.withLock { $0 = true }
        await waitFor(timeout: .seconds(10)) {
            for request in held.withLock({ let pending = $0; $0 = []; return pending }) {
                await host.respond(to: request, with: .success(()))
            }
            return await Self.onQueue(centralQueue) { remote.canSendWriteWithoutResponse }
        }
        #expect(await Self.onQueue(centralQueue) { remote.canSendWriteWithoutResponse })
        // The event fires once, on the transition that reopened the window, and not once for each
        // write that the host answered.
        #expect(ready.withLock { $0 } == 1)
    }

    @Test("A host's ATT failure surfaces to the central as a CBATTErrorDomain error")
    func readFailure() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.FailingHost")
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

        let centralQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.FailingCentral")
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
        let hostQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.ReadOnlyHost")
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, identifier: identifier),
            queue: hostQueue
        )
        try await host.add(Self.service)

        // A host that would acknowledge anything that it receives. The refusal has to come from the
        // radio's own ATT layer. Otherwise this responder answers the write successfully.
        let arrived = Mutex(0)
        let writeResponder = Task { @Sendable in
            for await request in await host.writeRequests() {
                arrived.withLock { $0 += 1 }
                await host.respond(to: request, with: .success(()))
            }
        }
        defer { writeResponder.cancel() }

        // The test drives the backend directly, because `Peripheral`'s own writer would refuse a
        // write to a characteristic with no write property before it reached a radio. The radio's
        // refusal is under test. Real hardware refuses at the ATT layer for a host with no fixture
        // handler.
        let centralQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.ReadOnlyCentral")
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

        await Self.onQueue(centralQueue) {
            remote.writeValue(Data([0x2A]), for: Self.measurement, type: .withResponse)
        }
        await waitFor { writes.withLock { !$0.isEmpty } }
        let refused = try #require(writes.withLock { $0.first })
        #expect(refused.0 == Self.measurement)
        #expect(refused.1?.domain == "CBATTErrorDomain")
        #expect(refused.1?.code == ATTError.writeNotPermitted.rawValue)
        #expect(arrived.withLock { $0 } == 0)

        // The writable characteristic on the same device is unaffected. The refusal is the
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

        // The device is registered under a placeholder name, as `Provider` names a host session's
        // device after its link client. CoreBluetooth reports the *advertised* local name, and the
        // radio must too, or a scanner sees the placeholder.
        let hostQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.RenamedHost")
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, name: "PlaceholderClient"),
            queue: hostQueue
        )
        try await host.add(Self.service)
        try await host.startAdvertising(
            PeripheralAdvertisement(localName: "Renamed", serviceUUIDs: [Self.heartRate])
        )

        let centralQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.RenamedCentral")
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

    @Test("A stop right behind a start leaves the backend reporting not advertising")
    func stopBehindStartDoesNotLatchAdvertising() async {
        let radio = VirtualRadio()
        let queue = DispatchQueue(label: "VirtualPeripheralManagerTests.advertising")
        let backend = VirtualPeripheralManagerBackend(radio: radio, queue: queue)
        let started = Mutex(false)

        // Both calls are in one queue turn, which CoreBluetooth permits. The start's flag write
        // comes off the radio's chain, so the stop's flag write must not be overwritten by it.
        await Self.onQueue(queue) {
            backend.eventHandler = { event in
                if case .didStartAdvertising = event { started.withLock { $0 = true } }
            }
            backend.startAdvertising(PeripheralAdvertisement(localName: "Virtual HRM", serviceUUIDs: [Self.heartRate]))
            backend.stopAdvertising()
        }

        // Both calls have reached the radio when the start reports that it is applied and the chain
        // behind it has drained.
        await waitFor { started.withLock { $0 } }
        await waitFor { await Self.onQueue(queue) { !backend.isAdvertising } }
        #expect(await Self.onQueue(queue) { !backend.isAdvertising })

        let centralQueue = DispatchQueue(label: "VirtualPeripheralManagerTests.advertising.central")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: centralQueue), queue: centralQueue)
        await waitFor { central.state == .poweredOn }
        var found: Discovery?
        do {
            for try await event in await central.scan(services: [Self.heartRate], timeout: .milliseconds(200)) {
                if case .discovered(let discovery) = event {
                    found = discovery
                    break
                }
            }
        } catch {}
        #expect(found == nil)
    }

    @Test("Clearing the event handler detaches it without removing the hosted device")
    func clearingTheHandlerIsNotTerminal() async throws {
        let radio = VirtualRadio()
        let queue = DispatchQueue(label: "VirtualPeripheralManagerTests.detach")
        let identifier = UUID()
        let backend = VirtualPeripheralManagerBackend(radio: radio, queue: queue, identifier: identifier)

        let started = Mutex<[NSError?]>([])
        await Self.onQueue(queue) {
            backend.eventHandler = { event in
                if case .didStartAdvertising(let error) = event { started.withLock { $0.append(error) } }
            }
            backend.add(Self.service)
            backend.startAdvertising(PeripheralAdvertisement(localName: "Detachable", serviceUUIDs: [Self.heartRate]))
        }
        await waitFor { started.withLock { !$0.isEmpty } }
        #expect(started.withLock { $0 } == [nil])
        #expect(await radio.services(of: identifier, matching: nil) == [Self.heartRate])

        // Detaching is not a teardown. The device stays on the radio, as
        // ``CompositePeripheralManager/eventHandler`` documents for every child that it clears.
        await Self.onQueue(queue) { backend.eventHandler = nil }
        _ = await Self.onQueue(queue) { true }
        #expect(await radio.services(of: identifier, matching: nil) == [Self.heartRate])

        // A new attach installs a working backend, not an inert one. The advertisement that the
        // test gives it is applied and completes without the removal error.
        await Self.onQueue(queue) {
            backend.eventHandler = { event in
                if case .didStartAdvertising(let error) = event { started.withLock { $0.append(error) } }
            }
            backend.startAdvertising(PeripheralAdvertisement(localName: "Detachable", serviceUUIDs: [Self.heartRate]))
        }
        await waitFor { started.withLock { $0.count } == 2 }
        #expect(started.withLock { $0 } == [nil, nil])
        #expect(await radio.services(of: identifier, matching: nil) == [Self.heartRate])
    }

    // MARK: - Departing subscribers

    /// Runs `body` on `queue` and returns its result. It does not block a cooperative thread.
    private static func onQueue<T: Sendable>(
        _ queue: DispatchQueue,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// A hosted `PeripheralHost` on `radio` that publishes ``service``, with an observer already
    /// attached to its subscription events.
    ///
    /// The stream is created *before* this returns, because `subscriptionEvents()` does not replay.
    private static func hostRig(
        radio: VirtualRadio,
        label: String,
        identifier: UUID
    ) async throws -> (host: PeripheralHost, log: SubscriptionLog, observer: Task<Void, Never>) {
        let hostQueue = DispatchQueue(label: label)
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

    /// Connects `backend` to `identifier` and subscribes it to ``measurement``. It returns the
    /// remote, so each test controls how that central departs.
    ///
    /// The test drives the backend directly and not through a `Central`, because a notification
    /// stream unsubscribes when it terminates and these tests must *not* do that.
    private static func subscribedRemote(
        _ backend: VirtualCentralBackend,
        on queue: DispatchQueue,
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
        // Discover before subscribing: a `PeripheralRemote` ignores a `setNotifyValue` on an
        // undiscovered characteristic, as CoreBluetooth does.
        await onQueue(queue) { remote.discoverServices([Self.heartRate]) }
        await waitFor { await onQueue(queue) { remote.isDiscovered(Self.heartRate) } }
        await onQueue(queue) { remote.discoverCharacteristics([Self.measurement], for: Self.heartRate) }
        await waitFor { await onQueue(queue) { remote.isDiscovered(Self.measurement) } }
        await onQueue(queue) { remote.setNotifyValue(true, for: Self.measurement) }
        // Wait for both halves of the arming, each with a bound that a starved runner cannot
        // outrun: the radio's subscription table, which a `remove()` or disconnect walks, and then
        // the host's view behind it.
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

        let queue = DispatchQueue(label: "VirtualPeripheralManagerTests.DisconnectCentral")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let remote = try await Self.subscribedRemote(backend, on: queue, to: identifier, host: host, radio: radio)
        #expect(await host.subscribers(for: Self.measurement).map(\.id) == [backend.sessionID])

        // The central goes away without a prior unsubscribe, as a real central does when its
        // connection is cancelled.
        await Self.onQueue(queue) { backend.cancelPeripheralConnection(remote) }

        await waitFor(timeout: .seconds(10)) { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        // A task of its own fills the log, so the event can still be in flight when the host's list
        // has already emptied.
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

        let queue = DispatchQueue(label: "VirtualPeripheralManagerTests.DetachCentral")
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

        // The test releases the session and does not cancel it. `deinit` detaches the session from
        // the radio. The subscriptions that go with it must still reach the host.
        remote = nil
        backend = nil
        #expect(remote == nil && backend == nil)

        await waitFor(timeout: .seconds(10)) { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
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

        let queue = DispatchQueue(label: "VirtualPeripheralManagerTests.RemoveCentral")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        _ = try await Self.subscribedRemote(backend, on: queue, to: identifier, host: host, radio: radio)
        #expect(await host.subscribers(for: Self.measurement).map(\.id) == [backend.sessionID])

        let generation = try #require(await radio.generation(of: identifier))
        await radio.remove(device: identifier, generation: generation)

        await waitFor(timeout: .seconds(10)) { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
        await waitFor(timeout: .seconds(10)) { log.lastUnsubscribe != nil }
        let departure = try #require(log.lastUnsubscribe)
        #expect(departure.central.id == backend.sessionID)
        #expect(departure.characteristic == Self.measurement)
    }
}
#endif
