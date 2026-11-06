//
//  ConnectionEventsTests.swift
//  BLESwiftTests
//

// `Central.connectionEventRegistration(services:peripherals:)` exists on all platforms except
// macOS, as does `registerForConnectionEvents(options:)` in CoreBluetooth.
#if !os(macOS)

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Tests `Central.connectionEventRegistration(services:peripherals:)`: subscribe, receive, backend
/// register and unregister with reference counts, and the multicast to multiple subscribers.
@Suite("System connection events")
struct ConnectionEventsTests {

    @Test("Subscribing registers with the backend once and receives simulated events")
    func subscribeReceivesEvents() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        let stream = await central.connectionEventRegistration()

        let registrations = await fakeCentral.onQueue { fakeCentral.connectionEventRegistrationCount }
        #expect(registrations == 1)

        let id = fakePeripheral.peripheralIdentifier
        fakeCentral.simulateConnectionEvent(.peerConnected, for: id)

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == SystemConnectionEvent(peripheral: id, kind: .peerConnected))
    }

    @Test("Match options reach the backend seam")
    func matchOptionsReachBackend() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        let service = ServiceIdentifier(uuid: "180D")
        let id = fakePeripheral.peripheralIdentifier
        _ = await central.connectionEventRegistration(services: [service], peripherals: [id])

        let (services, peripherals) = await fakeCentral.onQueue {
            (fakeCentral.lastConnectionEventServices, fakeCentral.lastConnectionEventPeripherals)
        }
        #expect(services == [service])
        #expect(peripherals == [id.uuid])
    }

    @Test("Cancelling the last subscriber unregisters from the backend")
    func lastCancelUnregisters() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        let stream = await central.connectionEventRegistration()

        let consumer = Task {
            for await _ in stream { }
        }
        await waitFor { await fakeCentral.onQueue { fakeCentral.connectionEventRegistrationCount == 1 } }
        consumer.cancel()
        await waitFor { await fakeCentral.onQueue { fakeCentral.connectionEventUnregistrationCount == 1 } }

        let (registrations, unregistrations) = await fakeCentral.onQueue {
            (fakeCentral.connectionEventRegistrationCount, fakeCentral.connectionEventUnregistrationCount)
        }
        #expect(registrations == 1)
        #expect(unregistrations == 1)
    }

    @Test("Two subscribers both receive events; register once, unregister once after both end")
    func multiSubscriberMulticast() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        let id = fakePeripheral.peripheralIdentifier

        // Consume each stream inside its own task. Do NOT keep the stream value in this scope. When
        // code drops the iterator of an AsyncStream (as `first(where:)` does), a stream that
        // something still holds does not terminate. Termination fires only when the stream value
        // itself is released, here at the completion of each task. The continuations register
        // synchronously when each stream is created, so the stream buffers an event simulated
        // before the tasks start to iterate.
        func consumeFirst(_ stream: AsyncStream<SystemConnectionEvent>) -> Task<SystemConnectionEvent?, Never> {
            Task {
                for await event in stream { return event }
                return nil
            }
        }
        let first = consumeFirst(await central.connectionEventRegistration())
        let second = consumeFirst(await central.connectionEventRegistration())

        let registrations = await fakeCentral.onQueue { fakeCentral.connectionEventRegistrationCount }
        #expect(registrations == 1)

        fakeCentral.simulateConnectionEvent(.peerDisconnected, for: id)

        let expected = SystemConnectionEvent(peripheral: id, kind: .peerDisconnected)
        #expect(await first.value == expected)
        #expect(await second.value == expected)

        // Both tasks completed and released both streams. Exactly one backend unregistration
        // follows the second termination, with no re-registration.
        await waitFor { await fakeCentral.onQueue { fakeCentral.connectionEventUnregistrationCount == 1 } }
        let (finalRegistrations, unregistrations) = await fakeCentral.onQueue {
            (fakeCentral.connectionEventRegistrationCount, fakeCentral.connectionEventUnregistrationCount)
        }
        #expect(finalRegistrations == 1)
        #expect(unregistrations == 1)
    }
}

#endif
