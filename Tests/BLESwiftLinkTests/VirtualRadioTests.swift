//
//  VirtualRadioTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
@testable import BLESwiftSimulatorLink
@testable import BLESwiftVirtualRadio
import Dispatch
import Foundation
import BLESwiftCompat17
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
        let queue = DispatchQueue(label: "VirtualRadioTests")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
        await waitFor { central.state == .poweredOn }
        return (central, radio, handle)
    }

    /// A device registered under `identifier`. It advertises `name` and hosts `services`.
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

        let first = await radio.register(Self.device(identifier: identifier, name: "first", services: []))
        let second = await radio.register(Self.device(identifier: identifier, name: "second", services: [published]))
        #expect(first.generation != second.generation)

        // The old session's teardown lands *after* its successor registered. It is the sequence
        // that `HostSession.close()` runs (`stopAdvertising`, `removeAllHostedServices`,
        // `eventHandler = nil`), keyed by the identifier that both sessions share.
        await first.setAdvertising(false)
        await first.setServices([])
        await first.setAdvertisement(AdvertisementData(localName: "first", isConnectable: true))
        await first.remove()

        // The new registration is untouched. It is still there, and it still has generation 2's
        // state.
        #expect(radio.knownDeviceIDs.withLock { $0.contains(identifier) })
        #expect(await radio.name(of: identifier) == "second")
        #expect(await radio.services(of: identifier, matching: nil) == [Self.service])

        let queue = DispatchQueue(label: "VirtualRadioTests.generation")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
        await waitFor { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: [Self.service], timeout: .seconds(2)) {
            if case .discovered(let discovery) = event { found = discovery; break }
        }
        #expect(found?.peripheral.uuid == identifier)
        #expect(found?.advertisement.localName == "second")

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
        // `Peripheral` publishes no "notifications are armed" signal, so the test waits on the
        // radio's subscription table, which the push consults.
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
        // The backend never vends an identifier that it has never seen as a remote at all, so the
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

        // A device that this backend *has* sighted stays retrievable after the radio drops it. The
        // connect attempt then fails with the radio's error.
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
        // This is the shape of the provider's sessions: register a device, then build a backend and
        // look the identifier up in one synchronous flow, with no `waitFor` and no hop. A pushed
        // snapshot would not be there yet and would lose the race under CI load.
        let radio = VirtualRadio()
        let identifier = UUID()
        let (device, handler) = VirtualDevice.fixture(
            FixtureDevice(id: identifier, name: "Immediate", advertisedServices: [], services: [])
        )
        let handle = await radio.register(device)
        await handler.attach(handle)

        let queue = DispatchQueue(label: "VirtualRadioTests.immediate")
        let retrieved = queue.sync { () -> [UUID] in
            let backend = VirtualCentralBackend(radio: radio, queue: queue)
            return backend.retrievePeripherals(withIdentifiers: [identifier]).map(\.identifier)
        }
        #expect(retrieved == [identifier])

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
        // Subscribe here and not inside the task. `connectionEvents()` is a broadcast with no
        // replay. If the stream were created inside the task, `remove()` would win the race about
        // one run in ten, the `.disconnected` would go to nobody, and the test would hang on
        // `events.value`.
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
        /// Stands in for everything that a real sink closes over: a backend's remote and, through
        /// it, the session that the remote belongs to. Its lifetime *is* the sink's lifetime.
        final class Probe: Sendable {}

        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        let handle = await radio.register(device)
        await handler.attach(handle)
        let identifier = fixture.id
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })

        weak var afterDisconnect: Probe?
        do {
            let probe = Probe()
            afterDisconnect = probe
            #expect(await radio.connect(session: session, device: identifier, sink: { _ in _ = probe }).error == nil)
        }
        #expect(afterDisconnect != nil)
        await radio.disconnect(session: session, device: identifier)
        #expect(afterDisconnect == nil)

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
        let queue = DispatchQueue(label: "VirtualRadioTests.writes")
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

        // Discover first: a `PeripheralRemote` ignores GATT traffic on an undiscovered
        // characteristic, so a test that drives one directly must enumerate it as `Central` would,
        // one service at a time.
        await Self.onQueue(queue) { remote.discoverServices([Self.service]) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.control) } }

        // Two writes without response in one queue block, which is the `drainWrites` shape. Nothing
        // acknowledges them, so they land on the radio as queued work. An inversion depends on the
        // scheduler, so the test repeats them.
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
        let queue = DispatchQueue(label: "VirtualRadioTests.stopscan")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)

        // A scan that allows duplicates installs a repeater. If a `stopScan` reached the radio
        // first, the repeater would run forever against a scan that nobody asked for any more.
        for iteration in 0..<10 {
            await Self.onQueue(queue) {
                backend.scanForPeripherals(withServices: nil, options: ScanOptions(allowDuplicates: true))
                backend.stopScan()
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(await !radio.hasScanner(session: backend.sessionID), "iteration \(iteration)")
        }
    }

    /// Runs `body` on `queue` and returns its result. It does not block a cooperative thread.
    private static func onQueue<T: Sendable>(
        _ queue: DispatchQueue,
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
        // See `gatt()`. There is no public arming signal, so the test waits on the radio's
        // subscription table.
        await waitFor(timeout: .seconds(10)) { await radio.isSubscribed(characteristic: Self.measurement) }
        #expect(await radio.isSubscribed(characteristic: Self.measurement))
        await handle.notify(Data([0, 99]), for: Self.measurement, to: nil)
        #expect(try await bounded { try await task.value } == Data([0, 99]))
    }

    /// A device that answers no GATT traffic. The sighting-history tests only need it to exist and
    /// advertise.
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
        let queue = DispatchQueue(label: "VirtualRadioTests.sightings")
        // A history of one, so a second sighting is all that it takes to forget the first.
        let backend = VirtualCentralBackend(radio: radio, queue: queue, maximumDiscovered: 1)

        let sighted = Mutex<[UUID]>([])
        await Self.onQueue(queue) {
            backend.eventHandler = { event in
                if case .didDiscover(let peripheral, _, _) = event { sighted.withLock { $0.append(peripheral.uuid) } }
            }
        }

        /// Registers an advertising device and returns its handle after the backend has seen it.
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
        let oldest = await advertise()
        let newest = await advertise()
        #expect(sighted.withLock { $0 } == [oldest.id, newest.id])

        // Both devices leave the radio, so only the sighting history can still vend a remote for
        // them. The cap bounds exactly this.
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
        let queue = DispatchQueue(label: "VirtualRadioTests.remotecap")
        // A table of one, so the second remote is all that it takes to forget the first.
        let backend = VirtualCentralBackend(radio: radio, queue: queue, maximumDiscovered: 8, maximumRemotes: 1)
        let oldest = await Self.register(on: radio)
        let newest = await Self.register(on: radio)

        let first = try #require(await Self.remote(backend, queue, oldest))
        _ = await Self.remote(backend, queue, newest)

        // The remote is disconnected, so the cap was free to drop it. The identifier is still
        // known. A new retrieval creates a remote and does not return the forgotten one.
        let refetched = try #require(await Self.remote(backend, queue, oldest))
        #expect(refetched !== first)
    }

    @Test("The remote cap keeps a connected remote and re-files one it evicted")
    func remoteCapKeepsConnectedRemotesAndRefilesEvictedOnes() async throws {
        let radio = VirtualRadio()
        let queue = DispatchQueue(label: "VirtualRadioTests.remotecap.connected")
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

        // The test overflows the table of one while `live` is connected. A connected remote is
        // never a cap candidate, so the newcomer is filed next to it.
        let evicted = try #require(await Self.remote(backend, queue, other))
        #expect(await Self.remote(backend, queue, connected) === live)

        // `evicted` is disconnected, so the next retrieval displaces it. The connect files it again
        // anyway. Otherwise the caller would wait for a `didConnect` that nothing would ever send.
        _ = await Self.remote(backend, queue, filler)
        await Self.onQueue(queue) { backend.connect(evicted, options: nil, requiresANCS: false) }
        await waitFor(timeout: .seconds(5)) { events.withLock { $0.contains(other) } }
        #expect(events.withLock { $0.contains(other) })
    }

    @Test("A connect to a remote this backend has replaced fails instead of being dropped")
    func connectToAStaleRemoteFails() async throws {
        let radio = VirtualRadio()
        let queue = DispatchQueue(label: "VirtualRadioTests.staleconnect")
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
        // The overflow evicted the remote and the backend created it again, so the backend files a
        // *different* remote for `target`, and the radio would route events there.
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
        // The backend refused before it ever asked the radio, so the stale remote never left
        // `.disconnected`.
        #expect(await Self.onQueue(queue) { stale.connectionState } == .disconnected)
    }

    @Test("A read for a characteristic the remote has not discovered is a no-op")
    func undiscoveredReadIsANoOp() async throws {
        let radio = VirtualRadio()
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        let (device, handler) = VirtualDevice.fixture(fixture)
        await handler.attach(await radio.register(device))
        let queue = DispatchQueue(label: "VirtualRadioTests.undiscoveredread")
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

        // The remote is undiscovered. The radio is never asked, so no completion is delivered.
        await Self.onQueue(queue) { remote.readValue(for: Self.control) }

        // The discovery behind it is the barrier: both run on the same serial chain and queue, so
        // its completion cannot land before the read's would have. Discover one service at a time,
        // as `Central` does.
        await Self.onQueue(queue) { remote.discoverServices([Self.service]) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.control) } }
        #expect(values.withLock { $0 }.isEmpty)

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
        let queue = DispatchQueue(label: "VirtualRadioTests.undiscoveredchars")
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

        // The service was never discovered, so the radio is never asked and no completion arrives.
        // The same holds for `LinkPeripheral` and `CBPeripheral`, which has no `CBService` to pass
        // to `discoverCharacteristics(_:for:)`.
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }

        // The service discovery behind it is the barrier. Both run on the same serial chain, so its
        // completion cannot land before the refused call's completion would have landed.
        await Self.onQueue(queue) { remote.discoverServices([Self.service]) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        #expect(discovered.withLock { $0 }.isEmpty)
        #expect(await Self.onQueue(queue) { remote.discoveredCharacteristics(for: Self.service).isEmpty })

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
        let queue = DispatchQueue(label: "VirtualRadioTests.readafterdisconnect")
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
        // Do this one service at a time, because a characteristic discovery for a service that the
        // remote has not discovered yet does nothing. `Central` issues them in the same order.
        await Self.onQueue(queue) { remote.discoverServices([Self.service]) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.service) } }
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.control], for: Self.service) }
        await waitFor { await Self.onQueue(queue) { remote.isDiscovered(Self.control) } }

        await Self.onQueue(queue) { backend.cancelPeripheralConnection(remote) }
        await waitFor { await Self.onQueue(queue) { remote.connectionState == .disconnected } }
        // The disconnect emptied the discovery caches, as a `LinkPeripheral`'s `markDisconnected()`
        // does, so the read never leaves the remote at all.
        #expect(await Self.onQueue(queue) { !remote.isDiscovered(Self.control) })
        #expect(await Self.onQueue(queue) { remote.discoveredServices.isEmpty })
        #expect(await Self.onQueue(queue) { remote.properties(of: Self.control) == [] })

        // `readRSSI()` is the barrier. It always completes on the same queue, so when its event
        // lands, a read's event would have landed by now.
        await Self.onQueue(queue) {
            remote.readValue(for: Self.control)
            remote.readRSSI()
        }
        await waitFor { rssis.withLock { !$0.isEmpty } }
        #expect(values.withLock { $0 }.isEmpty)

        // The radio also refuses the write on its own account, for any caller that reaches past the
        // remote's cache. `2A39` has a static value, so only the connection gate can refuse it.
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
        let hostQueue = DispatchQueue(label: "VirtualRadioTests.ghost.host")
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

        // The remote was never connected. Nothing is armed, nothing is filed, and nobody tells the
        // host anything.
        #expect(await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session).isNotifying == false)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(await host.subscribers(for: Self.measurement).isEmpty)

        // Connected: the very same call takes effect. So the gate caused the refusal above, not the
        // characteristic.
        #expect(await radio.connect(session: session, device: identifier, sink: { _ in }).error == nil)
        #expect(await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session).isNotifying == true)
        await waitFor { await !host.subscribers(for: Self.measurement).isEmpty }
        #expect(await host.subscribers(for: Self.measurement).count == 1)

        // Disconnected again: the radio drops the subscription. A `setNotify` from the stale
        // session cannot plant a new subscription behind it.
        await radio.disconnect(session: session, device: identifier)
        await waitFor { await host.subscribers(for: Self.measurement).isEmpty }
        #expect(await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session).isNotifying == false)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(await host.subscribers(for: Self.measurement).isEmpty)

        await radio.detach(session: session)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
    }

    /// Records every write that the radio passes down, and accepts all of them.
    private final class WriteRecordingHandler: VirtualDeviceHandler, Sendable {
        private let writes = Mutex<[Data]>([])

        /// Every write that reached this handler, in order.
        var received: [Data] { writes.withLock { $0 } }

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.unlikelyError)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            writes.withLock { $0.append(contentsOf: entries.map(\.value)) }
            return .success(())
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
    }

    @Test("Each write type carries its own ceiling: one refuses, the other drops")
    func writeLengthCeilingsMatchTheWriteType() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handler = WriteRecordingHandler()
        let writable = GATTService(identifier: Self.service, characteristics: [
            GATTCharacteristic(
                identifier: Self.control,
                properties: [.write, .writeWithoutResponse],
                permissions: [.writeable]
            )
        ])
        _ = await radio.register(
            VirtualDevice(
                descriptor: VirtualDeviceDescriptor(
                    identifier: identifier,
                    advertisement: AdvertisementData(serviceUUIDs: [Self.service], isConnectable: true),
                    services: [writable]
                ),
                handler: handler
            )
        )
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        #expect(await radio.connect(session: session, device: identifier, sink: { _ in }).error == nil)

        /// Writes `count` bytes of `type`. It returns the `ATTError` that refused the write, or
        /// `nil` when the radio served the write. `Result<Void, _>` is not `Equatable`.
        func write(_ count: Int, _ type: WriteType) async -> ATTError? {
            let result = await radio.write(
                device: identifier,
                characteristic: Self.control,
                value: Data(repeating: 0x2A, count: count),
                type: type,
                session: session
            )
            guard case .failure(let error) = result else { return nil }
            return error
        }

        // 400 bytes without response. One ATT packet on hardware cannot carry them, so
        // CoreBluetooth drops the write and nothing reaches the device.
        #expect(await write(400, .withoutResponse) == nil)
        #expect(handler.received.isEmpty)

        #expect(await write(400, .withResponse) == nil)
        #expect(handler.received.map(\.count) == [400])

        #expect(await write(513, .withResponse) == .invalidAttributeValueLength)
        #expect(handler.received.map(\.count) == [400])

        #expect(await write(VirtualRadio.maximumWriteWithoutResponseLength, .withoutResponse) == nil)
        #expect(await write(VirtualRadio.maximumValueLength, .withResponse) == nil)
        #expect(handler.received.map(\.count) == [400, VirtualRadio.maximumWriteWithoutResponseLength, 512])

        let queue = DispatchQueue(label: "VirtualRadioTests.ceilings")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        await waitFor { await Self.onQueue(queue) { !backend.retrievePeripherals(withIdentifiers: [identifier]).isEmpty } }
        let remote = try #require(await Self.remote(backend, queue, identifier))
        #expect(await Self.onQueue(queue) { remote.maximumWriteValueLength(for: .withResponse) } == 512)
        #expect(await Self.onQueue(queue) { remote.maximumWriteValueLength(for: .withoutResponse) } == 182)
    }

    /// Records the `maximumUpdateValueLength` of every subscriber for which the radio reports a
    /// subscription change.
    private final class SubscriberRecordingHandler: VirtualDeviceHandler, Sendable {
        private let maxima = Mutex<[Int]>([])

        /// The maximum of every reported subscriber, in order.
        var reported: [Int] { maxima.withLock { $0 } }

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.unlikelyError)
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .failure(.unlikelyError)
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
            maxima.withLock { $0.append(central.maximumUpdateValueLength) }
        }
    }

    @Test("A subscriber reports one ATT packet, and a longer notification is truncated to it")
    func notificationsAreTruncatedToTheSubscribersMaximum() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handler = SubscriberRecordingHandler()
        let handle = await radio.register(
            VirtualDevice(
                descriptor: VirtualDeviceDescriptor(
                    identifier: identifier,
                    name: "truncating",
                    advertisement: AdvertisementData(serviceUUIDs: [Self.service], isConnectable: true),
                    services: Self.twoServices
                ),
                handler: handler
            )
        )
        let session = UUID()
        await radio.attach(session: session, centralSink: { _ in })
        let values = Mutex<[Data]>([])
        #expect(await radio.connect(session: session, device: identifier, sink: { event in
            guard case .didUpdateValue(_, let value, _) = event, let value else { return }
            values.withLock { $0.append(value) }
        }).error == nil)
        #expect(
            await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session)
                .isNotifying
        )

        // A notification is one ATT packet with no long-write equivalent, so a device handler's
        // subscriber reports ATT_MTU - 3, the same ceiling as a `.withoutResponse` write, and not
        // the 512-byte attribute maximum.
        #expect(handler.reported == [VirtualRadio.maximumWriteWithoutResponseLength])
        #expect(VirtualRadio.maximumWriteWithoutResponseLength == 182)

        // The value exceeds the subscriber's `maximumUpdateValueLength`. The radio clips it, as
        // CoreBluetooth clips a notification that does not fit the MTU.
        await handle.notify(Data(repeating: 0x7F, count: 500), for: Self.measurement, to: nil)
        await waitFor { values.withLock { !$0.isEmpty } }
        #expect(values.withLock { $0 }.map(\.count) == [VirtualRadio.maximumWriteWithoutResponseLength])

        let full = Data(repeating: 0x2A, count: VirtualRadio.maximumWriteWithoutResponseLength)
        await handle.notify(full, for: Self.measurement, to: nil)
        await waitFor { values.withLock { $0.count } == 2 }
        #expect(values.withLock { $0 }.last == full)

        await handle.notify(Data(repeating: 0x01, count: 8), for: Self.measurement, to: nil)
        await waitFor { values.withLock { $0.count } == 3 }
        #expect(values.withLock { $0 }.last == Data(repeating: 0x01, count: 8))
    }

    /// Records every `subscriptionChanged` that the radio reports, so a test can assert on exactly
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

        // Disabling a characteristic that was never enabled is not an unsubscribe. The host never
        // had this subscriber, so the radio must not tell it that it lost one.
        #expect(await setNotify(false) == false)
        #expect(handler.reported.isEmpty)

        // The first enable is the transition. The second enable changes nothing and reports
        // nothing.
        #expect(await setNotify(true) == true)
        #expect(await setNotify(true) == true)
        #expect(handler.reported == [true])
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 1)

        #expect(await setNotify(false) == false)
        #expect(await setNotify(false) == false)
        #expect(handler.reported == [true, false])
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
    }

    @Test("Notifying a characteristic that declares no notify or indicate is refused")
    func setNotifyEnforcesTheNotifiableProperty() async throws {
        let radio = VirtualRadio()
        let hostQueue = DispatchQueue(label: "VirtualRadioTests.notifiable.host")
        let identifier = UUID()
        let host = PeripheralHost(
            backend: VirtualPeripheralManagerBackend(radio: radio, queue: hostQueue, identifier: identifier),
            queue: hostQueue
        )
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

        // A characteristic that is not in the database at all is refused in the same way as a read
        // or a write of it.
        let missing = await radio.setNotify(true, device: identifier, characteristic: Self.measurement, session: session)
        #expect(missing.isNotifying == false)
        #expect(missing.error == .attributeNotFound)
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(await host.subscribers(for: Self.measurement).isEmpty)
    }

    /// A second service, so a discovery can be narrowed and a database can drop one.
    private static let batteryService = ServiceIdentifier(uuid: "180F")
    private static let batteryLevel = CharacteristicIdentifier(uuid: "2A19", service: batteryService)

    /// A device that hosts the heart-rate and battery services. It is connected to `backend`. Both
    /// services and the heart rate's characteristics are already discovered.
    private static func discoveredRemote(
        radio: VirtualRadio,
        backend: VirtualCentralBackend,
        queue: DispatchQueue,
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

    @Test("A cancel on an already-disconnected remote delivers nothing")
    func cancelOnADisconnectedRemoteIsANoOp() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handle = await radio.register(Self.device(identifier: identifier, name: "cancel", services: Self.twoServices))
        let queue = DispatchQueue(label: "VirtualRadioTests.cancel")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let remote = try await Self.discoveredRemote(radio: radio, backend: backend, queue: queue, identifier: identifier)

        let disconnects = Mutex<Int>(0)
        await Self.onQueue(queue) {
            backend.eventHandler = { event in
                if case .didDisconnect = event { disconnects.withLock { $0 += 1 } }
            }
        }

        await handle.remove()
        await waitFor { disconnects.withLock { $0 } == 1 }
        await waitFor { await Self.onQueue(queue) { remote.connectionState == .disconnected } }

        // The cancel that follows has nothing to cancel. CoreBluetooth would report nothing for it
        // either.
        await Self.onQueue(queue) { backend.cancelPeripheralConnection(remote) }
        // The wait covers the radio round-trip that a cancel would take and the queue hop that its
        // `didDisconnect` would return on. This is a negative assertion, so it gets every chance to
        // fail.
        try? await Task.sleep(for: .milliseconds(50))
        _ = await radio.generation(of: identifier)
        await Self.onQueue(queue) {}
        #expect(await Self.onQueue(queue) { remote.connectionState == .disconnected })
        #expect(disconnects.withLock { $0 } == 1)
    }

    @Test("Completions arrive in the order their calls were made, radio round-trip or not")
    func offChainCompletionsKeepCallOrder() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        _ = await radio.register(Self.device(identifier: identifier, name: "order", services: Self.twoServices))
        let queue = DispatchQueue(label: "VirtualRadioTests.order")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let remote = try await Self.discoveredRemote(radio: radio, backend: backend, queue: queue, identifier: identifier)

        let events = Mutex<[String]>([])
        await Self.onQueue(queue) {
            remote.eventHandler = { event in
                switch event {
                case .didDiscoverCharacteristics: events.withLock { $0.append("characteristics") }
                case .didDiscoverDescriptors: events.withLock { $0.append("descriptors") }
                case .didReadRSSI: events.withLock { $0.append("rssi") }
                case .didOpenL2CAPChannel: events.withLock { $0.append("l2cap") }
                default: break
                }
            }
            // One queue turn. The first call needs a radio round-trip. The three calls behind it do
            // not. If the radio answered them off the chain, each of them overtook the first call.
            remote.discoverCharacteristics(nil, for: Self.service)
            remote.discoverDescriptors(for: Self.measurement)
            remote.readRSSI()
            remote.openL2CAPChannel(L2CAPPSM(0x0041))
        }

        await waitFor { events.withLock { $0.count } == 4 }
        #expect(events.withLock { $0 } == ["characteristics", "descriptors", "rssi", "l2cap"])
    }

    /// Both services. The heart rate carries its measurement and control point.
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

    @Test("A narrowed discovery joins the caches; an unfiltered one replaces them")
    func filteredDiscoveryJoinsTheCaches() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handle = await radio.register(Self.device(identifier: identifier, name: "two", services: Self.twoServices))
        let queue = DispatchQueue(label: "VirtualRadioTests.replace")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let remote = try await Self.discoveredRemote(radio: radio, backend: backend, queue: queue, identifier: identifier)

        #expect(await Self.onQueue(queue) { Set(remote.discoveredServices) } == [Self.service, Self.batteryService])
        #expect(await Self.onQueue(queue) { Set(remote.discoveredCharacteristics(for: Self.service)) } == [Self.measurement, Self.control])

        // The test awaits each service discovery's completion, because a discovery that changes
        // nothing in the cache gives nothing to poll for.
        let discoveries = Mutex<Int>(0)
        await Self.onQueue(queue) {
            remote.eventHandler = { event in
                if case .didDiscoverServices = event { discoveries.withLock { $0 += 1 } }
            }
        }
        @Sendable func discover(_ services: [ServiceIdentifier]?) async {
            let before = discoveries.withLock { $0 }
            await Self.onQueue(queue) { remote.discoverServices(services) }
            await waitFor { discoveries.withLock { $0 } > before }
        }

        // A discovery narrowed to one service says nothing about other services, so it joins the
        // cache instead of replacing it. `GATTCompatibility.discovery` defaults to `.filtered`.
        // Pruning would leave the heart rate's characteristics discovered on the client and gone on
        // the provider, and a read under them would never answer.
        await discover([Self.batteryService])
        #expect(await Self.onQueue(queue) { Set(remote.discoveredServices) } == [Self.service, Self.batteryService])
        #expect(await Self.onQueue(queue) { Set(remote.discoveredCharacteristics(for: Self.service)) } == [Self.measurement, Self.control])
        #expect(await Self.onQueue(queue) { remote.properties(of: Self.measurement) } == [.read, .notify])

        // A narrowed *characteristic* discovery still replaces the entries of that service. That
        // answer does describe the whole of the one service that the discovery asked about.
        await Self.onQueue(queue) { remote.discoverCharacteristics([Self.measurement], for: Self.service) }
        await waitFor { await Self.onQueue(queue) { !remote.isDiscovered(Self.control) } }
        #expect(await Self.onQueue(queue) { remote.discoveredCharacteristics(for: Self.service) } == [Self.measurement])
        // The battery service, which the same sweep discovered, is untouched. The replacement is
        // per service.
        #expect(await Self.onQueue(queue) { remote.isDiscovered(Self.batteryService) })

        // An unfiltered discovery does describe the whole database, so the client no longer reports
        // as discovered a service that has since disappeared from it.
        await handle.setServices([Self.twoServices[0]])
        await discover(nil)
        #expect(await Self.onQueue(queue) { remote.discoveredServices } == [Self.service])
        #expect(await Self.onQueue(queue) { remote.discoveredCharacteristics(for: Self.batteryService).isEmpty })
        #expect(await Self.onQueue(queue) { remote.properties(of: Self.batteryLevel) } == [])
    }

    @Test("Dropping a service from the database invalidates it on every connected remote")
    func droppedServiceIsReportedAsModified() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handle = await radio.register(Self.device(identifier: identifier, name: "two", services: Self.twoServices))
        let queue = DispatchQueue(label: "VirtualRadioTests.modify")
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

        // The device drops the heart-rate service. This is the hosted-host equivalent of a
        // `CBPeripheralManager` that removes a published service.
        await handle.setServices([Self.twoServices[1]])

        await waitFor { modified.withLock { !$0.isEmpty } }
        #expect(modified.withLock { $0 } == [[Self.service]])
        // The remote pruned what went with the service: the service, its characteristics, their
        // properties, and the notification that it had armed under them.
        #expect(await Self.onQueue(queue) { !remote.isDiscovered(Self.service) })
        #expect(await Self.onQueue(queue) { remote.discoveredCharacteristics(for: Self.service).isEmpty })
        #expect(await Self.onQueue(queue) { !remote.isNotifying(Self.measurement) })
        #expect(await Self.onQueue(queue) { remote.isDiscovered(Self.batteryService) })

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

        // The heart-rate service goes. The subscription under it goes with it. The host is told
        // that it lost that subscriber, so it is not left to hold a ghost.
        await handle.setServices([Self.twoServices[1]])
        #expect(await radio.subscriberCount(device: identifier, characteristic: Self.measurement) == 0)
        #expect(handler.reported == [true, false])

        // Add the service and subscribe again. The radio reports the transition again. A stale set
        // entry would swallow it and leave the central armed without the host knowing.
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
        // Both characteristics carry a static value, so the database answers them. The handler's
        // `read` fails everything, so an answer proves the database served it.
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

        // The write-only characteristic has a value that the radio could answer with, and it must
        // not.
        let refused = await radio.read(device: identifier, characteristic: Self.control, session: session)
        #expect(refused == .failure(.readNotPermitted))

        // The readable characteristic on the same device still answers from the database, so the
        // permission check caused the refusal above and not the static path.
        let allowed = await radio.read(device: identifier, characteristic: Self.measurement, session: session)
        #expect(allowed == .success(Data([0, 0x48])))
    }

    @Test("A radio with a fixture attached deallocates once its last strong reference drops")
    func fixtureAttachmentDoesNotRetainTheRadio() async throws {
        let fixture = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices[0]
        weak var weakRadio: VirtualRadio?
        // The handler outlives the scope, so the only path that could keep the radio alive is the
        // handle it was attached with. This test guards against that cycle.
        var retainedHandler: FixtureDeviceHandler?
        do {
            let radio = VirtualRadio()
            weakRadio = radio
            let (device, handler) = VirtualDevice.fixture(fixture)
            await handler.attach(radio.register(device))
            retainedHandler = handler
            #expect(weakRadio != nil)
        }
        #expect(weakRadio == nil)
        #expect(retainedHandler != nil)
        retainedHandler = nil
    }

    /// The remote that `backend` vends for `identifier`, fetched on its own queue.
    private static func remote(
        _ backend: VirtualCentralBackend,
        _ queue: DispatchQueue,
        _ identifier: UUID
    ) async -> VirtualPeripheralRemote? {
        await onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [identifier]).first as? VirtualPeripheralRemote
        }
    }
}
/// The read path of ``FixtureDeviceHandler``: what a fixture device answers, and what it refuses.
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
        #expect(await handler.read(Self.readable, offset: 5, from: Self.central) == .success(Data()))
    }

    @Test("An offset past the end of the value — or a negative one — is .invalidOffset")
    func offsetBeyondTheValueIsRejected() async throws {
        let handler = try makeHandler()
        #expect(await handler.read(Self.readable, offset: 6, from: Self.central) == .failure(.invalidOffset))
        #expect(await handler.read(Self.readable, offset: -1, from: Self.central) == .failure(.invalidOffset))
    }
}

/// Per-service (filtered) discovery over the link, against a two-service fixture device.
///
/// `GATTCompatibility.discovery` defaults to `.filtered`, so `Central` asks for one service at a
/// time. A discovery answer that replaces the cache instead of joining it breaks this.
@Suite("Filtered service discovery over the link")
struct FilteredDiscoveryTests {

    /// A heart-rate service and a battery service on one device, so a per-service discovery of
    /// either one leaves the other already discovered.
    private static let fixtureJSON = """
    { "devices": [ { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "Fixture Multi",
      "advertisedServices": ["180D"], "services": [
        { "uuid": "180D", "characteristics": [
          { "uuid": "2A37", "properties": ["read", "notify"], "value": "AEg=" } ] },
        { "uuid": "180F", "characteristics": [
          { "uuid": "2A19", "properties": ["read"], "value": "ZA==" } ] } ] } ] }
    """
    private static let deviceID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let battery = ServiceIdentifier(uuid: "180F")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)
    private static let batteryLevel = CharacteristicIdentifier(uuid: "2A19", service: battery)

    /// A provider that serves the two-service fixture on a system-assigned loopback port.
    private func makeProvider() async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.fixtures = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices
        let provider = Provider(configuration: configuration)
        try await provider.start()
        return provider
    }

    /// A real `Central` on a `LinkCentral` that dials `provider`. It is already powered on and
    /// connected to the fixture device.
    private func connect(to provider: Provider, label: String) async throws -> (Central, LinkCentral, Peripheral) {
        let queue = DispatchQueue(label: label)
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "filtered",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor(timeout: .seconds(10)) { central.state == .poweredOn }
        var found: Discovery?
        for try await event in await central.scan(services: [Self.heartRate], timeout: .seconds(10)) {
            if case .discovered(let discovery) = event {
                found = discovery
                break
            }
        }
        let discovered = try #require(found)
        let peripheral = try await central.connect(discovered.peripheral)
        return (central, link, peripheral)
    }

    @Test("Reading under a second service leaves the first service's characteristics readable")
    func filteredDiscoveryKeepsTheEarlierService() async throws {
        let provider = try await makeProvider()
        let (_, link, peripheral) = try await connect(to: provider, label: "filtered.read")

        let first: Data = try await bounded("read A") { try await peripheral.read(from: Self.measurement) }
        #expect(first == Data([0, 0x48]))

        // Discovery of the battery service must not evict the heart rate service from either half
        // of the seam, or anything discovered beneath it.
        let level: Data = try await bounded("read B") { try await peripheral.read(from: Self.batteryLevel) }
        #expect(level == Data([0x64]))

        // This read timed out in the original bug. `Central` rediscovers the service, which is
        // cheap, and skips characteristic discovery because its cache kept the characteristic. The
        // read then reaches a provider that had pruned it, and the provider drops the read.
        let again: Data = try await bounded("read A again") { try await peripheral.read(from: Self.measurement) }
        #expect(again == Data([0, 0x48]))

        link.shutdown()
        await provider.stop()
    }

    @Test("Subscribing under a service discovered before a second one still arms")
    func filteredDiscoveryKeepsTheEarlierServiceSubscribable() async throws {
        let provider = try await makeProvider()
        let (_, link, peripheral) = try await connect(to: provider, label: "filtered.notify")

        _ = try await bounded("read A") { try await peripheral.read(from: Self.measurement) as Data }
        _ = try await bounded("read B") { try await peripheral.read(from: Self.batteryLevel) as Data }

        let notifications: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: Self.measurement)
        let armed = Task { () -> Data? in
            for try await value in notifications { return value }
            return nil
        }
        // The radio's own subscription table is the state that the push consults, so it replaces
        // the "armed" signal that `Peripheral` does not publish.
        await waitFor(timeout: .seconds(10)) { await provider.radio.isSubscribed(characteristic: Self.measurement) }
        #expect(await provider.radio.isSubscribed(characteristic: Self.measurement))

        armed.cancel()
        link.shutdown()
        await provider.stop()
    }
}
#endif
