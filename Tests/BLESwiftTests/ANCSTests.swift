//
//  ANCSTests.swift
//  BLESwiftTests
//

// ANCS is available on iOS only. The ANCS API (`requiresANCS:`, `Peripheral.ancsAuthorized`, and
// `ancsAuthorizationEvents()`) has the availability of `CBConnectPeripheralOptionRequiresANCS` in
// CoreBluetooth.
#if os(iOS)

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Tests the ANCS API:
/// - how the `requiresANCS:` connect option reaches the backend seam
/// - `Peripheral.ancsAuthorized`
/// - the multicast of `ancsAuthorizationEvents()`
@Suite("ANCS")
struct ANCSTests {

    @Test("connect(requiresANCS: true) reaches the backend seam")
    func connectPlumbsRequiresANCS() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
        }

        _ = try await central.connect(fakePeripheral.peripheralIdentifier, requiresANCS: true)

        let last = await fakeCentral.onQueue { fakeCentral.lastConnectRequiresANCS }
        #expect(last == true)
    }

    @Test("connect without requiresANCS defaults to false at the backend seam")
    func connectDefaultsToNoANCS() async throws {
        let (_, fakeCentral, _, _) = try await makeConnectedTestCentral()
        let last = await fakeCentral.onQueue { fakeCentral.lastConnectRequiresANCS }
        #expect(last == false)
    }

    @Test("ancsAuthorizationEvents() yields simulated changes and ancsAuthorized reflects the backend")
    func authorizationEventsAndSnapshot() async throws {
        let (_, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        #expect(await peripheral.ancsAuthorized == false)

        let events = peripheral.ancsAuthorizationEvents()
        await fakeCentral.onQueue { fakePeripheral.ancsAuthorized = true }
        fakeCentral.simulateANCSAuthorization(true, for: peripheral.id)

        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(await peripheral.ancsAuthorized == true)
    }

    @Test("ancsAuthorized is false once the peripheral is disconnected")
    func ancsAuthorizedFalseWhenDisconnected() async throws {
        let (_, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakeCentral.onQueue { fakePeripheral.ancsAuthorized = true }
        #expect(await peripheral.ancsAuthorized == true)

        // An explicit disconnect has two phases and waits for the CoreBluetooth confirmation. The
        // fake must script it, as in PeripheralDisconnectTests.disconnectResolves.
        let disconnectTask = Task { try await peripheral.disconnect() }
        await waitFor { await fakeCentral.onQueue { fakeCentral.cancelCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        try await disconnectTask.value

        #expect(await peripheral.ancsAuthorized == false)
    }

    @Test("Two ancsAuthorizationEvents() subscribers both receive changes")
    func multiSubscriberMulticast() async throws {
        let (_, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let first = peripheral.ancsAuthorizationEvents()
        let second = peripheral.ancsAuthorizationEvents()

        await fakeCentral.onQueue { fakePeripheral.ancsAuthorized = true }
        fakeCentral.simulateANCSAuthorization(true, for: peripheral.id)

        #expect(await Task { await first.first { _ in true } }.value == true)
        #expect(await Task { await second.first { _ in true } }.value == true)
    }
}

#endif
