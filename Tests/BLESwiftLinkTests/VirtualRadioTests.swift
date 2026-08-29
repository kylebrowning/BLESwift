//
//  VirtualRadioTests.swift
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

@Suite("VirtualRadio")
struct VirtualRadioTests {

    private static let fixtureJSON = """
    { "devices": [ { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "Fixture HRM", "advertisedServices": ["180D"],
      "services": [ { "uuid": "180D", "characteristics": [
        { "uuid": "2A37", "properties": ["read", "notify"], "value": "AEg=" },
        { "uuid": "2A39", "properties": ["read", "write", "writeWithoutResponse", "notify"], "value": "AA==" } ] } ] } ] }
    """
    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: service)

    private func makeRig() async throws -> (Central, VirtualRadio, VirtualDeviceHandle) {
        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        let handle = await radio.register(device)
        await handler.attach(handle)
        let queue = DispatchSerialQueue(label: "VirtualRadioTests")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
        await waitFor { central.state == .poweredOn }
        return (central, radio, handle)
    }

    /// A device registered under `identifier`, advertising `name` and hosting `services`.
    private static func device(identifier: UUID, name: String, services: [GATTService]) -> VirtualDevice {
        VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: identifier,
                name: name,
                advertisement: AdvertisementData(localName: name, serviceUUIDs: [Self.service], isConnectable: true),
                services: services
            ),
            handler: InertHandler()
        )
    }

    @Test("A re-registered identifier ignores every mutation from the handle it replaced")
    func staleHandleMutationsAreIgnored() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let published = GATTService(identifier: Self.service, characteristics: [
            GATTCharacteristic(identifier: Self.measurement, properties: [.read], permissions: [.readable])
        ])

        // Generation 1: the session that is about to be replaced.
        let first = await radio.register(Self.device(identifier: identifier, name: "first", services: []))
        // Generation 2: the reconnect, registered under the same stable `hostIdentifier`.
        let second = await radio.register(Self.device(identifier: identifier, name: "second", services: [published]))
        #expect(first.generation != second.generation)

        // The old session's teardown, landing *after* its successor registered: exactly the
        // `stopAdvertising` / `removeAllHostedServices` / `eventHandler = nil` sequence
        // `HostSession.close()` runs, all of it keyed by the identifier they now share.
        await first.setAdvertising(false)
        await first.setServices([])
        await first.setAdvertisement(AdvertisementData(localName: "first", isConnectable: true))
        await first.remove()

        // The new registration is untouched: still there, still generation 2's state.
        #expect(radio.knownDeviceIDs.withLock { $0.contains(identifier) })
        #expect(await radio.name(of: identifier) == "second")
        #expect(await radio.services(of: identifier, matching: nil) == [Self.service])

        // And still advertising, so a scan started after the teardown finds it.
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.generation")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
        await waitFor { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: [Self.service], timeout: .seconds(2)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        #expect(found?.peripheral.uuid == identifier)
        #expect(found?.advertisement.localName == "second")

        // The current handle still works, so the guard refuses only the stale one.
        await second.remove()
        #expect(radio.knownDeviceIDs.withLock { !$0.contains(identifier) })
    }

    @Test("Scanning discovers an advertising fixture device")
    func scan() async throws {
        let (central, _, _) = try await makeRig()
        var found: Discovery?
        for try await event in await central.scan(services: [Self.service], timeout: .seconds(2)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        #expect(found?.peripheral.name == "Fixture HRM")
        #expect(found?.rssi == -50)
        #expect(found?.advertisement.serviceUUIDs == [Self.service])
    }

    @Test("Connect, read a static value, write, and get notified")
    func gatt() async throws {
        let (central, radio, _) = try await makeRig()
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        let peripheral = try await central.connect(PeripheralIdentifier(uuid: id, name: "Fixture HRM"))
        let measured: Data = try await peripheral.read(from: Self.measurement)
        #expect(measured == Data([0, 0x48]))

        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.control) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // `Peripheral` publishes no "notifications are armed" signal of its own, so the wait is
        // on the radio's own subscription table — the state the push consults.
        await waitFor(timeout: .seconds(10)) { await radio.isSubscribed(characteristic: Self.control) }
        #expect(await radio.isSubscribed(characteristic: Self.control))
        try await peripheral.write(Data([0x2A]), to: Self.control)
        #expect(try await bounded { try await notifications.value } == Data([0x2A]))
        let readBack: Data = try await peripheral.read(from: Self.control)
        #expect(readBack == Data([0x2A]))
        try await central.disconnect(peripheral.id)
    }

    @Test("Connecting to an unknown identifier throws rather than connecting")
    func unknown() async throws {
        let (central, radio, handle) = try await makeRig()
        // An identifier the backend has never seen is never vended as a remote at all, so the
        // attempt fails before it can reach the radio.
        do {
            _ = try await central.connect(PeripheralIdentifier(uuid: UUID(), name: nil), timeout: .seconds(2))
            Issue.record("Expected the connect to fail")
        } catch let error as BLESwiftError {
            guard case .unexpectedPeripheral = error else {
                Issue.record("Expected .unexpectedPeripheral, got \(error)")
                return
            }
        }

        // A device this backend *has* sighted stays retrievable after the radio drops it, and
        // the connect attempt is what then fails — with the radio's own error.
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        for try await event in await central.scan(services: [Self.service], timeout: .seconds(2)) {
            if case .discovered = event { break }
        }
        await handle.remove()
        await waitFor { await radio.name(of: id) == nil }
        do {
            _ = try await central.connect(PeripheralIdentifier(uuid: id, name: nil), timeout: .seconds(2))
            Issue.record("Expected the connect to fail")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "BLESwiftProvider")
            #expect(nsError.code == 1)
        }
    }

    @Test("The backend vends remotes only for devices the radio knows")
    func retrievalIsLimitedToKnownDevices() async throws {
        let (central, _, _) = try await makeRig()
        let registered = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

        #expect(try await central.knownPeripherals(withIdentifiers: [UUID()]).isEmpty)
        #expect(try await central.knownPeripherals(withIdentifiers: [registered]).map(\.uuid) == [registered])
    }

    @Test("A device registered after attachment becomes retrievable")
    func lateRegistrationBecomesRetrievable() async throws {
        let (central, radio, _) = try await makeRig()
        let identifier = UUID()
        let (device, handler) = VirtualDevice.fixture(
            FixtureDevice(id: identifier, name: "Late", advertisedServices: [], services: [])
        )
        let handle = await radio.register(device)
        await handler.attach(handle)

        await waitFor { (try? await central.knownPeripherals(withIdentifiers: [identifier]))?.isEmpty == false }
        #expect(try await central.knownPeripherals(withIdentifiers: [identifier]).map(\.uuid) == [identifier])
    }

    @Test("A device registered a moment ago is retrievable with no waiting at all")
    func registrationIsVisibleWithoutWaiting() async throws {
        // The shape the provider's own sessions have: register a device, then build a backend
        // and look the identifier up in one synchronous flow, with no `waitFor` and no chance
        // for any hop to have run. A pushed known-devices snapshot could not be there yet, so
        // this used to depend on the scheduler — and lost the race under CI load.
        let radio = VirtualRadio()
        let identifier = UUID()
        let (device, handler) = VirtualDevice.fixture(
            FixtureDevice(id: identifier, name: "Immediate", advertisedServices: [], services: [])
        )
        let handle = await radio.register(device)
        await handler.attach(handle)

        let queue = DispatchSerialQueue(label: "VirtualRadioTests.immediate")
        let retrieved = queue.sync { () -> [UUID] in
            let backend = VirtualCentralBackend(radio: radio, queue: queue)
            return backend.retrievePeripherals(withIdentifiers: [identifier]).map(\.identifier)
        }
        #expect(retrieved == [identifier])

        // And a removal is just as immediate in the other direction.
        await handle.remove()
        let afterRemoval = queue.sync { () -> [UUID] in
            let backend = VirtualCentralBackend(radio: radio, queue: queue)
            return backend.retrievePeripherals(withIdentifiers: [identifier]).map(\.identifier)
        }
        #expect(afterRemoval.isEmpty)
    }

    @Test("Removing a connected device disconnects the central with provider code 2")
    func removal() async throws {
        let (central, _, handle) = try await makeRig()
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        _ = try await central.connect(PeripheralIdentifier(uuid: id, name: nil))
        // Subscribed here, not inside the task: `connectionEvents()` is a broadcast with no
        // replay, and the stream's subscriber is registered the moment it is created. Creating
        // it inside the task let `remove()` win the race perhaps one run in ten — the
        // `.disconnected` was yielded to nobody, the stream then never yielded again, and the
        // test parked on `events.value` forever, hanging the whole bundle with it.
        let events = await central.connectionEvents()
        let disconnects = Task { () -> (any Error)?? in
            for await event in events {
                if case .disconnected(_, let error, _) = event { return .some(error) }
            }
            return .none
        }
        await handle.remove()
        let reported = try #require(try await bounded { await disconnects.value })
        let nsError = try #require(reported) as NSError
        #expect(nsError.domain == "BLESwiftProvider")
        #expect(nsError.code == 2)
    }

    @Test("A device's event sink is released on disconnect and on removal")
    func peripheralSinksAreReleased() async throws {
        /// Stands in for everything a real sink closes over — a backend's remote, and through
        /// it the session it belongs to. Its lifetime *is* the sink's.
        final class Probe: Sendable {}

        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        let handle = await radio.register(device)
        await handler.attach(handle)
        let identifier = fixture.id
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })

        // Ended by the central: the sink goes with the connection that registered it.
        weak var afterDisconnect: Probe?
        do {
            let probe = Probe()
            afterDisconnect = probe
            #expect(await radio.connect(session: session, device: identifier, sink: { _ in _ = probe }).error == nil)
        }
        #expect(afterDisconnect != nil)
        await radio.disconnect(session: session, device: identifier)
        #expect(afterDisconnect == nil)

        // Ended by the device going away: same, for every session, connected or not.
        weak var afterRemoval: Probe?
        do {
            let probe = Probe()
            afterRemoval = probe
            #expect(await radio.connect(session: session, device: identifier, sink: { _ in _ = probe }).error == nil)
        }
        #expect(afterRemoval != nil)
        await handle.remove()
        #expect(afterRemoval == nil)
    }

    @Test("Back-to-back writes without response reach the radio in the order they were made")
    func writeWithoutResponseOrdering() async throws {
        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        await handler.attach(await radio.register(device))
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.writes")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

        await waitFor { await Self.onQueue(queue) { !backend.retrievePeripherals(withIdentifiers: [id]).isEmpty } }
        let remote = try #require(
            await Self.onQueue(queue) { backend.retrievePeripherals(withIdentifiers: [id]).first as? VirtualPeripheralRemote }
        )
        let values = Mutex<[Data]>([])
        await Self.onQueue(queue) {
            remote.eventHandler = { event in
                if case .didUpdateValue(_, let value, _) = event, let value { values.withLock { $0.append(value) } }
            }
            backend.connect(remote, options: nil, requiresANCS: false)
        }
        await waitFor { await Self.onQueue(queue) { remote.connectionState == .connected } }

        // Discovered first: a `PeripheralRemote` no-ops GATT traffic for a characteristic it
        // has not discovered, so a test driving one directly has to enumerate it the way
        // `Central` would.
        // A service at a time: a characteristic discovery for a service the remote has not
        // discovered yet is a no-op, so the sweep has to land before the one under it is asked
        // for — exactly the order `Central` issues them in.
        await Self.onQueue(queue) { remote.discoverServices([Self.service]) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.control) } }

        // Two writes without response issued in one queue block — the `drainWrites` shape.
        // Nothing acknowledges either, so they land on the radio purely as queued work;
        // repeated, because an inversion is scheduler-dependent.
        for iteration in 0..<25 {
            let first = Data([UInt8(iteration), 1])
            let second = Data([UInt8(iteration), 2])
            await Self.onQueue(queue) {
                remote.writeValue(first, for: Self.control, type: .withoutResponse)
                remote.writeValue(second, for: Self.control, type: .withoutResponse)
                remote.readValue(for: Self.control)
            }
            await waitFor { values.withLock { $0.count } == iteration + 1 }
            #expect(values.withLock { $0.last } == second, "iteration \(iteration)")
        }
    }

    @Test("A scan stopped immediately behind itself leaves no scanner on the radio")
    func stopScanBehindScanLeavesNoScanner() async throws {
        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        await handler.attach(await radio.register(device))
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.stopscan")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)

        // A duplicate-allowing scan installs a repeater; a `stopScan` that reached the radio
        // first would leave it running forever against a scan nobody asked for any more.
        for iteration in 0..<10 {
            await Self.onQueue(queue) {
                backend.scanForPeripherals(withServices: nil, options: ScanOptions(allowDuplicates: true))
                backend.stopScan()
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(await !radio.hasScanner(session: backend.sessionID), "iteration \(iteration)")
        }
    }

    /// Runs `body` on `queue` and returns its result, without blocking a cooperative thread.
    private static func onQueue<T: Sendable>(
        _ queue: DispatchSerialQueue,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    @Test("Handle-driven notifications reach subscribed centrals")
    func handleNotify() async throws {
        let (central, radio, handle) = try await makeRig()
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        let peripheral = try await central.connect(PeripheralIdentifier(uuid: id, name: nil))
        let task = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.measurement) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // See `gatt()` — no public arming signal, so the wait is on the radio's own
        // subscription table.
        await waitFor(timeout: .seconds(10)) { await radio.isSubscribed(characteristic: Self.measurement) }
        #expect(await radio.isSubscribed(characteristic: Self.measurement))
        await handle.notify(Data([0, 99]), for: Self.measurement, to: nil)
        #expect(try await bounded { try await task.value } == Data([0, 99]))
    }

    /// A device that answers no GATT traffic — the sighting-history tests only need it to
    /// exist and advertise.
    private struct InertHandler: VirtualDeviceHandler {
        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.unlikelyError)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .failure(.unlikelyError)
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
    }

    @Test("The sighting history is capped, forgetting the oldest sighting first")
    func sightingHistoryIsCapped() async throws {
        let radio = VirtualRadio()
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.sightings")
        // A history of one, so a second sighting is all it takes to forget the first.
        let backend = VirtualCentralBackend(radio: radio, queue: queue, maximumDiscovered: 1)

        let sighted = Mutex<[UUID]>([])
        await Self.onQueue(queue) {
            backend.eventHandler = { event in
                if case .didDiscover(let peripheral, _, _) = event { sighted.withLock { $0.append(peripheral.uuid) } }
            }
        }

        /// Registers an advertising device and returns its handle once the backend has seen it.
        func advertise() async -> (id: UUID, handle: VirtualDeviceHandle) {
            let identifier = UUID()
            let device = VirtualDevice(
                descriptor: VirtualDeviceDescriptor(
                    identifier: identifier,
                    advertisement: AdvertisementData(serviceUUIDs: [Self.service], isConnectable: true)
                ),
                handler: InertHandler()
            )
            let handle = await radio.register(device)
            await waitFor { sighted.withLock { $0.contains(identifier) } }
            return (identifier, handle)
        }

        await Self.onQueue(queue) {
            backend.scanForPeripherals(withServices: nil, options: ScanOptions(allowDuplicates: false))
        }
        // Sequential, so the history's order is the order they were registered in.
        let oldest = await advertise()
        let newest = await advertise()
        #expect(sighted.withLock { $0 } == [oldest.id, newest.id])

        // Both devices leave the radio, so only the sighting history can still vend a remote
        // for them — which is exactly what the cap bounds.
        await oldest.handle.remove()
        await newest.handle.remove()

        #expect(await Self.onQueue(queue) { backend.retrievePeripherals(withIdentifiers: [oldest.id]).isEmpty })
        #expect(await Self.onQueue(queue) { backend.retrievePeripherals(withIdentifiers: [newest.id]).count } == 1)
    }

    /// Registers an inert device on `radio` and returns its identifier.
    private static func register(on radio: VirtualRadio) async -> UUID {
        let identifier = UUID()
        let device = VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: identifier,
                advertisement: AdvertisementData(serviceUUIDs: [Self.service], isConnectable: true)
            ),
            handler: InertHandler()
        )
        _ = await radio.register(device)
        return identifier
    }

    @Test("The remote table is capped, forgetting the least recently vended disconnected remote")
    func remoteTableIsCapped() async throws {
        let radio = VirtualRadio()
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.remotecap")
        // A table of one, so the second remote is all it takes to forget the first.
        let backend = VirtualCentralBackend(radio: radio, queue: queue, maximumDiscovered: 8, maximumRemotes: 1)
        let oldest = await Self.register(on: radio)
        let newest = await Self.register(on: radio)

        let first = try #require(await Self.remote(backend, queue, oldest))
        _ = await Self.remote(backend, queue, newest)

        // Disconnected, so the cap was free to drop it: the identifier is still known, and
        // retrieving it again mints a remote rather than returning the forgotten one.
        let refetched = try #require(await Self.remote(backend, queue, oldest))
        #expect(refetched !== first)
    }

    @Test("The remote cap keeps a connected remote and re-files one it evicted")
    func remoteCapKeepsConnectedRemotesAndRefilesEvictedOnes() async throws {
        let radio = VirtualRadio()
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.remotecap.connected")
        let backend = VirtualCentralBackend(radio: radio, queue: queue, maximumDiscovered: 8, maximumRemotes: 1)
        let connected = await Self.register(on: radio)
        let other = await Self.register(on: radio)
        let filler = await Self.register(on: radio)

        let events = Mutex<[UUID]>([])
        await Self.onQueue(queue) {
            backend.eventHandler = { event in
                if case .didConnect(let peripheral) = event { events.withLock { $0.append(peripheral.uuid) } }
            }
        }

        let live = try #require(await Self.remote(backend, queue, connected))
        await Self.onQueue(queue) { backend.connect(live, options: nil, requiresANCS: false) }
        await waitFor { events.withLock { $0.contains(connected) } }

        // Overflows the table of one while `live` is connected: a connected remote is never
        // the cap's candidate, so the newcomer is filed alongside it rather than in its place.
        let evicted = try #require(await Self.remote(backend, queue, other))
        #expect(await Self.remote(backend, queue, connected) === live)

        // `evicted` is disconnected, so the next retrieval is what displaces it — and
        // connecting it anyway re-files it, rather than leaving the caller waiting for a
        // `didConnect` nothing would ever send.
        _ = await Self.remote(backend, queue, filler)
        await Self.onQueue(queue) { backend.connect(evicted, options: nil, requiresANCS: false) }
        await waitFor(timeout: .seconds(5)) { events.withLock { $0.contains(other) } }
        #expect(events.withLock { $0.contains(other) })
    }

    @Test("A connect to a remote this backend has replaced fails instead of being dropped")
    func connectToAStaleRemoteFails() async throws {
        let radio = VirtualRadio()
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.staleconnect")
        let backend = VirtualCentralBackend(radio: radio, queue: queue, maximumDiscovered: 8, maximumRemotes: 1)
        let target = await Self.register(on: radio)
        let filler = await Self.register(on: radio)

        let failures = Mutex<[(peripheral: UUID, error: NSError?)]>([])
        await Self.onQueue(queue) {
            backend.eventHandler = { event in
                guard case .didFailToConnect(let peripheral, let error) = event else { return }
                failures.withLock { $0.append((peripheral.uuid, error as NSError?)) }
            }
        }

        let stale = try #require(await Self.remote(backend, queue, target))
        // Evicted by the overflow, then re-minted: the backend files a *different* remote for
        // `target`, and the radio's events for it would be routed there.
        _ = await Self.remote(backend, queue, filler)
        let current = try #require(await Self.remote(backend, queue, target))
        #expect(current !== stale)

        await Self.onQueue(queue) { backend.connect(stale, options: nil, requiresANCS: false) }

        await waitFor { failures.withLock { !$0.isEmpty } }
        let reported = failures.withLock { $0 }
        #expect(reported.count == 1)
        #expect(reported.first?.peripheral == target)
        #expect(reported.first?.error?.domain == "BLESwiftProvider")
        #expect(reported.first?.error?.code == 8)
        // Refused before the radio was ever asked, so the stale remote never left `.disconnected`.
        #expect(await Self.onQueue(queue) { stale.connectionState } == .disconnected)
    }

    @Test("A read for a characteristic the remote has not discovered is a no-op")
    func undiscoveredReadIsANoOp() async throws {
        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        await handler.attach(await radio.register(device))
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.undiscoveredread")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

        await waitFor { await Self.onQueue(queue) { !backend.retrievePeripherals(withIdentifiers: [id]).isEmpty } }
        let remote = try #require(await Self.remote(backend, queue, id))
        let values = Mutex<[Data]>([])
        await Self.onQueue(queue) {
            remote.eventHandler = { event in
                if case .didUpdateValue(_, let value, _) = event, let value { values.withLock { $0.append(value) } }
            }
            backend.connect(remote, options: nil, requiresANCS: false)
        }
        await waitFor { await Self.onQueue(queue) { remote.connectionState == .connected } }
        #expect(await Self.onQueue(queue) { !remote.isDiscovered(Self.control) })

        // Undiscovered: the radio is never asked, so no completion is delivered.
        await Self.onQueue(queue) { remote.readValue(for: Self.control) }

        // Discovery behind it is the barrier: its own completion cannot land before the read's
        // would have, since both run on the same serial chain and the same queue.
        // A service at a time: a characteristic discovery for a service the remote has not
        // discovered yet is a no-op, so the sweep has to land before the one under it is asked
        // for — exactly the order `Central` issues them in.
        await Self.onQueue(queue) { remote.discoverServices([Self.service]) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.control) } }
        #expect(values.withLock { $0 }.isEmpty)

        // The very same read now answers: the guard is the discovery cache, nothing else.
        await Self.onQueue(queue) { remote.readValue(for: Self.control) }
        await waitFor { values.withLock { !$0.isEmpty } }
        #expect(values.withLock { $0.count } == 1)
    }

    @Test("A characteristic discovery for an undiscovered service is a no-op")
    func undiscoveredCharacteristicDiscoveryIsANoOp() async throws {
        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        await handler.attach(await radio.register(device))
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.undiscoveredchars")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

        await waitFor { await Self.onQueue(queue) { !backend.retrievePeripherals(withIdentifiers: [id]).isEmpty } }
        let remote = try #require(await Self.remote(backend, queue, id))
        let discovered = Mutex<[ServiceIdentifier]>([])
        await Self.onQueue(queue) {
            remote.eventHandler = { event in
                if case .didDiscoverCharacteristics(let service, _) = event {
                    discovered.withLock { $0.append(service) }
                }
            }
            backend.connect(remote, options: nil, requiresANCS: false)
        }
        await waitFor { await Self.onQueue(queue) { remote.connectionState == .connected } }
        #expect(await Self.onQueue(queue) { !remote.isDiscovered(Self.service) })

        // The service was never discovered, so — as with `LinkPeripheral` and `CBPeripheral`,
        // which has no `CBService` object to hand its own `discoverCharacteristics(_:for:)` —
        // the radio is never asked and no completion arrives.
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }

        // The service discovery behind it is the barrier: both run on the same serial chain,
        // so its own completion cannot land before the refused one would have.
        await Self.onQueue(queue) { remote.discoverServices([Self.service]) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        #expect(discovered.withLock { $0 }.isEmpty)
        #expect(await Self.onQueue(queue) { remote.discoveredCharacteristics(for: Self.service).isEmpty })

        // The very same call now answers: the guard is the discovery cache, nothing else.
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }
        await waitFor { discovered.withLock { !$0.isEmpty } }
        #expect(discovered.withLock { $0 } == [Self.service])
        #expect(await Self.onQueue(queue) { remote.isDiscovered(Self.control) })
    }

    @Test("A disconnected remote reads nothing and the radio refuses the read outright")
    func readAfterDisconnectIsRefused() async throws {
        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        await handler.attach(await radio.register(device))
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.readafterdisconnect")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

        await waitFor { await Self.onQueue(queue) { !backend.retrievePeripherals(withIdentifiers: [id]).isEmpty } }
        let remote = try #require(await Self.remote(backend, queue, id))
        let values = Mutex<[Data]>([])
        let rssis = Mutex<[Int]>([])
        await Self.onQueue(queue) {
            remote.eventHandler = { event in
                switch event {
                case .didUpdateValue(_, let value, _):
                    if let value { values.withLock { $0.append(value) } }
                case .didReadRSSI(let rssi, _):
                    rssis.withLock { $0.append(rssi) }
                default:
                    break
                }
            }
            backend.connect(remote, options: nil, requiresANCS: false)
        }
        await waitFor { await Self.onQueue(queue) { remote.connectionState == .connected } }
        // A service at a time: a characteristic discovery for a service the remote has not
        // discovered yet is a no-op, so the sweep has to land before the one under it is asked
        // for — exactly the order `Central` issues them in.
        await Self.onQueue(queue) { remote.discoverServices([Self.service]) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.control) } }

        await Self.onQueue(queue) { backend.cancelPeripheralConnection(remote) }
        await waitFor { await Self.onQueue(queue) { remote.connectionState == .disconnected } }
        // The disconnect emptied the discovery caches, exactly as a `LinkPeripheral`'s
        // `markDisconnected()` does, so the read never leaves the remote at all.
        #expect(await Self.onQueue(queue) { !remote.isDiscovered(Self.control) })
        #expect(await Self.onQueue(queue) { remote.discoveredServices.isEmpty })
        #expect(await Self.onQueue(queue) { remote.properties(of: Self.control) == [] })

        // `readRSSI()` is the barrier: it always completes, and on the same queue, so its
        // event landing proves the read's would have landed by now had one been produced.
        await Self.onQueue(queue) {
            remote.readValue(for: Self.control)
            remote.readRSSI()
        }
        await waitFor { rssis.withLock { !$0.isEmpty } }
        #expect(values.withLock { $0 }.isEmpty)

        // And the radio refuses it on its own account, for any caller that reaches past the
        // remote's cache: `2A39` has a static value, so only the connection gate can refuse it.
        let refused = await radio.read(device: id, characteristic: Self.control, session: backend.sessionID)
        #expect(refused == .failure(.invalidHandle))
        let written = await radio.write(device: id, characteristic: Self.control, value: Data([1]), session: backend.sessionID)
        guard case .failure(.invalidHandle) = written else {
            Issue.record("Expected the write to be refused with .invalidHandle, got \(written)")
            return
        }
    }

    @Test("A disconnected session cannot plant a subscription, and detach leaves no ghost")
    func setNotifyWhileDisconnectedPlantsNoSubscription() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchSerialQueue(label: "VirtualRadioTests.ghost.host")
        let identifier = UUID()
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, identifier: identifier),
            queue: hostQueue
        )
        try await host.add(
            GATTService(identifier: Self.service, characteristics: [
                GATTCharacteristic(identifier: Self.measurement, properties: [.read, .notify], permissions: [.readable])
            ])
        )
        await waitFor { await !radio.services(of: identifier, matching: nil).isEmpty }

        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })

        // Never connected: nothing is armed, nothing is filed, and the host is told nothing.
        #expect(await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session).isNotifying == false)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(await host.subscribers(for: Self.measurement).isEmpty)

        // Connected: the very same call takes, so the refusal above was the gate and not the
        // characteristic.
        #expect(await radio.connect(session: session, device: identifier, sink: { _ in }).error == nil)
        #expect(await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session).isNotifying == true)
        await waitFor { await !host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).count == 1)

        // Disconnected again: the subscription is dropped, and a `setNotify` from the stale
        // session cannot plant a new one behind it.
        await radio.disconnect(session: session, device: identifier)
        await waitFor { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session).isNotifying == false)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(await host.subscribers(for: Self.measurement).isEmpty)

        // A detach has nothing left to clean, and leaves nothing behind either.
        await radio.detach(session: session)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
    }

    /// Records every `subscriptionChanged` the radio reports, so a test can assert on exactly
    /// which calls produced one.
    private final class RecordingHandler: VirtualDeviceHandler, Sendable {
        private let changes = Mutex<[Bool]>([])

        /// Every reported change, in order, as its `isSubscribed` flag.
        var reported: [Bool] { changes.withLock { $0 } }

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.unlikelyError)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .failure(.unlikelyError)
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
            changes.withLock { $0.append(isSubscribed) }
        }
    }

    @Test("A subscription change is reported only when the subscriber set really changed")
    func subscriptionChangesAreReportedOnlyOnTransitions() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handler = RecordingHandler()
        _ = await radio.register(
            VirtualDevice(
                descriptor: VirtualDeviceDescriptor(
                    identifier: identifier,
                    advertisement: AdvertisementData(serviceUUIDs: [Self.service], isConnectable: true),
                    services: [
                        GATTService(identifier: Self.service, characteristics: [
                            GATTCharacteristic(
                                identifier: Self.measurement,
                                properties: [.read, .notify],
                                permissions: [.readable]
                            )
                        ])
                    ]
                ),
                handler: handler
            )
        )
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        #expect(await radio.connect(session: session, device: identifier, sink: { _ in }).error == nil)

        /// Sets the notification state and returns what the radio reports it as afterwards.
        func setNotify(_ enabled: Bool) async -> Bool {
            let outcome = await radio.setNotify(
                enabled, device: identifier, characteristic: Self.measurement, session: session
            )
            #expect(outcome.error == nil)
            return outcome.isNotifying
        }

        // Disabling a characteristic that was never enabled is not an unsubscribe: the host
        // never had this subscriber, so it must not be told it lost one.
        #expect(await setNotify(false) == false)
        #expect(handler.reported.isEmpty)

        // The first enable is the transition; the second changes nothing and reports nothing.
        #expect(await setNotify(true) == true)
        #expect(await setNotify(true) == true)
        #expect(handler.reported == [true])
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 1)

        // Symmetrically on the way out.
        #expect(await setNotify(false) == false)
        #expect(await setNotify(false) == false)
        #expect(handler.reported == [true, false])
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
    }

    @Test("Notifying a characteristic that declares no notify or indicate is refused")
    func setNotifyEnforcesTheNotifiableProperty() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchSerialQueue(label: "VirtualRadioTests.notifiable.host")
        let identifier = UUID()
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, identifier: identifier),
            queue: hostQueue
        )
        // Read/write only: no CCCD, so no hardware would ever accept a subscription on it.
        try await host.add(
            GATTService(identifier: Self.service, characteristics: [
                GATTCharacteristic(
                    identifier: Self.control,
                    properties: [.read, .write],
                    permissions: [.readable, .writeable]
                )
            ])
        )
        await waitFor { await !radio.services(of: identifier, matching: nil).isEmpty }

        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        #expect(await radio.connect(session: session, device: identifier, sink: { _ in }).error == nil)

        let refused = await radio.setNotify(true, device: identifier, characteristic: Self.control, session: session)
        #expect(refused.isNotifying == false)
        #expect(refused.error == .requestNotSupported)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.control) == 0)
        #expect(await host.subscribers(for: Self.control).isEmpty)

        // A characteristic that is not in the database at all is refused the way a read or a
        // write of it is.
        let missing = await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session)
        #expect(missing.isNotifying == false)
        #expect(missing.error == .attributeNotFound)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
    }

    /// A second service, so a discovery can be narrowed and a database can drop one.
    private static let batteryService = ServiceIdentifier(uuid: "180F")
    private static let batteryLevel = CharacteristicIdentifier(uuid: "2A19", service: batteryService)

    /// A device hosting the heart-rate and battery services, connected to `backend`, with
    /// both services and the heart rate's characteristics already discovered.
    private static func discoveredRemote(
        radio: VirtualRadio,
        backend: VirtualCentralBackend,
        queue: DispatchSerialQueue,
        identifier: UUID
    ) async throws -> VirtualPeripheralRemote {
        await waitFor { await onQueue(queue) { !backend.retrievePeripherals(withIdentifiers: [identifier]).isEmpty } }
        let remote = try #require(await remote(backend, queue, identifier))
        await onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await waitFor { await onQueue(queue) { remote.connectionState == .connected } }
        await onQueue(queue) { remote.discoverServices(nil) }
        await waitFor { await onQueue(queue) { remote.isDiscovered(service) } }
        await onQueue(queue) { remote.discoverCharacteristics(nil, for: service) }
        await waitFor { await onQueue(queue) { remote.isDiscovered(measurement) } }
        return remote
    }

    /// Both services, the heart rate carrying its measurement and control point.
    private static var twoServices: [GATTService] {
        [
            GATTService(identifier: service, characteristics: [
                GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable]),
                GATTCharacteristic(identifier: control, properties: [.write], permissions: [.writeable])
            ]),
            GATTService(identifier: batteryService, characteristics: [
                GATTCharacteristic(identifier: batteryLevel, properties: [.read], permissions: [.readable])
            ])
        ]
    }

    @Test("A narrower discovery replaces the caches rather than adding to them")
    func discoveryReplacesTheCaches() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        _ = await radio.register(Self.device(identifier: identifier, name: "two", services: Self.twoServices))
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.replace")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let remote = try await Self.discoveredRemote(radio: radio, backend: backend, queue: queue, identifier: identifier)

        #expect(await Self.onQueue(queue) { Set(remote.discoveredServices) } == [Self.service, Self.batteryService])
        #expect(await Self.onQueue(queue) { Set(remote.discoveredCharacteristics(for: Self.service)) } == [Self.measurement, Self.control])

        // A discovery narrowed to one service leaves exactly that one discovered — the answer
        // is the cache, not an addition to it, which is what `LinkPeripheral` does with the
        // same answer arriving over the link.
        await Self.onQueue(queue) { remote.discoverServices([Self.batteryService]) }
        await waitFor { await Self.onQueue(queue) { !remote.isDiscovered(Self.service) } }
        #expect(await Self.onQueue(queue) { remote.discoveredServices } == [Self.batteryService])
        // And the heart rate's characteristics went with it.
        #expect(await Self.onQueue(queue) { remote.discoveredCharacteristics(for: Self.service).isEmpty })
        #expect(await Self.onQueue(queue) { remote.properties(of: Self.measurement) } == [])

        // Narrowing a characteristic discovery replaces that service's entries the same way.
        await Self.onQueue(queue) { remote.discoverServices(nil) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        await Self.onQueue(queue) { remote.discoverCharacteristics(nil, for: Self.service) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.control) } }
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.measurement], for: Self.service) }
        await waitFor { await Self.onQueue(queue) { !remote.isDiscovered(Self.control) } }
        #expect(await Self.onQueue(queue) { remote.discoveredCharacteristics(for: Self.service) } == [Self.measurement])
        // The battery service, discovered in the same sweep, is untouched: the replacement is
        // per service.
        #expect(await Self.onQueue(queue) { remote.isDiscovered(Self.batteryService) })
    }

    @Test("Dropping a service from the database invalidates it on every connected remote")
    func droppedServiceIsReportedAsModified() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handle = await radio.register(Self.device(identifier: identifier, name: "two", services: Self.twoServices))
        let queue = DispatchSerialQueue(label: "VirtualRadioTests.modify")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let remote = try await Self.discoveredRemote(radio: radio, backend: backend, queue: queue, identifier: identifier)
        let modified = Mutex<[[ServiceIdentifier]]>([])
        await Self.onQueue(queue) {
            remote.eventHandler = { event in
                if case .didModifyServices(let services) = event { modified.withLock { $0.append(services) } }
            }
        }
        await Self.onQueue(queue) { remote.setNotifyValue(true, for: Self.measurement) }
        await waitFor { await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 1 }

        // The device drops the heart-rate service — the hosted-host equivalent of a
        // `CBPeripheralManager` removing a published service.
        await handle.setServices([Self.twoServices[1]])

        await waitFor { modified.withLock { !$0.isEmpty } }
        #expect(modified.withLock { $0 } == [[Self.service]])
        // The remote pruned what went with it: the service, its characteristics, their
        // properties, and the notification it had armed under them.
        #expect(await Self.onQueue(queue) { !remote.isDiscovered(Self.service) })
        #expect(await Self.onQueue(queue) { remote.discoveredCharacteristics(for: Self.service).isEmpty })
        #expect(await Self.onQueue(queue) { !remote.isNotifying(Self.measurement) })
        // The service that stayed is still discovered.
        #expect(await Self.onQueue(queue) { remote.isDiscovered(Self.batteryService) })

        // A purely additive change invalidates nothing, so nothing more is reported.
        await handle.setServices(Self.twoServices)
        await Self.onQueue(queue) { remote.discoverServices(nil) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        #expect(modified.withLock { $0 } == [[Self.service]])
    }

    @Test("An invalidated service takes its subscriptions with it, and re-subscribing reports again")
    func droppedServiceDropsItsSubscriptions() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handler = RecordingHandler()
        let handle = await radio.register(
            VirtualDevice(
                descriptor: VirtualDeviceDescriptor(
                    identifier: identifier,
                    name: "two",
                    advertisement: AdvertisementData(serviceUUIDs: [Self.service], isConnectable: true),
                    services: Self.twoServices
                ),
                handler: handler
            )
        )
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        #expect(await radio.connect(session: session, device: identifier, sink: { _ in }).error == nil)
        #expect(
            await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session)
                .isNotifying
        )
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 1)
        #expect(handler.reported == [true])

        // The heart-rate service goes: the subscription under it goes with it, and the host is
        // told it lost that subscriber rather than being left holding a ghost.
        await handle.setServices([Self.twoServices[1]])
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(handler.reported == [true, false])

        // Re-added and re-subscribed, the transition is reported again — which the stale set
        // entry would have swallowed, leaving the central armed and the host unaware.
        await handle.setServices(Self.twoServices)
        #expect(
            await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session)
                .isNotifying
        )
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 1)
        #expect(handler.reported == [true, false, true])
    }

    @Test("A static value is refused when its characteristic declares no read or notify")
    func staticValueHonorsTheReadPermission() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        // Both carry a static value, so both are answered from the database rather than
        // through the handler — whose `read` fails everything, so an answer proves the
        // database served it.
        let published = GATTService(identifier: Self.service, characteristics: [
            GATTCharacteristic(
                identifier: Self.control,
                properties: [.write, .writeWithoutResponse],
                permissions: [.writeable],
                value: Data([0x2A])
            ),
            GATTCharacteristic(
                identifier: Self.measurement,
                properties: [.read],
                permissions: [.readable],
                value: Data([0, 0x48])
            )
        ])
        _ = await radio.register(Self.device(identifier: identifier, name: "static", services: [published]))
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        #expect(await radio.connect(session: session, device: identifier, sink: { _ in }).error == nil)

        // The write-only characteristic has a value the radio could answer with, and must not.
        let refused = await radio.read(device: identifier, characteristic: Self.control, session: session)
        #expect(refused == .failure(.readNotPermitted))

        // The readable one on the same device still answers from the database, so the refusal
        // above was the permission check and not the static path itself.
        let allowed = await radio.read(device: identifier, characteristic: Self.measurement, session: session)
        #expect(allowed == .success(Data([0, 0x48])))
    }

    /// The remote `backend` vends for `identifier`, fetched on its own queue.
    private static func remote(
        _ backend: VirtualCentralBackend,
        _ queue: DispatchSerialQueue,
        _ identifier: UUID
    ) async -> VirtualPeripheralRemote? {
        await onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [identifier]).first as? VirtualPeripheralRemote
        }
    }
}
/// ``FixtureDeviceHandler``'s read path: what a fixture device answers, and what it refuses.
@Suite("Fixture device reads")
struct FixtureDeviceReadTests {

    private static let json = """
    { "devices": [ { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "services": [ { "uuid": "180D",
      "characteristics": [
        { "uuid": "2A37", "properties": ["read"], "value": "AQIDBAU=" },
        { "uuid": "2A38", "properties": ["notify"], "value": "AQI=" },
        { "uuid": "2A39", "properties": ["write"] } ] } ] } ] }
    """
    private static let service = ServiceIdentifier(uuid: "180D")
    private static let readable = CharacteristicIdentifier(uuid: "2A37", service: service)
    private static let notifying = CharacteristicIdentifier(uuid: "2A38", service: service)
    private static let writeOnly = CharacteristicIdentifier(uuid: "2A39", service: service)
    private static let undeclared = CharacteristicIdentifier(uuid: "2A3A", service: service)
    private static let central = Subscriber(id: UUID(), maximumUpdateValueLength: 20)

    private func makeHandler() throws -> FixtureDeviceHandler {
        FixtureDeviceHandler(device: try FixtureDocument.parse(Data(Self.json.utf8)).devices[0])
    }

    @Test("A characteristic the fixture never declared reads as .attributeNotFound")
    func undeclaredCharacteristicIsNotFound() async throws {
        let handler = try makeHandler()
        let result = await handler.read(Self.undeclared, offset: 0, from: Self.central)
        #expect(result == .failure(.attributeNotFound))
    }

    @Test("A characteristic declaring neither read nor notify reads as .readNotPermitted")
    func writeOnlyCharacteristicIsNotReadable() async throws {
        let handler = try makeHandler()
        let result = await handler.read(Self.writeOnly, offset: 0, from: Self.central)
        #expect(result == .failure(.readNotPermitted))
    }

    @Test("A notify-only characteristic is readable — notify implies a value worth reading")
    func notifyOnlyCharacteristicIsReadable() async throws {
        let handler = try makeHandler()
        let result = await handler.read(Self.notifying, offset: 0, from: Self.central)
        #expect(result == .success(Data([1, 2])))
    }

    @Test("A read honors its offset, slicing the stored value")
    func readHonorsOffset() async throws {
        let handler = try makeHandler()
        #expect(await handler.read(Self.readable, offset: 0, from: Self.central) == .success(Data([1, 2, 3, 4, 5])))
        #expect(await handler.read(Self.readable, offset: 2, from: Self.central) == .success(Data([3, 4, 5])))
        // At the end: legal, and empty — how a long read learns it is done.
        #expect(await handler.read(Self.readable, offset: 5, from: Self.central) == .success(Data()))
    }

    @Test("An offset past the end of the value — or a negative one — is .invalidOffset")
    func offsetBeyondTheValueIsRejected() async throws {
        let handler = try makeHandler()
        #expect(await handler.read(Self.readable, offset: 6, from: Self.central) == .failure(.invalidOffset))
        #expect(await handler.read(Self.readable, offset: -1, from: Self.central) == .failure(.invalidOffset))
    }
}
#endif
