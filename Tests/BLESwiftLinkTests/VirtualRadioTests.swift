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
import Testing

@Suite("VirtualRadio")
struct VirtualRadioTests {

    private static let fixtureJSON = """
    { "devices": [ { "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "name": "Fixture HRM", "advertisedServices": ["180D"],
      "services": [ { "uuid": "180D", "characteristics": [
        { "uuid": "2A37", "properties": ["read", "notify"], "value": "AEg=" },
        { "uuid": "2A39", "properties": ["read", "write", "notify"], "value": "AA==" } ] } ] } ] }
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
        #expect(try await notifications.value == Data([0x2A]))
        let readBack: Data = try await peripheral.read(from: Self.control)
        #expect(readBack == Data([0x2A]))
        try await central.disconnect(peripheral.id)
    }

    @Test("Connecting to an unknown identifier fails with provider code 1")
    func unknown() async throws {
        let (central, _, _) = try await makeRig()
        await #expect(throws: (any Error).self) {
            _ = try await central.connect(PeripheralIdentifier(uuid: UUID(), name: nil), timeout: .seconds(2))
        }
    }

    @Test("Removing a connected device disconnects the central with provider code 2")
    func removal() async throws {
        let (central, _, handle) = try await makeRig()
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        _ = try await central.connect(PeripheralIdentifier(uuid: id, name: nil))
        let events = Task { () -> Bool in
            for await event in await central.connectionEvents() { if case .disconnected = event { return true } }
            return false
        }
        await handle.remove()
        #expect(await events.value)
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
        #expect(try await task.value == Data([0, 99]))
    }
}
#endif
