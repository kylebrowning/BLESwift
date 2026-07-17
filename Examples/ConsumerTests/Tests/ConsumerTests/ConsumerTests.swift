//
//  ConsumerTests.swift
//  ConsumerTests
//
//  BLESwift's out-of-package consumer proof (plans/03-core-split-and-testsupport.md,
//  Phase T3): every test here is written exactly as an outside consumer would write it —
//  `import BLESwift`, `import BLESwiftCore`, `import BLESwiftTestSupport`, and nothing else.
//  No test-only import attribute, and no reach into anything `package`-visibility: this
//  package depends on the root package only by path, the same way any real consumer's
//  `Package.swift` would depend on a published BLESwift release. A green `swift test` here
//  is the actual proof that the shipped test-support story (`FakeCentral`, `FakePeripheral`,
//  and `Central`'s public `init(backend:queue:...)`) works end to end with no special
//  access — see the "Testing Your BLE Code" DocC article in `BLESwiftTestSupport` for the
//  narrated version of the rig pattern these tests use.
//

import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Foundation
import Testing

@Suite("Consumer proof — BLESwift + BLESwiftTestSupport from outside the package")
struct ConsumerTests {

    // MARK: - Rig construction

    @Test("The documented 4-line rig: a shared queue, a FakeCentral/FakePeripheral pair, and Central(backend:queue:)")
    func rigConstruction() {
        // 1. One serial queue, shared by every fake and by `Central` itself — this is the
        //    queue-confined contract's foundation (see `FakeCentral`'s doc comment).
        let queue = DispatchSerialQueue(label: "ConsumerTests.rigConstruction")
        // 2. The fakes, confined to that queue.
        let fakeCentral = FakeCentral(queue: queue)
        let fakePeripheral = FakePeripheral(queue: queue)
        // 3. `Central`'s public backend initializer — no hardware, no special test access.
        let central = Central(backend: fakeCentral, queue: queue)

        #expect(fakeCentral.onQueue { fakeCentral.radioState } == .unknown)
        _ = central
        _ = fakePeripheral
    }

    // MARK: - Power-on, connect, and a GATT read/decode round trip

    @Test("Power on the radio, connect, and read-decode a heart rate measurement")
    func powerOnConnectAndRead() async throws {
        let queue = DispatchSerialQueue(label: "ConsumerTests.powerOnConnectAndRead")
        let fakeCentral = FakeCentral(queue: queue)
        let fakePeripheral = FakePeripheral(queue: queue)
        let central = Central(backend: fakeCentral, queue: queue)

        // Wait for the radio to power on before doing anything else — the same pattern
        // every BLESwift app follows against real hardware (see "Getting Started").
        fakeCentral.simulateStateChange(.poweredOn)
        for await state in await central.stateEvents() {
            if state == .poweredOn { break }
        }

        // The fake stands in for "CoreBluetooth already knows about this peripheral" —
        // register it as retrievable, and script the connect to succeed.
        fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)

        // Script the value the device would report for a read, then read-decode it through
        // the same `Receivable` path a real characteristic read uses.
        fakePeripheral.onQueue {
            fakePeripheral.scriptedReadValues[HeartRateGATT.measurement] =
                HeartRateMeasurement.wireData(beatsPerMinute: 72)
        }

        let reading: HeartRateMeasurement = try await peripheral.read(from: HeartRateGATT.measurement)
        #expect(reading.beatsPerMinute == 72)
    }

    // MARK: - Notification stream

    @Test("A subscribed notification stream delivers a value simulated after subscription")
    func notificationStreamDeliversSimulatedValue() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connectedRig()

        let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
            peripheral.notifications(for: HeartRateGATT.measurement)

        // `notifications(for:)` enqueues its subscription registration (and the
        // `setNotifyValue(true)` call that goes with it) onto the shared queue before
        // returning the stream. Flushing via `onQueue {}` — an empty block, run
        // synchronously on that same serial queue — waits for every job already queued
        // ahead of it, which by FIFO ordering includes that registration. Only after that
        // is it safe to simulate a notification and be sure this stream is listening for it.
        fakePeripheral.onQueue {}
        fakePeripheral.simulateNotification(
            for: HeartRateGATT.measurement,
            value: HeartRateMeasurement.wireData(beatsPerMinute: 81)
        )

        var iterator = readings.makeAsyncIterator()
        let reading = try await iterator.next()
        #expect(reading?.beatsPerMinute == 81)
    }

    // MARK: - Connect failure

    @Test("connect() failure surfaces the backend-reported error")
    func connectFailureSurfacesError() async throws {
        let queue = DispatchSerialQueue(label: "ConsumerTests.connectFailureSurfacesError")
        let fakeCentral = FakeCentral(queue: queue)
        let fakePeripheral = FakePeripheral(queue: queue)
        let central = Central(backend: fakeCentral, queue: queue)

        fakeCentral.simulateStateChange(.poweredOn)
        for await state in await central.stateEvents() {
            if state == .poweredOn { break }
        }

        let expectedError = NSError(domain: "ConsumerTests", code: 99)
        fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .fail(expectedError)
        }

        do {
            _ = try await central.connect(fakePeripheral.peripheralIdentifier)
            Issue.record("expected connect() to throw")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "ConsumerTests")
            #expect(nsError.code == 99)
        }
    }

    // MARK: - availableServices-driven .missingCharacteristic

    @Test("A characteristic genuinely absent from the scripted GATT table throws .missingCharacteristic")
    func missingCharacteristicSurfaced() async throws {
        let (_, _, fakePeripheral, peripheral) = try await connectedRig()

        // The service is real, but its scripted GATT table doesn't actually contain the
        // heart rate measurement characteristic — only a different one under it, exactly
        // like a real peripheral whose GATT table simply doesn't have what was asked for.
        fakePeripheral.onQueue {
            fakePeripheral.availableServices = [HeartRateGATT.service: [HeartRateGATT.bodySensorLocation]]
        }

        do {
            let _: HeartRateMeasurement = try await peripheral.read(from: HeartRateGATT.measurement)
            Issue.record("expected .missingCharacteristic")
        } catch let error as BLESwiftError {
            #expect(error == .missingCharacteristic(HeartRateGATT.measurement))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Rig helper

    /// Builds the documented 4-line rig, powers the radio on, and connects — the standard
    /// starting point for the GATT-level tests above.
    private func connectedRig() async throws -> (Central, FakeCentral, FakePeripheral, Peripheral) {
        let queue = DispatchSerialQueue(label: "ConsumerTests.connectedRig")
        let fakeCentral = FakeCentral(queue: queue)
        let fakePeripheral = FakePeripheral(queue: queue)
        let central = Central(backend: fakeCentral, queue: queue)

        fakeCentral.simulateStateChange(.poweredOn)
        for await state in await central.stateEvents() {
            if state == .poweredOn { break }
        }

        fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
        return (central, fakeCentral, fakePeripheral, peripheral)
    }
}
