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

    /// A scenario step that could not be completed — reported as a test failure rather than
    /// left to hang.
    private struct ParityFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs `operation` under the shared ten-second bound, giving up with a recorded failure
    /// instead of hanging the suite.
    ///
    /// Every step of this scenario simulates its stimulus exactly once, so a link that
    /// dropped or reordered that one message must surface as a timeout here — never as a
    /// silent retry that papers over the loss.
    private static func bounded<T: Sendable>(
        _ step: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        do {
            return try await BLESwiftLinkTests.bounded(step, operation)
        } catch let timeout as TimedOut {
            Issue.record("\(timeout)")
            return nil
        } catch {
            throw ParityFailure(description: "\(step): \(String(describing: error))")
        }
    }

    // MARK: - The scenario

    /// Drives one `Central` through the full scenario, returning a log of everything it
    /// observed. Every entry is a value the API handed back — never a duration, a call
    /// count, or anything else that could differ legitimately between the two runs.
    ///
    /// Each simulated stimulus fires **exactly once**, gated on the fake's own record that
    /// the corresponding request actually arrived (`scanCallCount`,
    /// `notifyingCharacteristics`, `cancelCallCounts`). That gate is what gives the suite
    /// its teeth: a link that dropped the first sighting, the first notification, or the
    /// disconnect would hang and be reported, not quietly retried into a pass.
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

        // Scan. The consumer is started first, then the scan request is awaited on the fake
        // — in run B that means it has crossed the socket — and only then is the single
        // sighting delivered.
        let events = await central.scan(services: [heartRate], timeout: .seconds(10))
        let discovering = Task { () async throws -> Discovery in
            for try await event in events {
                if case .discovered(let discovery) = event, discovery.peripheral.uuid == peripheralID {
                    return discovery
                }
            }
            throw ParityFailure(description: "the scan finished without sighting \(peripheralID)")
        }
        await waitFor(timeout: .seconds(10)) { await fake.onQueue { fake.scanCallCount == 1 } }
        fake.simulateDiscovery(peripheral: identifier, advertisement: advertisement, rssi: scriptedRSSI)
        let discovery = try #require(try await bounded("discovery") { try await discovering.value })
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

        // Subscribe, then notify once. `notifyingCharacteristics` is the fake's own record
        // that the subscribe landed, so it stands in for the "armed" signal `Peripheral`
        // does not expose.
        let notifications: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: measurement)
        let notified = Task { () async throws -> Data in
            for try await packet in notifications { return packet }
            throw ParityFailure(description: "the notification stream finished without a packet")
        }
        await waitFor(timeout: .seconds(10)) {
            await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(measurement) }
        }
        fakePeripheral.simulateNotification(for: measurement, value: notificationValue)
        let packet = try #require(try await bounded("notification") { try await notified.value })
        log.append("notified:\(hex(packet))")

        // RSSI.
        log.append("rssi:\(try await peripheral.readRSSI())")

        // Disconnect. `FakeCentral.cancelPeripheralConnection` records the call but never
        // delivers `didDisconnect`, so the one disconnect event is simulated — after the
        // fake has recorded the cancel, so the ordering is the same in both runs.
        let disconnecting = Task { () async throws -> Bool in
            try await central.disconnect(peripheral.id)
            return true
        }
        await waitFor(timeout: .seconds(10)) {
            await fake.onQueue { fake.cancelCallCounts[peripheralID] == 1 }
        }
        fake.simulateDisconnect(identifier, error: nil)
        #expect(try await bounded("disconnect") { try await disconnecting.value } == true)
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
        // accepted — so wait for the fake before scripting it. The window is generous because
        // the session may have to dial through a spell of the local stack refusing loopback
        // connects outright (`EADDRINUSE`), which on a machine running several test bundles at
        // once has been seen to last past ten seconds; the session redials every 50 ms
        // throughout, so the wait costs nothing when the first dial lands.
        await waitFor(timeout: .seconds(45)) { centralBox.value != nil && peripheralBox.value != nil }
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
