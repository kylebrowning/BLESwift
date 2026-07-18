//
//  FakesSmokeTests.swift
//  BLESwiftTests
//

import Dispatch
import Foundation
import Synchronization
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Proves the CoreBluetooth shim's test doubles (`FakeCentral`/`FakePeripheral`) exist,
/// conform to the shim protocols, and are genuinely queue-confined: every CB-mirroring
/// method and property is only legal to touch from on `queue` (guarded by
/// `dispatchPrecondition`), event delivery is always asynchronous, and `onQueue(_:)` is
/// the one sanctioned door for off-queue (test) code — the property the eventual delegate
/// proxy's `assumeIsolated` will depend on. Later phases exercise the fakes' full
/// scriptable behavior in depth; this suite only smoke-tests the seam itself.
///
/// `onQueue(_:)` is `async` (it hops onto `queue` via `queue.async` + a continuation, never
/// blocking the caller's thread), so its `@Sendable` body must not mutate captured `var`s.
/// The event-accumulating tests therefore collect into a `Mutex`, which the handler mutates
/// under lock and the test reads back after a flush — a happens-before the serial queue
/// already guarantees.
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
        await central.onQueue {} // flush the async didUpdateState delivery

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

        central.simulateStateChange(.poweredOn)
        // No flush yet: simulateStateChange only *schedules* the delivery via
        // queue.async, so nothing should have been observed synchronously.
        #expect(observedStates.withLock { $0 }.isEmpty)

        await central.onQueue {} // now flush
        #expect(observedStates.withLock { $0 } == [.poweredOn])
    }

    @Test("onQueue is the sanctioned door: property access through it never trips the on-queue precondition")
    func onQueueDoorSatisfiesPrecondition() async {
        let (central, peripheral, _) = makeFakeCentral()

        // Every one of these would trap via dispatchPrecondition if called directly from
        // this (off-queue) test body; routed through onQueue, they succeed.
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
        await central.onQueue {} // flush all three async deliveries (FIFO on a serial queue)

        #expect(observedStates.withLock { $0 } == [.resetting, .poweredOn, .poweredOff])
    }

    @Test("connect(_:options:) with .succeed delivers didConnect asynchronously on the queue")
    func connectSucceeds() async {
        let (central, peripheral, _) = makeFakeCentral()
        await central.onQueue { central.connectBehavior = .succeed }

        let events = Mutex<[CentralEvent]>([])
        await central.onQueue { central.eventHandler = { event in events.withLock { $0.append(event) } } }

        await central.onQueue { central.connect(peripheral, options: nil) }
        await central.onQueue {} // flush the async didConnect enqueued by connect(_:options:)

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
        await central.onQueue {} // flush the async didFailToConnect enqueued by connect(_:options:)

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
        await central.onQueue {} // nothing was enqueued, so this returns immediately

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
        await peripheral.onQueue {} // flush

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
