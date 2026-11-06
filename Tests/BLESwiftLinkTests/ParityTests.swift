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
import BLESwiftCompat17
import Testing

/// Conformance parity: the link must be behaviorally indistinguishable from a local backend.
///
/// One scenario runs twice against the *same* scripted `FakeCentral` and `FakePeripheral` script:
/// power on, scan, connect, read, write, subscribe, read RSSI, disconnect.
///
/// - **A (local):** `Central` to `FakeCentral`, in-process.
/// - **B (linked):** `Central` to `LinkCentral` to socket to passthrough `Provider`, whose
///   `centralBackendFactory` builds that same fake.
///
/// Each run logs observable values only, with no timings or call counts. The two logs must be
/// identical. A difference is a defect in the link, not a reason to loosen the comparison.
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

    /// A `Sendable` hand-off for a fake that the provider's backend factory builds on the session's
    /// queue. `Mutex` is non-copyable, so it cannot live in a struct rig.
    private final class FakeBox<Fake: Sendable>: Sendable {
        private let storage = Mutex<Fake?>(nil)

        var value: Fake? { storage.withLock { $0 } }

        func store(_ fake: Fake) { storage.withLock { $0 = fake } }
    }

    // MARK: - The script

    /// The one script that both runs apply, through the queue-confined setters of the fakes.
    ///
    /// `simulateStateChange` is safe off the queue. The setters are not, so they go through
    /// `onQueue`. Both fakes share one queue, so `fake.onQueue` covers the peripheral's setters
    /// too.
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

    /// A scenario step that the test could not complete. The test reports it as a test failure and
    /// does not leave the step to hang.
    private struct ParityFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs `operation` under the shared ten-second bound and records a failure instead of hanging
    /// the suite.
    ///
    /// Each step simulates its stimulus exactly once, so a link that dropped or reordered that
    /// message appears as a timeout, never as a silent retry.
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

    /// Drives one `Central` through the full scenario and returns a log of everything that it
    /// observed. Entries are API values only, with nothing that could legitimately differ between
    /// the two runs.
    ///
    /// Each simulated stimulus fires **exactly once**, gated on the fake's record that the request
    /// arrived (`scanCallCount`, `notifyingCharacteristics`, `cancelCallCounts`). A link that
    /// dropped a sighting, a notification, or the disconnect would hang and be reported, not be
    /// retried into a pass.
    private static func runScenario(
        central: Central,
        peripheralID: UUID,
        fake: FakeCentral,
        fakePeripheral: FakePeripheral
    ) async throws -> [String] {
        var log: [String] = []

        await waitFor(timeout: .seconds(10)) { central.state == .poweredOn }
        log.append("state:\(central.state)")

        // Scan. The test starts the consumer, then awaits the scan request on the fake. In run B
        // the request has then crossed the socket. Only then does it deliver the single sighting.
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

        let peripheral = try await central.connect(discovery.peripheral)
        log.append("connected:\(peripheral.id.uuid)")

        let value: Data = try await peripheral.read(from: measurement)
        log.append("read:\(hex(value))")

        // Write, with response. `FakePeripheral.writeValue` completes the write itself, because no
        // `onWriteRequest` hook is installed.
        try await peripheral.write(controlWrite, to: control, type: .withResponse)
        log.append("wrote:\(control.uuidString)")

        // Subscribe, then notify once. `notifyingCharacteristics` is the fake's record that the
        // subscribe landed, so it replaces the "armed" signal that `Peripheral` does not expose.
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

        log.append("rssi:\(try await peripheral.readRSSI())")

        // Disconnect. `FakeCentral.cancelPeripheralConnection` never delivers `didDisconnect`, so
        // the test simulates it once, after the fake recorded the cancel. The ordering is the same
        // in both runs.
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

    /// The scenario against a `Central` that sits directly on the scripted fake.
    private func runLocal() async throws -> [String] {
        let queue = DispatchQueue(label: "parity.local")
        let fake = FakeCentral(queue: queue, state: .poweredOn)
        let peripheral = FakePeripheral(identifier: Self.deviceID, name: Self.deviceName, queue: queue)
        // The test wires the `Central` before the script runs, so it sees the `.poweredOn` event
        // that the script delivers, exactly as the client of the linked run does.
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

    /// The same scenario against a `Central` whose backend is a `LinkCentral`. The `LinkCentral`
    /// dials a passthrough `Provider` that owns the same kind of scripted fake.
    private func runLinked() async throws -> [String] {
        let centralBox = FakeBox<FakeCentral>()
        let peripheralBox = FakeBox<FakePeripheral>()

        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        configuration.passthrough = true
        configuration.centralBackendFactory = { queue in
            // The factory calls this once, on the session's queue, and only constructs. The test
            // scripts afterwards through `scriptFake`, so the same code drives both runs.
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            let peripheral = FakePeripheral(identifier: Self.deviceID, name: Self.deviceName, queue: queue)
            centralBox.store(fake)
            peripheralBox.store(peripheral)
            return fake
        }
        let provider = Provider(configuration: configuration)
        try await provider.start()

        let queue = DispatchQueue(label: "parity.linked")
        let link = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port),
            queue: queue,
            clientName: "parity",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: link, queue: queue)

        // The factory runs when the session is created, when the client's socket is accepted, so
        // the test waits for the fake before it scripts it. The window is generous. The local stack
        // can refuse loopback connects outright (`EADDRINUSE`) for more than ten seconds when
        // several test bundles run at once. The session redials every 50 ms, so the wait costs
        // nothing when the first dial lands.
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
