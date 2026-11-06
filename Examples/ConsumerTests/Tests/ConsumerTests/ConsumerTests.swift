//
//  ConsumerTests.swift
//  ConsumerTests
//
//  The consumer proof of BLESwift, outside the main package. Every test is written as an outside
//  consumer writes it: it uses only `import BLESwift`, `import BLESwiftCore`, and `import
//  BLESwiftTestSupport`, with no test-only import attribute and nothing with `package` visibility.
//  This package depends on the root package by path. A real consumer's `Package.swift` depends on a
//  published BLESwift release in the same way. A passing `swift test` here proves that the shipped
//  test support (`FakeCentral`, `FakePeripheral`, and the public `init(backend:queue:...)` of
//  `Central`) works end to end with no special access. The "Testing Your BLE Code" DocC article in
//  `BLESwiftTestSupport` narrates the rig pattern that these tests use.
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
    func rigConstruction() async {
        // 1. One serial queue. Every fake and `Central` itself share it. This queue is the base of
        //    the queue-confined contract (see the doc comment of `FakeCentral`).
        let queue = DispatchQueue(label: "ConsumerTests.rigConstruction")
        // 2. The fakes, confined to that queue.
        let fakeCentral = FakeCentral(queue: queue)
        let fakePeripheral = FakePeripheral(queue: queue)
        // 3. `Central`'s public backend initializer — no hardware, no special test access.
        let central = Central(backend: fakeCentral, queue: queue)

        await #expect(fakeCentral.onQueue { fakeCentral.radioState } == .unknown)
        _ = central
        _ = fakePeripheral
    }

    // MARK: - Power-on, connect, and a GATT read/decode round trip

    @Test("Power on the radio, connect, and read-decode a heart rate measurement")
    func powerOnConnectAndRead() async throws {
        let queue = DispatchQueue(label: "ConsumerTests.powerOnConnectAndRead")
        let fakeCentral = FakeCentral(queue: queue)
        let fakePeripheral = FakePeripheral(queue: queue)
        let central = Central(backend: fakeCentral, queue: queue)

        // Wait until the radio is on before the test does anything else. Every BLESwift app follows
        // this pattern against real hardware (see "Getting Started").
        fakeCentral.simulateStateChange(.poweredOn)
        for await state in await central.stateEvents() {
            if state == .poweredOn { break }
        }

        // The fake represents "CoreBluetooth already knows this peripheral". Register it as
        // retrievable and script the connect to succeed.
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)

        // Script the value that the device reports for a read, then read and decode it through the
        // same `Receivable` path as a real characteristic read.
        await fakePeripheral.onQueue {
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

        // `notifications(for:)` puts its subscription registration, with the `setNotifyValue(true)`
        // call, in the shared queue before it returns the stream. `onQueue {}` then flushes the
        // queue: its empty block runs synchronously on the same serial queue, so by FIFO order it
        // waits for every job ahead of it, including the registration. After the flush it is safe
        // to simulate a notification, because the stream is listening.
        await fakePeripheral.onQueue {}
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
        let queue = DispatchQueue(label: "ConsumerTests.connectFailureSurfacesError")
        let fakeCentral = FakeCentral(queue: queue)
        let fakePeripheral = FakePeripheral(queue: queue)
        let central = Central(backend: fakeCentral, queue: queue)

        fakeCentral.simulateStateChange(.poweredOn)
        for await state in await central.stateEvents() {
            if state == .poweredOn { break }
        }

        let expectedError = NSError(domain: "ConsumerTests", code: 99)
        await fakeCentral.onQueue {
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

        // The service is real, but its scripted GATT table contains only a different characteristic
        // under the service, not the heart rate measurement. This is the same as a real peripheral
        // whose GATT table lacks the requested characteristic.
        await fakePeripheral.onQueue {
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

    /// Builds the documented 4-line rig, powers the radio on, and connects. This is the standard
    /// start for the GATT-level tests above.
    private func connectedRig() async throws -> (Central, FakeCentral, FakePeripheral, Peripheral) {
        let queue = DispatchQueue(label: "ConsumerTests.connectedRig")
        let fakeCentral = FakeCentral(queue: queue)
        let fakePeripheral = FakePeripheral(queue: queue)
        let central = Central(backend: fakeCentral, queue: queue)

        fakeCentral.simulateStateChange(.poweredOn)
        for await state in await central.stateEvents() {
            if state == .poweredOn { break }
        }

        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
        return (central, fakeCentral, fakePeripheral, peripheral)
    }
}
