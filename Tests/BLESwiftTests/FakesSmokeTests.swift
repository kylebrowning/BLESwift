//
//  FakesSmokeTests.swift
//  BLESwiftTests
//

import Dispatch
import Foundation
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
@Suite("CoreBluetooth shim fakes")
struct FakesSmokeTests {

    @Test("FakeCentral drives state to .poweredOn and the event is observed on its queue")
    func stateFlipObservedOnQueue() {
        let (central, _, queue) = makeFakeCentral()

        var observedStates: [CentralState] = []
        central.onQueue {
            central.eventHandler = { event in
                dispatchPrecondition(condition: .onQueue(queue))
                if case .didUpdateState(let state) = event {
                    observedStates.append(state)
                }
            }
        }

        #expect(central.onQueue { central.radioState } == .unknown)

        central.simulateStateChange(.poweredOn)
        central.onQueue {} // flush the async didUpdateState delivery

        #expect(observedStates == [.poweredOn])
        #expect(central.onQueue { central.radioState } == .poweredOn)
    }

    @Test("Event delivery is asynchronous: the event is not observed before a flush")
    func eventDeliveryIsAsynchronous() {
        let (central, _, _) = makeFakeCentral()

        var observedStates: [CentralState] = []
        central.onQueue {
            central.eventHandler = { event in
                if case .didUpdateState(let state) = event {
                    observedStates.append(state)
                }
            }
        }

        central.simulateStateChange(.poweredOn)
        // No flush yet: simulateStateChange only *schedules* the delivery via
        // queue.async, so nothing should have been observed synchronously.
        #expect(observedStates.isEmpty)

        central.onQueue {} // now flush
        #expect(observedStates == [.poweredOn])
    }

    @Test("onQueue is the sanctioned door: property access through it never trips the on-queue precondition")
    func onQueueDoorSatisfiesPrecondition() {
        let (central, peripheral, _) = makeFakeCentral()

        // Every one of these would trap via dispatchPrecondition if called directly from
        // this (off-queue) test body; routed through onQueue, they succeed.
        let state = central.onQueue { central.radioState }
        let connectCount = central.onQueue { central.connectCallCount }
        let peripheralState = peripheral.onQueue { peripheral.connectionState }
        let discovered = peripheral.onQueue { peripheral.isDiscovered(ServiceIdentifier(uuid: "180D")) }

        #expect(state == .unknown)
        #expect(connectCount == 0)
        #expect(peripheralState == .disconnected)
        #expect(!discovered)
    }

    @Test("Two subscribers-in-a-row both see every state transition, in order")
    func multipleStateTransitionsObservedInOrder() {
        let (central, _, _) = makeFakeCentral()

        var observedStates: [CentralState] = []
        central.onQueue {
            central.eventHandler = { event in
                if case .didUpdateState(let state) = event {
                    observedStates.append(state)
                }
            }
        }

        central.simulateStateChange(.resetting)
        central.simulateStateChange(.poweredOn)
        central.simulateStateChange(.poweredOff)
        central.onQueue {} // flush all three async deliveries (FIFO on a serial queue)

        #expect(observedStates == [.resetting, .poweredOn, .poweredOff])
    }

    @Test("connect(_:options:) with .succeed delivers didConnect asynchronously on the queue")
    func connectSucceeds() {
        let (central, peripheral, _) = makeFakeCentral()
        central.onQueue { central.connectBehavior = .succeed }

        var events: [CentralEvent] = []
        central.onQueue { central.eventHandler = { events.append($0) } }

        central.onQueue { central.connect(peripheral, options: nil) }
        central.onQueue {} // flush the async didConnect enqueued by connect(_:options:)

        #expect(central.onQueue { central.connectCallCount } == 1)
        guard case .didConnect(let identifier) = events.first else {
            Issue.record("expected a single didConnect event, got \(events)")
            return
        }
        #expect(identifier.uuid == peripheral.identifier)
    }

    @Test("connect(_:options:) with .fail delivers didFailToConnect asynchronously on the queue")
    func connectFails() {
        let (central, peripheral, _) = makeFakeCentral()
        let expectedError = NSError(domain: "BLESwiftTests", code: 1)
        central.onQueue { central.connectBehavior = .fail(expectedError) }

        var events: [CentralEvent] = []
        central.onQueue { central.eventHandler = { events.append($0) } }

        central.onQueue { central.connect(peripheral, options: nil) }
        central.onQueue {} // flush the async didFailToConnect enqueued by connect(_:options:)

        guard case .didFailToConnect(let identifier, let error) = events.first else {
            Issue.record("expected a single didFailToConnect event, got \(events)")
            return
        }
        #expect(identifier.uuid == peripheral.identifier)
        #expect(error === expectedError)
    }

    @Test("connect(_:options:) with .hang delivers no event")
    func connectHangs() {
        let (central, peripheral, _) = makeFakeCentral()
        central.onQueue { central.connectBehavior = .hang }

        var events: [CentralEvent] = []
        central.onQueue { central.eventHandler = { events.append($0) } }

        central.onQueue { central.connect(peripheral, options: nil) }
        central.onQueue {} // nothing was enqueued, so this returns immediately

        #expect(central.onQueue { central.connectCallCount } == 1)
        #expect(events.isEmpty)
    }

    @Test("FakePeripheral delivers a scripted notification value on its queue")
    func notificationEmission() throws {
        let (_, peripheral, _) = makeFakeCentral()
        let characteristic = CharacteristicIdentifier(uuid: "2A37", service: ServiceIdentifier(uuid: "180D"))
        let value = Data([0x01, 0x02, 0x03])

        var events: [PeripheralEvent] = []
        peripheral.onQueue { peripheral.eventHandler = { events.append($0) } }

        peripheral.simulateNotification(for: characteristic, value: value)
        peripheral.onQueue {} // flush

        guard case .didUpdateValue(let receivedCharacteristic, let receivedValue, let error) = try #require(events.first) else {
            Issue.record("expected a single didUpdateValue event, got \(events)")
            return
        }
        #expect(receivedCharacteristic == characteristic)
        #expect(receivedValue == value)
        #expect(error == nil)
    }

    @Test("FakePeripheral discovery is cached and reflected by isDiscovered")
    func discoveryCacheReflectsSimulatedState() {
        let (_, peripheral, _) = makeFakeCentral()
        let service = ServiceIdentifier(uuid: "180D")
        let characteristic = CharacteristicIdentifier(uuid: "2A37", service: service)

        #expect(!peripheral.onQueue { peripheral.isDiscovered(service) })
        #expect(!peripheral.onQueue { peripheral.isDiscovered(characteristic) })

        peripheral.simulateDiscoveredCharacteristics([characteristic], for: service)

        #expect(peripheral.onQueue { peripheral.isDiscovered(service) })
        #expect(peripheral.onQueue { peripheral.isDiscovered(characteristic) })
    }

    @Test("FakeCentral.bluetoothAuthorization is Mutex-backed and readable/writable off-queue, without onQueue")
    func authorizationIsNotQueueConfined() {
        let original = FakeCentral.bluetoothAuthorization
        defer { FakeCentral.bluetoothAuthorization = original }

        FakeCentral.bluetoothAuthorization = .allowedAlways
        #expect(FakeCentral.bluetoothAuthorization == .allowedAlways)
    }
}
