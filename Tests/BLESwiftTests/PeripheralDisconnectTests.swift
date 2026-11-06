//
//  PeripheralDisconnectTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Covers small gaps that no test covered before:
/// - `Peripheral.disconnect()`, a public API.
/// - The `.notConnected` throw of `Peripheral.resolveCentral()` after the owning `Central` actor
///   has deallocated. The test uses the public `disconnect()` call site because `resolveCentral()`
///   is `internal`.
/// - `RestoredScanOptions.init(allowDuplicates:solicitedServices:)`.
@Suite("Peripheral disconnect")
struct PeripheralDisconnectTests {

    // MARK: - Peripheral.disconnect()

    @Test("Peripheral.disconnect() resolves and leaves the peripheral disconnected")
    func disconnectResolves() async throws {
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

        // Release every strong reference to `Central`. As the "Retention" doc comment of
        // `Central.init(backend:queue:...)` explains, this custom-backend init deliberately makes
        // `backend.eventHandler` capture `self` strongly, which forms a `Central` <-> `FakeCentral`
        // cycle. Dropping the test's `central` reference is not enough. `fakeCentral` keeps the
        // actor alive through that closure until the test also clears it ("backend.eventHandler =
        // nil", as the doc comment prescribes). When both are gone, `WeakCentralBox`'s weak
        // reference becomes zero and `resolveCentral()` sees that the actor is gone.
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
        // The initializer with the exact signature `(allowDuplicates:solicitedServices:)` is on
        // `RestoredScanOptions`, not on `RestoredState`, whose init takes
        // `peripherals:scanServices:scanOptions:`. Confirmed against
        // Sources/BLESwiftCore/Restoration/RestoredState.swift.
        let service = ServiceIdentifier(uuid: "180D")
        let options = RestoredScanOptions(allowDuplicates: true, solicitedServices: [service])

        #expect(options.allowDuplicates == true)
        #expect(options.solicitedServices == [service])
    }
}
