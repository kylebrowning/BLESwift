//
//  ANCSTests.swift
//  BLESwiftTests
//

// ANCS (`requiresANCS:`, `Peripheral.ancsAuthorized`, `ancsAuthorizationEvents()`) is
// iOS-only, matching CoreBluetooth's `CBConnectPeripheralOptionRequiresANCS` availability.
#if os(iOS)

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Exercises the ANCS surface: the `requiresANCS:` connect option's plumbing to the
/// backend seam, `Peripheral.ancsAuthorized`, and `ancsAuthorizationEvents()` multicast.
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

        try await peripheral.disconnect()
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
