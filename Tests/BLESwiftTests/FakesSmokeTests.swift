//
//  FakesSmokeTests.swift
//  BLESwiftTests
//

import Dispatch
import Foundation
import BLESwiftCompat17
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Proves these properties of the CoreBluetooth shim test doubles (`FakeCentral` and
/// `FakePeripheral`):
/// - They exist and conform to the shim protocols.
/// - They are confined to queues. Code can touch every method and property that mirrors
///   CoreBluetooth only from `queue`. `dispatchPrecondition` guards this.
/// - Event delivery is always asynchronous.
/// - `onQueue(_:)` is the one permitted door for code outside the queue, such as test code. The
///   delegate proxy's `assumeIsolated` will depend on this.
///
/// Other tests exercise the full scriptable behavior of the fakes. This suite only smoke-tests the
/// seam.
///
/// `onQueue(_:)` is `async`. It hops onto `queue` with `queue.async` and a continuation, and never
/// blocks the caller's thread. Its `@Sendable` body must not mutate captured `var` values. Tests
/// that accumulate events collect them into a `Mutex`, which the handler changes under lock and the
/// test reads after a flush. The serial queue guarantees the happens-before order.
@Suite("CoreBluetooth shim fakes")
struct FakesSmokeTests {

    @Test("FakeCentral drives state to .poweredOn and the event is observed on its queue")
    func stateFlipObservedOnQueue() async {
        let (central, _, queue) = makeFakeCentral()

        let observedStates = Mutex<[CentralState]>([])
        await central.onQueue {
            central.eventHandler = { event in
                dispatchPrecondition(condition: .onQueue(queue))
                if case .didUpdateState(let state) = event {
                    observedStates.withLock { $0.append(state) }
                }
            }
        }

        #expect(await central.onQueue { central.radioState } == .unknown)

        central.simulateStateChange(.poweredOn)
        await central.onQueue {} // Flush the async didUpdateState delivery.

        #expect(observedStates.withLock { $0 } == [.poweredOn])
        #expect(await central.onQueue { central.radioState } == .poweredOn)
    }

    @Test("Event delivery is asynchronous: the event is not observed before a flush")
    func eventDeliveryIsAsynchronous() async {
        let (central, _, _) = makeFakeCentral()

        let observedStates = Mutex<[CentralState]>([])
        await central.onQueue {
            central.eventHandler = { event in
                if case .didUpdateState(let state) = event {
                    observedStates.withLock { $0.append(state) }
                }
            }
        }

        // simulateStateChange only *schedules* the delivery with queue.async. The test schedules
        // and checks inside one block on that serial queue, so the delivery cannot run before the
        // check. Checking from the test thread would let the queue deliver first on a busy machine
        // and fail the expectation spuriously.
        await central.onQueue {
            central.simulateStateChange(.poweredOn)
            #expect(observedStates.withLock { $0 }.isEmpty)
        }

        await central.onQueue {} // Now flush.
        #expect(observedStates.withLock { $0 } == [.poweredOn])
    }

    @Test("onQueue is the sanctioned door: property access through it never trips the on-queue precondition")
    func onQueueDoorSatisfiesPrecondition() async {
        let (central, peripheral, _) = makeFakeCentral()

        // Each of these would trap through dispatchPrecondition if called directly from this test
        // body, which is off the queue. Routed through onQueue, they succeed.
        let state = await central.onQueue { central.radioState }
        let connectCount = await central.onQueue { central.connectCallCount }
        let peripheralState = await peripheral.onQueue { peripheral.connectionState }
        let discovered = await peripheral.onQueue { peripheral.isDiscovered(ServiceIdentifier(uuid: "180D")) }

        #expect(state == .unknown)
        #expect(connectCount == 0)
        #expect(peripheralState == .disconnected)
        #expect(!discovered)
    }

    @Test("Two subscribers-in-a-row both see every state transition, in order")
    func multipleStateTransitionsObservedInOrder() async {
        let (central, _, _) = makeFakeCentral()

        let observedStates = Mutex<[CentralState]>([])
        await central.onQueue {
            central.eventHandler = { event in
                if case .didUpdateState(let state) = event {
                    observedStates.withLock { $0.append(state) }
                }
            }
        }

        central.simulateStateChange(.resetting)
        central.simulateStateChange(.poweredOn)
        central.simulateStateChange(.poweredOff)
        await central.onQueue {} // Flush all three async deliveries. A serial queue delivers them first in, first out.

        #expect(observedStates.withLock { $0 } == [.resetting, .poweredOn, .poweredOff])
    }

    @Test("connect(_:options:) with .succeed delivers didConnect asynchronously on the queue")
    func connectSucceeds() async {
        let (central, peripheral, _) = makeFakeCentral()
        await central.onQueue { central.connectBehavior = .succeed }

        let events = Mutex<[CentralEvent]>([])
        await central.onQueue { central.eventHandler = { event in events.withLock { $0.append(event) } } }

        await central.onQueue { central.connect(peripheral, options: nil) }
        await central.onQueue {} // Flush the async didConnect that connect(_:options:) queued.

        #expect(await central.onQueue { central.connectCallCount } == 1)
        guard case .didConnect(let identifier) = events.withLock({ $0 }).first else {
            Issue.record("expected a single didConnect event, got \(events.withLock { $0 })")
            return
        }
        #expect(identifier.uuid == peripheral.identifier)
    }

    @Test("connect(_:options:) with .fail delivers didFailToConnect asynchronously on the queue")
    func connectFails() async {
        let (central, peripheral, _) = makeFakeCentral()
        let expectedError = NSError(domain: "BLESwiftTests", code: 1)
        await central.onQueue { central.connectBehavior = .fail(expectedError) }

        let events = Mutex<[CentralEvent]>([])
        await central.onQueue { central.eventHandler = { event in events.withLock { $0.append(event) } } }

        await central.onQueue { central.connect(peripheral, options: nil) }
        await central.onQueue {} // Flush the async didFailToConnect that connect(_:options:) queued.

        guard case .didFailToConnect(let identifier, let error) = events.withLock({ $0 }).first else {
            Issue.record("expected a single didFailToConnect event, got \(events.withLock { $0 })")
            return
        }
        #expect(identifier.uuid == peripheral.identifier)
        #expect(error === expectedError)
    }

    @Test("connect(_:options:) with .hang delivers no event")
    func connectHangs() async {
        let (central, peripheral, _) = makeFakeCentral()
        await central.onQueue { central.connectBehavior = .hang }

        let events = Mutex<[CentralEvent]>([])
        await central.onQueue { central.eventHandler = { event in events.withLock { $0.append(event) } } }

        await central.onQueue { central.connect(peripheral, options: nil) }
        await central.onQueue {} // The code queued nothing, so this returns immediately.

        #expect(await central.onQueue { central.connectCallCount } == 1)
        #expect(events.withLock { $0 }.isEmpty)
    }

    @Test("FakePeripheral delivers a scripted notification value on its queue")
    func notificationEmission() async throws {
        let (_, peripheral, _) = makeFakeCentral()
        let characteristic = CharacteristicIdentifier(uuid: "2A37", service: ServiceIdentifier(uuid: "180D"))
        let value = Data([0x01, 0x02, 0x03])

        let events = Mutex<[PeripheralEvent]>([])
        await peripheral.onQueue { peripheral.eventHandler = { event in events.withLock { $0.append(event) } } }

        peripheral.simulateNotification(for: characteristic, value: value)
        await peripheral.onQueue {} // Flush.

        guard case .didUpdateValue(let receivedCharacteristic, let receivedValue, let error) = try #require(events.withLock({ $0 }).first) else {
            Issue.record("expected a single didUpdateValue event, got \(events.withLock { $0 })")
            return
        }
        #expect(receivedCharacteristic == characteristic)
        #expect(receivedValue == value)
        #expect(error == nil)
    }

    @Test("FakePeripheral discovery is cached and reflected by isDiscovered")
    func discoveryCacheReflectsSimulatedState() async {
        let (_, peripheral, _) = makeFakeCentral()
        let service = ServiceIdentifier(uuid: "180D")
        let characteristic = CharacteristicIdentifier(uuid: "2A37", service: service)

        #expect(!(await peripheral.onQueue { peripheral.isDiscovered(service) }))
        #expect(!(await peripheral.onQueue { peripheral.isDiscovered(characteristic) }))

        peripheral.simulateDiscoveredCharacteristics([characteristic], for: service)

        #expect(await peripheral.onQueue { peripheral.isDiscovered(service) })
        #expect(await peripheral.onQueue { peripheral.isDiscovered(characteristic) })
    }

    @Test("FakeCentral.bluetoothAuthorization is Mutex-backed and readable/writable off-queue, without onQueue")
    func authorizationIsNotQueueConfined() {
        let original = FakeCentral.bluetoothAuthorization
        defer { FakeCentral.bluetoothAuthorization = original }

        FakeCentral.bluetoothAuthorization = .allowedAlways
        #expect(FakeCentral.bluetoothAuthorization == .allowedAlways)
    }
}
