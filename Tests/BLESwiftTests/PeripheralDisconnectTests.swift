//
//  PeripheralDisconnectTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Covers a few small, previously-untested gaps:
///
/// - `Peripheral.disconnect(immediate:)` — a public API with 0% prior coverage.
/// - `Peripheral.resolveCentral()`'s `.notConnected` throw once the owning `Central` actor
///   has deallocated (exercised through the public `disconnect()` call site, since
///   `resolveCentral()` itself is `internal`).
/// - `RestoredScanOptions.init(allowDuplicates:solicitedServices:)`.
@Suite("Peripheral disconnect")
struct PeripheralDisconnectTests {

    // MARK: - Peripheral.disconnect(immediate:)

    @Test("Peripheral.disconnect() (default immediate: false) resolves and leaves the peripheral disconnected")
    func disconnectDefaultResolves() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let disconnectTask = Task { try await peripheral.disconnect() }
        await waitFor { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        try await disconnectTask.value

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected after peripheral.disconnect()")
            return
        }
    }

    @Test("Peripheral.disconnect(immediate: true) also resolves and leaves the peripheral disconnected")
    func disconnectImmediateResolves() async throws {
        // `Central.disconnect(_:immediate:)`'s `immediate` flag isn't threaded into any
        // fake-observable difference along the current disconnect path (both call sites
        // route through the same `beginDisconnecting`, which already fails pending GATT
        // operations unconditionally before waiting on CoreBluetooth's confirmation) — so
        // this can only confirm `disconnect(immediate: true)` compiles and resolves the
        // same way as the default, not that its behavior differs observably.
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let disconnectTask = Task { try await peripheral.disconnect(immediate: true) }
        await waitFor { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        try await disconnectTask.value

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected after peripheral.disconnect(immediate: true)")
            return
        }
    }

    // MARK: - resolveCentral() after the owning Central deallocates

    @Test("Peripheral.disconnect() throws .notConnected once the owning Central has deallocated")
    func disconnectAfterCentralDeallocatedThrowsNotConnected() async throws {
        let (fakeCentral, fakePeripheral, queue) = makeFakeCentral()
        var central: Central? = Central(backend: fakeCentral, queue: queue)
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await central!.connect(fakePeripheral.peripheralIdentifier)

        // Release every strong reference to `Central`. `Central.init(backend:queue:...)`'s
        // doc comment ("Retention") spells out that, unlike the production initializers,
        // this custom-backend init deliberately makes `backend.eventHandler` capture `self`
        // strongly — a `Central` <-> `FakeCentral` cycle. So dropping this test's own
        // `central` reference alone would not be enough: `fakeCentral`, which this test
        // still holds, keeps the actor alive via that closure until it too is cleared,
        // exactly as the doc comment prescribes ("clear it explicitly: backend.eventHandler
        // = nil"). Once both are gone, `WeakCentralBox`'s weak reference zeroes and
        // `resolveCentral()` observes it as gone.
        central = nil
        await fakeCentral.onQueue { fakeCentral.eventHandler = nil }

        do {
            try await peripheral.disconnect()
            Issue.record("expected .notConnected once the owning Central has deallocated")
        } catch let error as BLESwiftError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - RestoredScanOptions.init(allowDuplicates:solicitedServices:)

    @Test("RestoredScanOptions.init(allowDuplicates:solicitedServices:) stores both properties unchanged")
    func restoredScanOptionsStoresProperties() {
        // The untested initializer with this exact `(allowDuplicates:solicitedServices:)`
        // signature lives on `RestoredScanOptions`, not `RestoredState` (whose own init
        // takes `peripherals:scanServices:scanOptions:`) — confirmed against
        // Sources/BLESwiftCore/Restoration/RestoredState.swift.
        let service = ServiceIdentifier(uuid: "180D")
        let options = RestoredScanOptions(allowDuplicates: true, solicitedServices: [service])

        #expect(options.allowDuplicates == true)
        #expect(options.solicitedServices == [service])
    }
}
