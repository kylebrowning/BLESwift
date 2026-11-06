//
//  ScanTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Tests `Central.scan(...)`: the event flow for discovery, duplicate, loss, and throttle, the
/// single-scan rule, and the cleanup that a stream's termination starts. All tests use
/// `FakeCentral`.
@Suite("Scan")
struct ScanTests {

    @Test("A first sighting is reported as .discovered")
    func discoveryEventFlow() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(services: nil)
        var iterator = stream.makeAsyncIterator()

        let peripheral = PeripheralIdentifier(uuid: UUID(), name: "Heart Rate Monitor")
        let advertisement = AdvertisementData()
        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -50)

        let event = try await iterator.next()
        guard case .discovered(let discovery) = event else {
            Issue.record("expected .discovered, got \(String(describing: event))")
            return
        }
        #expect(discovery.peripheral == peripheral)
        #expect(discovery.rssi == -50)
    }

    @Test("Without allowDuplicates, a repeat sighting emits nothing further")
    func duplicateCoalescingOff() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(services: nil, allowDuplicates: false)
        var iterator = stream.makeAsyncIterator()

        let peripheral = PeripheralIdentifier(uuid: UUID(), name: nil)
        let advertisement = AdvertisementData()

        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -50)
        guard case .discovered = try await iterator.next() else {
            Issue.record("expected .discovered")
            return
        }

        // A repeat sighting without allowDuplicates must not yield anything. Prove it with a
        // sighting of a *different* peripheral next: had the repeat yielded an .updated, this
        // .next() would return it and not the second peripheral's .discovered.
        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -70)
        await fakeCentral.onQueue {}

        let other = PeripheralIdentifier(uuid: UUID(), name: nil)
        fakeCentral.simulateDiscovery(peripheral: other, advertisement: advertisement, rssi: -40)

        let next = try await iterator.next()
        guard case .discovered(let discovery) = next else {
            Issue.record("expected .discovered for the second peripheral, got \(String(describing: next))")
            return
        }
        #expect(discovery.peripheral == other)
    }

    @Test("With allowDuplicates, a repeat sighting emits .updated")
    func duplicateCoalescingOn() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(services: nil, allowDuplicates: true)
        var iterator = stream.makeAsyncIterator()

        let peripheral = PeripheralIdentifier(uuid: UUID(), name: nil)
        let advertisement = AdvertisementData()

        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -50)
        guard case .discovered = try await iterator.next() else {
            Issue.record("expected .discovered")
            return
        }

        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -70)
        let updated = try await iterator.next()
        guard case .updated(let discovery) = updated else {
            Issue.record("expected .updated, got \(String(describing: updated))")
            return
        }
        #expect(discovery.rssi == -70)
    }

    @Test("A peripheral not re-sighted within lossTimeout is reported as .lost")
    func lostAtDeadline() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(services: nil, allowDuplicates: true, lossTimeout: .milliseconds(50))
        var iterator = stream.makeAsyncIterator()

        let peripheral = PeripheralIdentifier(uuid: UUID(), name: nil)
        let advertisement = AdvertisementData()
        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -50)

        guard case .discovered = try await iterator.next() else {
            Issue.record("expected .discovered")
            return
        }

        let lost = try await iterator.next()
        guard case .lost(let discovery) = lost else {
            Issue.record("expected .lost, got \(String(describing: lost))")
            return
        }
        #expect(discovery.peripheral == peripheral)
    }

    @Test("rssiThreshold suppresses .updated for an insignificant RSSI change")
    func throttleSuppression() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(services: nil, allowDuplicates: true, rssiThreshold: 10)
        var iterator = stream.makeAsyncIterator()

        let peripheral = PeripheralIdentifier(uuid: UUID(), name: nil)
        let advertisement = AdvertisementData()

        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -50)
        guard case .discovered = try await iterator.next() else {
            Issue.record("expected .discovered")
            return
        }

        // A delta of 5 from -50 is below the threshold of 10. The code suppresses it.
        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -55)
        await fakeCentral.onQueue {}

        // A throttled sighting does not update the stored baseline, so the code computes this delta
        // against the *original* -50 (a delta of 20), which is above the threshold.
        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -70)
        let updated = try await iterator.next()
        guard case .updated(let discovery) = updated else {
            Issue.record("expected .updated, got \(String(describing: updated))")
            return
        }
        #expect(discovery.rssi == -70)
    }

    @Test("Cancelling the scan's consuming task stops the underlying hardware scan")
    func cancelStopsScan() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(services: nil)

        let task = Task {
            for try await _ in stream {}
        }
        task.cancel()
        _ = await task.result

        // Flush the actor's queue so that the cleanup started by onTermination (it hops through
        // queue.async) has run before the assertion.
        await fakeCentral.onQueue {}

        #expect(await fakeCentral.onQueue { fakeCentral.stopScanCallCount } == 1)
        #expect(central.isScanning == false)
    }

    @Test("Starting a second scan while one is active throws .alreadyScanning, without affecting the first")
    func secondScanRejection() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let firstStream = await central.scan(services: nil)
        var firstIterator = firstStream.makeAsyncIterator()

        let secondStream = await central.scan(services: nil)
        var secondIterator = secondStream.makeAsyncIterator()

        do {
            _ = try await secondIterator.next()
            Issue.record("expected the second scan to throw .alreadyScanning")
        } catch let error as BLESwiftError {
            #expect(error == .alreadyScanning)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        #expect(central.isScanning == true)

        // The first scan is not affected. It keeps delivering discoveries.
        let peripheral = PeripheralIdentifier(uuid: UUID(), name: nil)
        let advertisement = AdvertisementData()
        fakeCentral.simulateDiscovery(peripheral: peripheral, advertisement: advertisement, rssi: -50)

        guard case .discovered = try await firstIterator.next() else {
            Issue.record("expected the first scan to still be delivering .discovered events")
            return
        }
    }

    @Test("A scan with a timeout finishes its stream cleanly, with no error")
    func timeoutFinishesCleanly() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(services: nil, timeout: .milliseconds(50))

        var events: [ScanEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
        } catch {
            Issue.record("expected the stream to finish without error, got \(error)")
        }

        #expect(events.isEmpty)

        await fakeCentral.onQueue {} // Flush the cleanup that onTermination starts.
        #expect(central.isScanning == false)
    }

    @Test("Leaving .poweredOn fails the active scan with .bluetoothUnavailable")
    func leavingPoweredOnFailsActiveScan() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(services: nil)
        var iterator = stream.makeAsyncIterator()

        fakeCentral.simulateStateChange(.poweredOff)

        do {
            _ = try await iterator.next()
            Issue.record("expected the scan to throw .bluetoothUnavailable")
        } catch let error as BLESwiftError {
            #expect(error == .bluetoothUnavailable)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("isScanning reflects an active scan")
    func isScanningReflectsActiveScan() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        #expect(central.isScanning == false)

        let stream = await central.scan(services: nil, timeout: .milliseconds(50))
        #expect(central.isScanning == true)

        for try await _ in stream {}

        await fakeCentral.onQueue {} // Flush the cleanup that onTermination starts.
        #expect(central.isScanning == false)
    }
}
