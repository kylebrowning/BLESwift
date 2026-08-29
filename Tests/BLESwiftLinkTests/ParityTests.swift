//
//  ParityTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftProvider
import BLESwiftSimulatorLink
import BLESwiftTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

/// Conformance parity: the link must be behaviorally indistinguishable from a local
/// backend.
///
/// One scenario — power on, scan, connect, read, write, subscribe, read RSSI, disconnect —
/// runs twice against the *same* scripted `FakeCentral`/`FakePeripheral` script:
///
/// - **A (local):** `Central` → `FakeCentral`, in-process.
/// - **B (linked):** `Central` → `LinkCentral` → socket → passthrough `Provider` whose
///   `centralBackendFactory` builds that same fake.
///
/// Both runs produce a log of observable values only (no timings, no call counts), and the
/// two logs must be identical. A difference is a defect in the link, not a reason to
/// loosen the comparison.
@Suite("Link vs local conformance parity")
struct ParityTests {

    // MARK: - Fixtures

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: heartRate)

    private static let deviceID = UUID(uuidString: "9C1E7A32-5B04-4E8D-8F6A-1D2B3C4E5F60")!
    private static let deviceName = "Parity Rig"

    private static let measurementValue = Data([0, 72])
    private static let notificationValue = Data([0, 99])
    private static let controlWrite = Data([0x2A])
    private static let scriptedRSSI = -61

    private static var identifier: PeripheralIdentifier {
        PeripheralIdentifier(uuid: deviceID, name: deviceName)
    }

    private static var advertisement: AdvertisementData {
        AdvertisementData(localName: deviceName, serviceUUIDs: [heartRate])
    }

    /// A `Sendable` hand-off for a fake the provider's backend factory builds on the
    /// session's own queue — `Mutex` is non-copyable, so it cannot live in a struct rig.
    private final class FakeBox<Fake: Sendable>: Sendable {
        private let storage = Mutex<Fake?>(nil)

        var value: Fake? { storage.withLock { $0 } }

        func store(_ fake: Fake) { storage.withLock { $0 = fake } }
    }

    // MARK: - The script

    /// The one script both runs apply, through the fakes' queue-confined setters.
    ///
    /// `simulateStateChange` is off-queue safe and hops onto the fake's queue itself; the
    /// setters are not, hence `onQueue`. Both fakes share one queue, so `fake.onQueue`
    /// covers the peripheral's setters too.
    private static func scriptFake(_ fake: FakeCentral, peripheral: FakePeripheral) async {
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {
            peripheral.availableServices = [heartRate: [measurement, control]]
            peripheral.scriptedProperties = [measurement: [.read, .notify], control: [.write]]
            peripheral.scriptedReadValues = [measurement: measurementValue]
            peripheral.scriptedRSSI = scriptedRSSI
            fake.retrievablePeripherals[deviceID] = peripheral
            fake.connectBehavior = .succeed
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The scenario

    /// Drives one `Central` through the full scenario, returning a log of everything it
    /// observed. Every entry is a value the API handed back — never a duration, a call
    /// count, or anything else that could differ legitimately between the two runs.
    private static func runScenario(
        central: Central,
        peripheralID: UUID,
        fake: FakeCentral,
        fakePeripheral: FakePeripheral
    ) async throws -> [String] {
        var log: [String] = []

        // State.
        await waitFor(timeout: .seconds(10)) { central.state == .poweredOn }
        log.append("state:\(central.state)")

        // Scan. The fake only advertises when told to, and a sighting delivered before the
        // scan request has crossed the socket would be dropped in run B — so sight it
        // repeatedly, identically in both runs, until the client's stream yields.
        let sightings = Task {
            while !Task.isCancelled {
                fake.simulateDiscovery(peripheral: identifier, advertisement: advertisement, rssi: scriptedRSSI)
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        var found: Discovery?
        for try await event in await central.scan(services: [heartRate], timeout: .seconds(10)) {
            if case .discovered(let discovery) = event, discovery.peripheral.uuid == peripheralID {
                found = discovery
                break
            }
        }
        sightings.cancel()
        let discovery = try #require(found)
        log.append("discovered:\(discovery.peripheral.name):\(discovery.peripheral.uuid)")

        // Connect.
        let peripheral = try await central.connect(discovery.peripheral)
        log.append("connected:\(peripheral.id.uuid)")

        // Read.
        let value: Data = try await peripheral.read(from: measurement)
        log.append("read:\(hex(value))")

        // Write, with response. `FakePeripheral.writeValue` auto-completes the write (no
        // `onWriteRequest` bridge hook is installed here), so nothing further is scripted.
        try await peripheral.write(controlWrite, to: control, type: .withResponse)
        log.append("wrote:\(control.uuidString)")

        // Subscribe, then notify. `Peripheral` exposes no "subscription is armed" signal,
        // so the notification is re-simulated until the stream yields — the same shape as
        // the sighting pump, and equally deterministic in both runs.
        let notifications: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: measurement)
        let notified = Task { () -> Data? in
            for try await packet in notifications { return packet }
            return nil
        }
        let pump = Task {
            while !Task.isCancelled {
                fakePeripheral.simulateNotification(for: measurement, value: notificationValue)
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        let packet = try await notified.value
        pump.cancel()
        log.append("notified:\(hex(try #require(packet)))")

        // RSSI.
        log.append("rssi:\(try await peripheral.readRSSI())")

        // Disconnect. `FakeCentral.cancelPeripheralConnection` records the call but never
        // delivers `didDisconnect`, so the disconnect is completed by simulating one —
        // identically in both runs. The pump sleeps first so the cancel has been issued
        // before the first simulated event lands.
        let disconnects = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                fake.simulateDisconnect(identifier, error: nil)
            }
        }
        try await central.disconnect(peripheral.id)
        disconnects.cancel()
        log.append("disconnected:\(peripheral.id.uuid)")

        return log
    }

    // MARK: - Run A: local

    /// The scenario against a `Central` sitting directly on the scripted fake.
    private func runLocal() async throws -> [String] {
        let queue = DispatchSerialQueue(label: "parity.local")
        let fake = FakeCentral(queue: queue, state: .poweredOn)
        let peripheral = FakePeripheral(identifier: Self.deviceID, name: Self.deviceName, queue: queue)
        // The `Central` is wired before the script runs, so it sees the `.poweredOn` event
        // the script delivers — exactly as the linked run's client does.
        let central = Central(backend: fake, queue: queue)
        await Self.scriptFake(fake, peripheral: peripheral)
        return try await Self.runScenario(
            central: central,
            peripheralID: Self.deviceID,
            fake: fake,
            fakePeripheral: peripheral
        )
    }

    // MARK: - Run B: linked

    /// The same scenario against a `Central` whose backend is a `LinkCentral` dialing a
    /// passthrough `Provider` that owns the very same kind of scripted fake.
    private func runLinked() async throws -> [String] {
        let centralBox = FakeBox<FakeCentral>()
        let peripheralBox = FakeBox<FakePeripheral>()

        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            // Called once, on the session's own queue. Only construction happens here; the
            // scripting is applied afterwards through `scriptFake`, so both runs are driven
            // by literally the same code.
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: Self.deviceName, queue: queue)
            centralBox.store(fake)
            peripheralBox.store(peripheral)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchSerialQueue(label: "parity.linked")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "parity",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: link, queue: queue)

        // The factory runs when the session is created, i.e. once the client's socket is
        // accepted — so wait for the fake before scripting it.
        await waitFor(timeout: .seconds(10)) { centralBox.value != nil && peripheralBox.value != nil }
        let fake = try #require(centralBox.value)
        let fakePeripheral = try #require(peripheralBox.value)
        await Self.scriptFake(fake, peripheral: fakePeripheral)

        let log = try await Self.runScenario(
            central: central,
            peripheralID: Self.deviceID,
            fake: fake,
            fakePeripheral: fakePeripheral
        )

        link.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        await provider.stop()
        return log
    }

    // MARK: - The parity assertion

    @Test("A linked central observes exactly what a local one observes")
    func linkedRunMatchesLocalRun() async throws {
        let logA = try await runLocal()
        let logB = try await runLinked()
        #expect(logA == logB, "A: \(logA)\nB: \(logB)")
    }
}
#endif
