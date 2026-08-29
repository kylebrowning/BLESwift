//
//  VirtualRadioTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftProvider
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
        let (central, _, _) = try await makeRig()
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
        // `Peripheral` exposes no public "notifications are armed" signal, so the brief's
        // permitted fixed-delay fallback stands in for one.
        try await Task.sleep(for: .milliseconds(100))
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

    @Test("Removing a connected device disconnects the central with provider code 2")
    func removal() async throws {
        let (central, _, handle) = try await makeRig()
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        _ = try await central.connect(PeripheralIdentifier(uuid: id, name: nil))
        let events = Task { () -> (any Error)?? in
            for await event in await central.connectionEvents() {
                if case .disconnected(_, let error, _) = event { return .some(error) }
            }
            return .none
        }
        await handle.remove()
        let reported = try #require(try await bounded { await events.value })
        let nsError = try #require(reported) as NSError
        #expect(nsError.domain == "BLESwiftProvider")
        #expect(nsError.code == 2)
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
        let (central, _, handle) = try await makeRig()
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        let peripheral = try await central.connect(PeripheralIdentifier(uuid: id, name: nil))
        let task = Task { () -> Data? in
            for try await value in peripheral.notifications(for: Self.measurement) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        // See `gatt()` — no public arming signal, so the brief's fixed-delay fallback stands in.
        try await Task.sleep(for: .milliseconds(100))
        await handle.notify(Data([0, 99]), for: Self.measurement, to: nil)
        #expect(try await bounded { try await task.value } == Data([0, 99]))
    }
}
#endif
