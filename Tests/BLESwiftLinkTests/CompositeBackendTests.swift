//
//  CompositeBackendTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftProvider
import BLESwiftTestSupport
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// Tests for ``CompositeCentral`` and ``CompositePeripheralManager``. Each is one backend made of
/// several backends. It fans out every call and fans in every event on the single shared queue.
@Suite("Composite backends")
struct CompositeBackendTests {

    // MARK: - Helpers

    /// Hops onto `queue` to run `body` and returns its result. Because `queue` is serial, it also
    /// flushes every `.async` delivery that was scheduled before it.
    private func onQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let battery = ServiceIdentifier(uuid: "180F")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

    private static var service: GATTService {
        GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable])
        ])
    }

    // MARK: - CompositeCentral

    @Test("Composite state is .poweredOn when any child is, and is announced once on attach")
    func stateIsPoweredOnWhenAnyChildIs() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.state")
        let off = FakeCentral(queue: queue, state: .poweredOff)
        let on = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [off, on], queue: queue)

        let states = Mutex<[CentralState]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .didUpdateState(let state) = event { states.withLock { $0.append(state) } }
            }
        }

        await waitFor { states.withLock { !$0.isEmpty } }
        #expect(states.withLock { $0 } == [.poweredOn])
        #expect(await onQueue(queue) { composite.radioState } == .poweredOn)
    }

    @Test("Composite state flips to .poweredOff only when every child is off, emitting once")
    func stateFlipsOffOnlyWhenEveryChildIsOff() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.stateFlip")
        let first = FakeCentral(queue: queue, state: .poweredOn)
        let second = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [first, second], queue: queue)

        let states = Mutex<[CentralState]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .didUpdateState(let state) = event { states.withLock { $0.append(state) } }
            }
        }
        await waitFor { states.withLock { $0 == [.poweredOn] } }

        first.simulateStateChange(.poweredOff)
        _ = await onQueue(queue) { true }
        #expect(states.withLock { $0 } == [.poweredOn])

        second.simulateStateChange(.poweredOff)
        await waitFor { states.withLock { $0.count == 2 } }
        #expect(states.withLock { $0 } == [.poweredOn, .poweredOff])

        second.simulateStateChange(.poweredOff)
        _ = await onQueue(queue) { true }
        #expect(states.withLock { $0 } == [.poweredOn, .poweredOff])
    }

    @Test("Every call fans out to every child")
    func callsFanOutToEveryChild() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.fanOut")
        let first = FakeCentral(queue: queue, state: .poweredOn)
        let second = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [first, second], queue: queue)

        await onQueue(queue) {
            composite.scanForPeripherals(withServices: [Self.heartRate], options: ScanOptions())
            composite.stopScan()
            composite.registerForConnectionEvents(services: [Self.heartRate], peripherals: nil)
            composite.unregisterForConnectionEvents()
        }

        #expect(await onQueue(queue) { first.scanCallCount } == 1)
        #expect(await onQueue(queue) { second.scanCallCount } == 1)
        #expect(await onQueue(queue) { first.stopScanCallCount } == 1)
        #expect(await onQueue(queue) { second.stopScanCallCount } == 1)
        #expect(await onQueue(queue) { first.connectionEventRegistrationCount } == 1)
        #expect(await onQueue(queue) { second.connectionEventRegistrationCount } == 1)
        #expect(await onQueue(queue) { first.connectionEventUnregistrationCount } == 1)
        #expect(await onQueue(queue) { second.connectionEventUnregistrationCount } == 1)
    }

    @Test("retrievePeripherals concatenates across children, de-duplicated by identifier")
    func retrieveReachesEveryChild() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.retrieve")
        let first = FakeCentral(queue: queue, state: .poweredOff)
        let second = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [first, second], queue: queue)

        let onlyOnSecond = FakePeripheral(queue: queue)
        let shared = FakePeripheral(queue: queue)
        let sharedImposter = FakePeripheral(identifier: shared.identifier, name: "second", queue: queue)

        await onQueue(queue) {
            second.retrievablePeripherals[onlyOnSecond.identifier] = onlyOnSecond
            first.retrievablePeripherals[shared.identifier] = shared
            second.retrievablePeripherals[shared.identifier] = sharedImposter
        }

        let retrieved = await onQueue(queue) {
            composite.retrievePeripherals(withIdentifiers: [onlyOnSecond.identifier, shared.identifier])
                .map(\.identifier)
        }
        #expect(retrieved.count == 2)
        #expect(Set(retrieved) == Set([onlyOnSecond.identifier, shared.identifier]))

        let winner = await onQueue(queue) {
            composite.retrievePeripherals(withIdentifiers: [shared.identifier]).first.map { $0 === shared } ?? false
        }
        #expect(winner)
    }

    @Test("retrieveConnectedPeripherals concatenates across children")
    func retrieveConnectedReachesEveryChild() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.retrieveConnected")
        let first = FakeCentral(queue: queue, state: .poweredOn)
        let second = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [first, second], queue: queue)

        let a = FakePeripheral(queue: queue)
        let b = FakePeripheral(queue: queue)
        await onQueue(queue) {
            first.systemConnectedPeripherals = [(a, [Self.heartRate])]
            second.systemConnectedPeripherals = [(b, [Self.heartRate])]
        }

        let retrieved = await onQueue(queue) {
            composite.retrieveConnectedPeripherals(withServices: [Self.heartRate]).map(\.identifier)
        }
        #expect(retrieved == [a.identifier, b.identifier])
    }

    @Test("connect on a peripheral from one child delivers didConnect through the composite")
    func connectDeliversDidConnect() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.connect")
        let first = FakeCentral(queue: queue, state: .poweredOff)
        let second = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [first, second], queue: queue)

        let peripheral = FakePeripheral(queue: queue)
        let connected = Mutex<[UUID]>([])
        await onQueue(queue) {
            second.retrievablePeripherals[peripheral.identifier] = peripheral
            composite.eventHandler = { event in
                if case .didConnect(let id) = event { connected.withLock { $0.append(id.uuid) } }
            }
        }

        // Retrieve and connect in one hop. `any PeripheralRemote` is not `Sendable`, so the remote
        // never leaves the queue that confines it.
        let retrievedCount = await onQueue(queue) {
            let retrieved = composite.retrievePeripherals(withIdentifiers: [peripheral.identifier])
            for remote in retrieved { composite.connect(remote, options: nil, requiresANCS: false) }
            return retrieved.count
        }
        #expect(retrievedCount == 1)

        await waitFor { connected.withLock { !$0.isEmpty } }
        #expect(connected.withLock { $0 }.contains(peripheral.identifier))
        #expect(await onQueue(queue) { first.connectCallCount } == 1)
        #expect(await onQueue(queue) { second.connectCallCount } == 1)

        await onQueue(queue) {
            for remote in composite.retrievePeripherals(withIdentifiers: [peripheral.identifier]) {
                composite.cancelPeripheralConnection(remote)
            }
        }
        #expect(await onQueue(queue) { first.cancelCallCount } == 1)
        #expect(await onQueue(queue) { second.cancelCallCount } == 1)
    }

    @Test("A real Central over the composite connects a peripheral end-to-end")
    func realCentralOverCompositeConnects() async throws {
        let queue = DispatchQueue(label: "CompositeBackendTests.central")
        let first = FakeCentral(queue: queue, state: .poweredOff)
        let second = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [first, second], queue: queue)

        let peripheral = FakePeripheral(queue: queue)
        await onQueue(queue) {
            second.retrievablePeripherals[peripheral.identifier] = peripheral
            first.connectBehavior = .hang
            second.connectBehavior = .succeed
        }

        let central = Central(backend: composite, queue: queue)
        let connected = try await central.connect(peripheral.peripheralIdentifier)
        #expect(connected.id.uuid == peripheral.identifier)

        await onQueue(queue) { composite.eventHandler = nil }
    }

    @Test("Clearing the composite's handler detaches every child")
    func clearingHandlerDetachesChildren() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.detach")
        let first = FakeCentral(queue: queue, state: .poweredOn)
        let second = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [first, second], queue: queue)

        await onQueue(queue) { composite.eventHandler = { _ in } }
        await onQueue(queue) { composite.eventHandler = nil }

        let attached = await onQueue(queue) { first.eventHandler != nil || second.eventHandler != nil }
        #expect(!attached)
    }

    @Test("A child powering on is re-issued the scan and the connection-event registration")
    func aChildPoweringOnIsReissuedTheScan() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.rescan")
        let first = FakeCentral(queue: queue, state: .poweredOn)
        let second = FakeCentral(queue: queue, state: .poweredOff)
        let skipped = Mutex<[String]>([])
        let composite = CompositeCentral(backends: [first, second], queue: queue) { line in
            skipped.withLock { $0.append(line) }
        }
        await onQueue(queue) { composite.eventHandler = { _ in } }

        let options = ScanOptions(allowDuplicates: true)
        await onQueue(queue) {
            composite.scanForPeripherals(withServices: [Self.heartRate], options: options)
            composite.registerForConnectionEvents(services: [Self.heartRate], peripherals: nil)
        }

        // CoreBluetooth would drop both calls on a child that is not powered on, so the composite
        // does not issue them at all. It holds them.
        #expect(await onQueue(queue) { first.scanCallCount } == 1)
        #expect(await onQueue(queue) { second.scanCallCount } == 0)
        #expect(await onQueue(queue) { second.connectionEventRegistrationCount } == 0)

        second.simulateStateChange(.poweredOn)
        await waitFor { await self.onQueue(queue) { second.scanCallCount } == 1 }

        #expect(await onQueue(queue) { second.scanCallCount } == 1)
        #expect(await onQueue(queue) { second.lastScanServices } == [Self.heartRate])
        #expect(await onQueue(queue) { second.lastScanOptions } == options)
        #expect(await onQueue(queue) { second.connectionEventRegistrationCount } == 1)
        #expect(await onQueue(queue) { first.scanCallCount } == 1)
        #expect(skipped.withLock { $0.count } == 1)
        #expect(skipped.withLock { $0.first }?.contains("composite child 1") == true)
    }

    @Test("A scan stopped before a child powers on is not re-issued to it")
    func aStoppedScanIsNotReissued() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.rescanStopped")
        let first = FakeCentral(queue: queue, state: .poweredOn)
        let second = FakeCentral(queue: queue, state: .poweredOff)
        let composite = CompositeCentral(backends: [first, second], queue: queue)
        await onQueue(queue) { composite.eventHandler = { _ in } }

        await onQueue(queue) {
            composite.scanForPeripherals(withServices: nil, options: ScanOptions())
            composite.registerForConnectionEvents(services: nil, peripherals: nil)
            composite.stopScan()
            composite.unregisterForConnectionEvents()
        }

        second.simulateStateChange(.poweredOn)
        // Two flushes are necessary. The state change hops onto the queue. The composite's
        // reconciliation runs inline on the delivery that it schedules.
        _ = await onQueue(queue) { true }
        _ = await onQueue(queue) { true }

        #expect(await onQueue(queue) { second.scanCallCount } == 0)
        #expect(await onQueue(queue) { second.connectionEventRegistrationCount } == 0)
    }

    // MARK: - CompositePeripheralManager

    @Test("add emits exactly one didAddService after every child has reported")
    func addEmitsOneCompletion() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.add")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        let added = Mutex<[(ServiceIdentifier, NSError?)]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .didAddService(let id, let error) = event { added.withLock { $0.append((id, error)) } }
            }
        }

        await onQueue(queue) { composite.add(Self.service) }
        await waitFor { added.withLock { !$0.isEmpty } }
        _ = await onQueue(queue) { true }

        #expect(added.withLock { $0.count } == 1)
        #expect(added.withLock { $0.first?.0 } == Self.heartRate)
        #expect(added.withLock { $0.first?.1 } == nil)
        #expect(await onQueue(queue) { first.addedServices.count } == 1)
        #expect(await onQueue(queue) { second.addedServices.count } == 1)
    }

    @Test("An addServiceError on the last child surfaces in the aggregated didAddService")
    func addServiceErrorSurfaces() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.addError")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        let failure = NSError(domain: "CompositeBackendTests", code: 7)
        let added = Mutex<[NSError?]>([])
        await onQueue(queue) {
            second.addServiceError = failure
            composite.eventHandler = { event in
                if case .didAddService(_, let error) = event { added.withLock { $0.append(error) } }
            }
        }

        await onQueue(queue) { composite.add(Self.service) }
        await waitFor { added.withLock { !$0.isEmpty } }
        _ = await onQueue(queue) { true }

        #expect(added.withLock { $0.count } == 1)
        #expect(added.withLock { $0.first ?? nil } == failure)
    }

    @Test("startAdvertising emits exactly one didStartAdvertising; isAdvertising follows the children")
    func startAdvertisingEmitsOnce() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.advertise")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        let started = Mutex<[NSError?]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .didStartAdvertising(let error) = event { started.withLock { $0.append(error) } }
            }
        }
        #expect(await onQueue(queue) { composite.isAdvertising } == false)

        await onQueue(queue) {
            composite.startAdvertising(PeripheralAdvertisement(localName: "Composite", serviceUUIDs: [Self.heartRate]))
        }
        await waitFor { started.withLock { !$0.isEmpty } }
        _ = await onQueue(queue) { true }

        #expect(started.withLock { $0.count } == 1)
        #expect(started.withLock { $0.first ?? nil } == nil)
        #expect(await onQueue(queue) { composite.isAdvertising })

        await onQueue(queue) { composite.stopAdvertising() }
        #expect(await onQueue(queue) { composite.isAdvertising } == false)
        #expect(await onQueue(queue) { first.stopAdvertisingCallCount } == 1)
        #expect(await onQueue(queue) { second.stopAdvertisingCallCount } == 1)
    }

    @Test("isAdvertising ignores a child that is not powered on")
    func isAdvertisingIgnoresAnOfflineChild() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.advertise.offline")
        let online = FakePeripheralManager(queue: queue, state: .poweredOn)
        let offline = FakePeripheralManager(queue: queue, state: .poweredOff)
        let composite = CompositePeripheralManager(backends: [online, offline], queue: queue)

        let started = Mutex<[NSError?]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .didStartAdvertising(let error) = event { started.withLock { $0.append(error) } }
            }
        }

        await onQueue(queue) {
            composite.startAdvertising(PeripheralAdvertisement(localName: "Composite", serviceUUIDs: [Self.heartRate]))
        }
        await waitFor { started.withLock { !$0.isEmpty } }
        _ = await onQueue(queue) { true }

        // The composite skipped the powered-off child. It never asked this child to advertise, and
        // the child could not report, so the composite advertises exactly as much as it can.
        #expect(await onQueue(queue) { offline.isAdvertising } == false)
        #expect(await onQueue(queue) { online.isAdvertising })
        #expect(await onQueue(queue) { composite.isAdvertising })

        await onQueue(queue) { composite.stopAdvertising() }
        #expect(await onQueue(queue) { composite.isAdvertising } == false)
    }

    @Test("Every child is offered every push, and a refusal does not stop the fan-out")
    func everyChildIsOfferedEveryPush() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.update")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        #expect(await onQueue(queue) {
            composite.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil)
        })

        // The second child refuses. The composite queues the value for it. One busy child does not
        // close the whole composite's window, so the composite still answers `true`.
        await onQueue(queue) { second.scriptedUpdateValueReturns = [false] }
        #expect(await onQueue(queue) {
            composite.updateValue(Data([2]), for: Self.measurement, onSubscribed: nil)
        })

        #expect(await onQueue(queue) { first.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { second.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { first.updateValueCalls.map(\.value) } == [Data([1]), Data([2])])
    }

    @Test("A push one child refused reaches it once, from its own FIFO, after it is ready")
    func aRefusedPushIsDeliveredOnceFromTheChildsQueue() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.retry")
        let accepting = FakePeripheralManager(queue: queue, state: .poweredOn)
        let refusing = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [accepting, refusing], queue: queue)

        let ready = Mutex<Int>(0)
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .readyToUpdateSubscribers = event { ready.withLock { $0 += 1 } }
            }
        }

        let value = Data([0xA5])
        // The second child's transmit queue is full, so it refuses and the value goes into its
        // FIFO. The composite still answers `true`, because nothing is lost.
        await onQueue(queue) { refusing.scriptedUpdateValueReturns = [false] }
        #expect(await onQueue(queue) {
            composite.updateValue(value, for: Self.measurement, onSubscribed: nil)
        })
        #expect(await onQueue(queue) { accepting.updateValueCalls.count } == 1)
        #expect(await onQueue(queue) { refusing.updateValueCalls.count } == 1)

        // That child's window reopens. Its FIFO drains and the value reaches it once. A second push
        // to the child that already took the value would duplicate it for its subscribers.
        refusing.simulateReadyToUpdate()
        await waitFor { ready.withLock { $0 } == 1 }
        #expect(await onQueue(queue) { accepting.updateValueCalls.count } == 1)
        #expect(await onQueue(queue) { refusing.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { refusing.updateValueCalls.map(\.value) } == [value, value])
        // Both offers carried the value, and only the second was accepted. Exactly one notification
        // reached that child's subscribers.

        #expect(await onQueue(queue) {
            composite.updateValue(Data([0x5A]), for: Self.measurement, onSubscribed: nil)
        })
        #expect(await onQueue(queue) { accepting.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { refusing.updateValueCalls.count } == 3)
    }

    @Test("A child that falls a whole window behind closes the composite's window")
    func afullChildQueueClosesTheWindow() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.window")
        let accepting = FakePeripheralManager(queue: queue, state: .poweredOn)
        let refusing = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [accepting, refusing], queue: queue)

        // A live child with a real transmit queue. It raises a readiness before it ever refuses,
        // which tells the composite that later refusals are back-pressure and not a dead handle.
        // The test does this before it installs the counter, so the host hears only the readiness
        // that the reopening owes it.
        refusing.simulateReadyToUpdate()
        await onQueue(queue) {}

        let ready = Mutex<Int>(0)
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .readyToUpdateSubscribers = event { ready.withLock { $0 += 1 } }
            }
        }

        let window = LinkFlowControl.updateValueWindow
        await onQueue(queue) { refusing.scriptedUpdateValueReturns = Array(repeating: false, count: window + 4) }
        for index in 0..<window {
            #expect(await onQueue(queue) {
                composite.updateValue(Data([UInt8(index % 256)]), for: Self.measurement, onSubscribed: nil)
            }, "push \(index) should have been queued")
        }

        // The FIFO is full, so the composite's window closes. The refused push reaches nobody, so
        // the caller's repeat offer is still the first delivery of that value.
        let acceptedByFirst = await onQueue(queue) { accepting.updateValueCalls.count }
        #expect(acceptedByFirst == window)
        #expect(await onQueue(queue) {
            composite.updateValue(Data([0xFF]), for: Self.measurement, onSubscribed: nil)
        } == false)
        #expect(await onQueue(queue) { accepting.updateValueCalls.count } == window)

        await onQueue(queue) { refusing.scriptedUpdateValueReturns = [] }
        refusing.simulateReadyToUpdate()
        await waitFor { ready.withLock { $0 } >= 1 }
        #expect(ready.withLock { $0 } == 1)
        #expect(await onQueue(queue) {
            composite.updateValue(Data([0xFF]), for: Self.measurement, onSubscribed: nil)
        })
    }

    @Test("A child whose FIFO fills is logged once, by index and characteristic")
    func afullChildQueueIsLoggedOnce() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.windowLog")
        let accepting = FakePeripheralManager(queue: queue, state: .poweredOn)
        let refusing = FakePeripheralManager(queue: queue, state: .poweredOn)
        let lines = Mutex<[String]>([])
        let composite = CompositePeripheralManager(
            backends: [accepting, refusing],
            queue: queue,
            log: { line in lines.withLock { $0.append(line) } }
        )

        // A live child, as above. It raises a readiness of its own, so the composite counts its
        // FIFO against the window.
        refusing.simulateReadyToUpdate()
        await onQueue(queue) {}

        let window = LinkFlowControl.updateValueWindow
        await onQueue(queue) { refusing.scriptedUpdateValueReturns = Array(repeating: false, count: window + 8) }
        for index in 0..<window {
            #expect(await onQueue(queue) {
                composite.updateValue(Data([UInt8(index % 256)]), for: Self.measurement, onSubscribed: nil)
            }, "push \(index) should have been queued")
        }
        for _ in 0..<3 {
            #expect(await onQueue(queue) {
                composite.updateValue(Data([0xFF]), for: Self.measurement, onSubscribed: nil)
            } == false)
        }

        let logged = lines.withLock { $0 }
        #expect(logged.count == 1)
        let line = logged.first ?? ""
        #expect(line.contains("child 1"))
        #expect(line.contains(Self.measurement.uuidString))
    }

    @Test("A child that never takes a push cannot latch the composite's window shut")
    func aChildWithADeadHandleNeverClosesTheWindow() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.deadHandle")
        let healthy = FakePeripheralManager(queue: queue, state: .poweredOn)
        let dead = FakePeripheralManager(queue: queue, state: .poweredOn)
        let lines = Mutex<[String]>([])
        let composite = CompositePeripheralManager(
            backends: [healthy, dead],
            queue: queue,
            log: { line in lines.withLock { $0.append(line) } }
        )
        let ready = Mutex<Int>(0)
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .readyToUpdateSubscribers = event { ready.withLock { $0 += 1 } }
            }
        }

        // This is the dead-handle behavior of the real `CBPeripheralManager`. Every push is refused
        // without reaching the radio, and the radio never raises `readyToUpdateSubscribers`.
        let window = LinkFlowControl.updateValueWindow
        let pushes = window + 8
        #expect(pushes >= 40)
        await onQueue(queue) { dead.scriptedUpdateValueReturns = Array(repeating: false, count: pushes * 2) }
        for index in 0..<pushes {
            #expect(await onQueue(queue) {
                composite.updateValue(Data([UInt8(index % 256)]), for: Self.measurement, onSubscribed: nil)
            }, "push \(index) must not be refused on a child that has taken nothing")
        }

        #expect(await onQueue(queue) { healthy.updateValueCalls.count } == pushes)
        #expect(await onQueue(queue) { healthy.updateValueCalls.map(\.value) } == (0..<pushes).map { Data([UInt8($0 % 256)]) })
        #expect(ready.withLock { $0 } == 0)
        #expect(await onQueue(queue) { composite.queuedCountForTesting(child: 1) } == window)
        #expect(lines.withLock { $0.count } == 1)
        #expect(lines.withLock { $0.first ?? "" }.contains("child 1"))

        // The child comes to life, as the readiness proves, and its FIFO drains in order. From here
        // the composite closes its window for this child again.
        await onQueue(queue) { dead.scriptedUpdateValueReturns = [] }
        let before = await onQueue(queue) { dead.updateValueCalls.count }
        dead.simulateReadyToUpdate()
        await waitFor { ready.withLock { $0 } == 1 }
        #expect(await onQueue(queue) { composite.queuedCountForTesting(child: 1) } == 0)
        let drained = await onQueue(queue) { Array(dead.updateValueCalls.map(\.value).dropFirst(before)) }
        #expect(drained == (8..<pushes).map { Data([UInt8($0 % 256)]) })
    }

    @Test("Concurrent pushes reach every child exactly once, in per-child order")
    func concurrentPushesAreDeliveredOncePerChild() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.concurrent")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        // Two tasks push at the same time. In every interleaving on `queue`, each value must reach
        // each child exactly once, and each task's values must stay in order.
        let left = (0..<20).map { Data([0x00, UInt8($0)]) }
        let right = (0..<20).map { Data([0x01, UInt8($0)]) }
        async let leftPushes: Void = {
            for value in left {
                _ = await onQueue(queue) { composite.updateValue(value, for: Self.measurement, onSubscribed: nil) }
            }
        }()
        async let rightPushes: Void = {
            for value in right {
                _ = await onQueue(queue) { composite.updateValue(value, for: Self.measurement, onSubscribed: nil) }
            }
        }()
        _ = await (leftPushes, rightPushes)

        for child in [first, second] {
            let delivered = await onQueue(queue) { child.updateValueCalls.map(\.value) }
            #expect(delivered.count == left.count + right.count)
            #expect(Set(delivered).count == delivered.count, "no value may be delivered twice")
            #expect(delivered.filter { $0.first == 0x00 } == left)
            #expect(delivered.filter { $0.first == 0x01 } == right)
        }
    }

    @Test("Two distinct pushes carrying the same bytes each reach every child")
    func identicalPayloadsAreNotMistakenForARetry() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.identicalPayloads")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        // The value, the characteristic, and the subscriber list (absent) are the same. The two
        // pushes are still separate. Neither may be mistaken for a retry of the other.
        let value = Data([0xA5])
        for _ in 0..<2 {
            #expect(await onQueue(queue) {
                composite.updateValue(value, for: Self.measurement, onSubscribed: nil)
            })
        }

        #expect(await onQueue(queue) { first.updateValueCalls.map(\.value) } == [value, value])
        #expect(await onQueue(queue) { second.updateValueCalls.map(\.value) } == [value, value])
    }

    @Test("readyToUpdateSubscribers from any child is forwarded")
    func readyToUpdateIsForwarded() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.ready")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        let ready = Mutex<Int>(0)
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .readyToUpdateSubscribers = event { ready.withLock { $0 += 1 } }
            }
        }

        second.simulateReadyToUpdate()
        await waitFor { ready.withLock { $0 == 1 } }
        #expect(ready.withLock { $0 } == 1)

        first.simulateReadyToUpdate()
        await waitFor { ready.withLock { $0 == 2 } }
        #expect(ready.withLock { $0 } == 2)
    }

    @Test("Peripheral composite state is .poweredOn when any child is; other events forward")
    func peripheralStateAndForwarding() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.peripheralState")
        let off = FakePeripheralManager(queue: queue, state: .poweredOff)
        let on = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [off, on], queue: queue)

        let states = Mutex<[CentralState]>([])
        let subscribes = Mutex<Int>(0)
        await onQueue(queue) {
            composite.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .didSubscribe: subscribes.withLock { $0 += 1 }
                default: break
                }
            }
        }
        await waitFor { states.withLock { !$0.isEmpty } }
        #expect(states.withLock { $0 } == [.poweredOn])
        #expect(await onQueue(queue) { composite.radioState } == .poweredOn)

        on.simulateSubscribe(central: Subscriber(id: UUID(), maximumUpdateValueLength: 20), to: Self.measurement)
        await waitFor { subscribes.withLock { $0 == 1 } }
        #expect(subscribes.withLock { $0 } == 1)
    }

    @Test("add and startAdvertising complete over a child that is not powered on")
    func addAndAdvertiseSkipAPoweredOffChild() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.addPoweredOff")
        let virtual = FakePeripheralManager(queue: queue, state: .poweredOn)
        let real = FakePeripheralManager(queue: queue, state: .poweredOff)
        let composite = CompositePeripheralManager(backends: [virtual, real], queue: queue)

        let added = Mutex<[NSError?]>([])
        let started = Mutex<[NSError?]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                switch event {
                case .didAddService(_, let error): added.withLock { $0.append(error) }
                case .didStartAdvertising(let error): started.withLock { $0.append(error) }
                default: break
                }
            }
        }

        // The powered-off child can never report a completion, so the composite must not wait for
        // it. The aggregate arrives from the powered-on child alone.
        await onQueue(queue) {
            composite.add(Self.service)
            composite.startAdvertising(PeripheralAdvertisement(localName: "Composite", serviceUUIDs: [Self.heartRate]))
        }
        await waitFor { added.withLock { !$0.isEmpty } && started.withLock { !$0.isEmpty } }
        _ = await onQueue(queue) { true }

        #expect(added.withLock { $0 } == [nil])
        #expect(started.withLock { $0 } == [nil])
        #expect(await onQueue(queue) { virtual.addedServices.count } == 1)
        #expect(await onQueue(queue) { virtual.startAdvertisingCallCount } == 1)
        #expect(await onQueue(queue) { real.addedServices.isEmpty })
        #expect(await onQueue(queue) { real.startAdvertisingCallCount } == 0)
    }

    @Test("With no powered-on child, add and startAdvertising complete with an error")
    func addAndAdvertiseFailWithNoOnlineChild() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.allPoweredOff")
        let first = FakePeripheralManager(queue: queue, state: .poweredOff)
        let second = FakePeripheralManager(queue: queue, state: .unauthorized)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        let added = Mutex<[NSError?]>([])
        let started = Mutex<[NSError?]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                switch event {
                case .didAddService(_, let error): added.withLock { $0.append(error) }
                case .didStartAdvertising(let error): started.withLock { $0.append(error) }
                default: break
                }
            }
        }

        await onQueue(queue) {
            composite.add(Self.service)
            composite.startAdvertising(PeripheralAdvertisement(localName: "Composite", serviceUUIDs: [Self.heartRate]))
        }
        await waitFor { added.withLock { !$0.isEmpty } && started.withLock { !$0.isEmpty } }
        _ = await onQueue(queue) { true }

        let expected = CompositePeripheralManager.noPoweredOnBackendError
        #expect(added.withLock { $0.count } == 1)
        #expect(added.withLock { $0.first ?? nil } == expected)
        #expect(started.withLock { $0.count } == 1)
        #expect(started.withLock { $0.first ?? nil } == expected)
        #expect(expected.domain == "BLESwiftProvider")
        #expect(expected.code == 9)
        #expect(expected.localizedDescription == "no powered-on backend")
        #expect(await onQueue(queue) { !composite.isAdvertising })

        first.simulateStateChange(.poweredOn)
        await waitFor { await self.onQueue(queue) { first.startAdvertisingCallCount } == 1 }
        #expect(await onQueue(queue) { first.addedServices.count } == 1)
        #expect(added.withLock { $0.count } == 1)
        #expect(started.withLock { $0.count } == 1)
    }

    @Test("A child that is not powered on never fills a FIFO, so the window never latches")
    func aPoweredOffChildNeverClosesTheWindow() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.windowPoweredOff")
        let virtual = FakePeripheralManager(queue: queue, state: .poweredOn)
        let real = FakePeripheralManager(queue: queue, state: .poweredOff)
        let composite = CompositePeripheralManager(backends: [virtual, real], queue: queue)

        // The count is far past the window. The composite skips the powered-off child outright and
        // does not queue for it, so no FIFO ever fills and the composite keeps accepting pushes.
        let pushes = LinkFlowControl.updateValueWindow * 2
        for index in 0..<pushes {
            #expect(await onQueue(queue) {
                composite.updateValue(Data([UInt8(index % 256)]), for: Self.measurement, onSubscribed: nil)
            }, "push \(index) should have been accepted")
        }

        #expect(await onQueue(queue) { virtual.updateValueCalls.count } == pushes)
        #expect(await onQueue(queue) { real.updateValueCalls.isEmpty })
    }

    @Test("With no powered-on child, updateValue is refused until one powers on")
    func updateValueIsRefusedWithNoOnlineChild() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.pushAllOff")
        let first = FakePeripheralManager(queue: queue, state: .poweredOff)
        let second = FakePeripheralManager(queue: queue, state: .unauthorized)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        let ready = Mutex<Int>(0)
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .readyToUpdateSubscribers = event { ready.withLock { $0 += 1 } }
            }
        }

        // No radio could carry the value, so a report that it was delivered or queued would be a
        // lie. `add` and `startAdvertising` refuse the same way when no child is powered on.
        #expect(await onQueue(queue) {
            composite.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil)
        } == false)
        #expect(await onQueue(queue) { first.updateValueCalls.isEmpty })
        #expect(await onQueue(queue) { second.updateValueCalls.isEmpty })
        #expect(ready.withLock { $0 } == 0)

        // The first child to power on reopens the window. The composite queued nothing for this
        // child, so no child would ever say by itself that it is ready.
        first.simulateStateChange(.poweredOn)
        await waitFor { ready.withLock { $0 } == 1 }
        #expect(ready.withLock { $0 } == 1)

        #expect(await onQueue(queue) {
            composite.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil)
        })
        #expect(await onQueue(queue) { first.updateValueCalls.count } == 1)
        #expect(await onQueue(queue) { second.updateValueCalls.isEmpty })
    }

    @Test("A child powering on later is caught up with the services and the advertisement")
    func aChildPoweringOnIsCaughtUp() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.powerUp")
        let virtual = FakePeripheralManager(queue: queue, state: .poweredOn)
        let real = FakePeripheralManager(queue: queue, state: .poweredOff)
        let composite = CompositePeripheralManager(backends: [virtual, real], queue: queue)

        let added = Mutex<[NSError?]>([])
        let started = Mutex<[NSError?]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                switch event {
                case .didAddService(_, let error): added.withLock { $0.append(error) }
                case .didStartAdvertising(let error): started.withLock { $0.append(error) }
                default: break
                }
            }
        }

        let advertisement = PeripheralAdvertisement(localName: "Composite", serviceUUIDs: [Self.heartRate])
        await onQueue(queue) {
            composite.add(Self.service)
            composite.startAdvertising(advertisement)
        }
        await waitFor { added.withLock { !$0.isEmpty } && started.withLock { !$0.isEmpty } }

        // The Mac's radio comes on in the middle of the session. The composite publishes again what
        // it hosts.
        real.simulateStateChange(.poweredOn)
        await waitFor {
            await onQueue(queue) { real.addedServices.count == 1 && real.startAdvertisingCallCount == 1 }
        }
        #expect(await onQueue(queue) { real.addedServices.first?.identifier } == Self.heartRate)
        #expect(await onQueue(queue) { real.lastAdvertisement?.localName } == "Composite")

        _ = await onQueue(queue) { true }
        #expect(added.withLock { $0 } == [nil])
        #expect(started.withLock { $0 } == [nil])

        #expect(await onQueue(queue) {
            composite.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil)
        })
        #expect(await onQueue(queue) { real.updateValueCalls.count } == 1)
    }

    @Test("A child powering off mid-add settles the pending it still owed")
    func aChildPoweringOffMidAddSettlesThePending() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.powerDownMidAdd")
        let virtual = FakePeripheralManager(queue: queue, state: .poweredOn)
        let real = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [virtual, real], queue: queue)

        let added = Mutex<[NSError?]>([])
        let failure = NSError(domain: "CompositeBackendTests", code: 13)
        await onQueue(queue) {
            // The radio drops out from inside the fan-out, after the add was issued but before its
            // completion is delivered. That completion carries an error, so a settlement that used
            // it would be visible here.
            real.addServiceError = failure
            real.onAddService = { _ in real.simulateStateChange(.poweredOff) }
            composite.eventHandler = { event in
                if case .didAddService(_, let error) = event { added.withLock { $0.append(error) } }
            }
        }

        await onQueue(queue) { composite.add(Self.service) }
        await waitFor { added.withLock { !$0.isEmpty } }
        _ = await onQueue(queue) { true }
        _ = await onQueue(queue) { true }

        // The power-off settles the batch. The child's late completion does not settle it. The
        // composite swallows that completion, so the host never hears the aggregate twice.
        #expect(added.withLock { $0 } == [nil])
        #expect(await onQueue(queue) { composite.radioState } == .poweredOn)
    }

    @Test("A handler that re-enters add() from a power-down keeps its own batches")
    func aReentrantAddFromPowerDownKeepsItsBatch() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.reentrantAdd")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        // The child abandons what it had in flight, so its power-down settles every batch. A
        // completion of its own does not settle any batch.
        let leaving = AbandoningPeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second, leaving], queue: queue)

        // There are several services, so the power-down walk settles one batch while others are
        // still ahead in the snapshot. A re-entrant `add()` used to lose these batches.
        let services = (1...8).map { index in
            GATTService(
                identifier: ServiceIdentifier(uuid: "18\(String(format: "%02X", index))"),
                characteristics: []
            )
        }
        let added = Mutex<[ServiceIdentifier]>([])
        let reentries = Mutex<Int>(0)
        await onQueue(queue) {
            // The child publishes but never reports it. Every batch stays owed to this child alone,
            // so the power-down below settles all of them in one walk.
            leaving.completesAdds = false
            composite.eventHandler = { event in
                guard case .didAddService(let identifier, _) = event else { return }
                added.withLock { $0.append(identifier) }
                // The handler goes straight back into the composite from the power-down callout.
                // The count is bounded to the power-down's completions, so the re-adds do not
                // recurse.
                let round = reentries.withLock { count -> Int in
                    count += 1
                    return count
                }
                guard round <= services.count else { return }
                for service in services { composite.add(service) }
            }
        }

        await onQueue(queue) {
            for service in services { composite.add(service) }
        }
        // Both powered-on children have reported, so only the child that is about to go still owes
        // a report. Nothing has reached the host yet.
        await waitFor {
            await self.onQueue(queue) {
                first.addedServices.count == services.count && second.addedServices.count == services.count
            }
        }
        _ = await onQueue(queue) { true }
        #expect(added.withLock { $0 }.isEmpty)

        leaving.simulateStateChange(.poweredOff)

        // One completion for each service for the power-down, then one for each re-add. There is
        // never one for each child.
        let expected = services.count + services.count * services.count
        await waitFor { added.withLock { $0.count } >= expected }
        _ = await onQueue(queue) { true }
        _ = await onQueue(queue) { true }
        #expect(added.withLock { $0 }.count == expected)
        for service in services {
            #expect(added.withLock { $0 }.filter { $0 == service.identifier }.count == 1 + services.count)
        }
    }

    @Test("respond and removeAllHostedServices fan out to every child")
    func respondAndRemoveFanOut() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.respond")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        let token = RequestToken()
        await onQueue(queue) {
            composite.respond(to: token, value: Data([9]), error: nil)
            composite.removeAllHostedServices()
        }

        #expect(await onQueue(queue) { first.respondCalls.count } == 1)
        #expect(await onQueue(queue) { second.respondCalls.count } == 1)
        #expect(await onQueue(queue) { first.removeAllServicesCallCount } == 1)
        #expect(await onQueue(queue) { second.removeAllServicesCallCount } == 1)
    }

    @Test("A child that abandons what it had in flight still hears its own completions again")
    func aChildThatAbandonsInFlightWorkIsNotOverCounted() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.abandon")
        let virtual = FakePeripheralManager(queue: queue, state: .poweredOn)
        let real = AbandoningPeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [virtual, real], queue: queue)

        let added = Mutex<[ServiceIdentifier]>([])
        let started = Mutex<Int>(0)
        await onQueue(queue) {
            // The radio drops out from inside the fan-out, after the add was issued and before
            // either completion could be delivered. The child abandons both, as a real
            // `CBPeripheralManager` does when it leaves `.poweredOn`. `FakePeripheralManager`
            // always answers, so it cannot model this.
            real.onAdd = { _ in real.simulateStateChange(.poweredOff) }
            composite.eventHandler = { event in
                switch event {
                case .didAddService(let identifier, _): added.withLock { $0.append(identifier) }
                case .didStartAdvertising: started.withLock { $0 += 1 }
                default: break
                }
            }
        }

        await onQueue(queue) {
            composite.add(Self.service)
            composite.startAdvertising(PeripheralAdvertisement(localName: "Composite", serviceUUIDs: [Self.heartRate]))
        }
        await waitFor { added.withLock { $0.count } == 1 && started.withLock { $0 } == 1 }
        _ = await onQueue(queue) { true }
        _ = await onQueue(queue) { true }
        #expect(added.withLock { $0 } == [Self.heartRate])
        #expect(started.withLock { $0 } == 1)

        // The radio is back on and stays on, so the catch-up completes. The composite swallows its
        // two completions, and the host hears nothing more.
        await onQueue(queue) { real.onAdd = nil }
        real.simulateStateChange(.poweredOn)
        await waitFor { await self.onQueue(queue) { real.addedServices.count == 2 && real.startAdvertisingCallCount == 2 } }
        _ = await onQueue(queue) { true }
        #expect(added.withLock { $0 } == [Self.heartRate])
        #expect(started.withLock { $0 } == 1)

        // Now the child publishes and advertises by itself. The composite never issued these
        // completions, so it must forward them. If it had counted the abandoned pair at power-down
        // time, both counters would be one operation too high and it would swallow them.
        real.publishOnItsOwn(Self.battery)
        real.advertiseOnItsOwn()
        await waitFor { added.withLock { $0.count } == 2 && started.withLock { $0 } == 2 }
        #expect(added.withLock { $0 } == [Self.heartRate, Self.battery])
        #expect(started.withLock { $0 } == 2)
    }

    // MARK: - Coalesced state transitions

    @Test("A child's coalesced power cycle still re-issues the scan")
    func coalescedCentralTransitionsStillReconcile() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.coalescedScan")
        let first = FakeCentral(queue: queue, state: .poweredOn)
        let second = FakeCentral(queue: queue, state: .poweredOn)
        let composite = CompositeCentral(backends: [first, second], queue: queue)
        await onQueue(queue) { composite.eventHandler = { _ in } }

        let options = ScanOptions(allowDuplicates: true)
        await onQueue(queue) { composite.scanForPeripherals(withServices: [Self.heartRate], options: options) }
        #expect(await onQueue(queue) { second.scanCallCount } == 1)

        // The child power-cycles. Both transitions land before the composite drains either one, so
        // its live `radioState` reads `.poweredOn` at both deliveries. Only the payloads record
        // that the child was off.
        await onQueue(queue) {
            let deliver = second.eventHandler
            deliver?(.didUpdateState(.poweredOff))
            deliver?(.didUpdateState(.poweredOn))
        }

        #expect(await onQueue(queue) { second.scanCallCount } == 2)
        #expect(await onQueue(queue) { second.lastScanServices } == [Self.heartRate])
        #expect(await onQueue(queue) { first.scanCallCount } == 1)
    }

    @Test("A peripheral child's coalesced power cycle still republishes and re-advertises")
    func coalescedPeripheralTransitionsStillReconcile() async {
        let queue = DispatchQueue(label: "CompositeBackendTests.coalescedPublish")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        let added = Mutex<[NSError?]>([])
        let started = Mutex<[NSError?]>([])
        await onQueue(queue) {
            composite.eventHandler = { event in
                switch event {
                case .didAddService(_, let error): added.withLock { $0.append(error) }
                case .didStartAdvertising(let error): started.withLock { $0.append(error) }
                default: break
                }
            }
            composite.add(Self.service)
            composite.startAdvertising(PeripheralAdvertisement(localName: "Composite", serviceUUIDs: [Self.heartRate]))
        }
        await waitFor { added.withLock { !$0.isEmpty } && started.withLock { !$0.isEmpty } }
        #expect(await onQueue(queue) { second.addedServices.count } == 1)
        #expect(await onQueue(queue) { second.startAdvertisingCallCount } == 1)

        // As above, two transitions coalesce, so only the payloads say that the child went away and
        // came back. The composite must catch up when the child comes back.
        await onQueue(queue) {
            let deliver = second.eventHandler
            deliver?(.didUpdateState(.poweredOff))
            deliver?(.didUpdateState(.poweredOn))
        }
        _ = await onQueue(queue) { true }

        #expect(await onQueue(queue) { second.addedServices.count } == 2)
        #expect(await onQueue(queue) { second.startAdvertisingCallCount } == 2)
        #expect(added.withLock { $0 } == [nil])
        #expect(started.withLock { $0 } == [nil])
    }
}

/// A peripheral-role child that answers only while its radio is on. It abandons in-flight work when
/// it leaves `.poweredOn`, and no completion for that work arrives.
///
/// `FakePeripheralManager` always answers an `add(_:)`, which is the case that
/// ``CompositePeripheralManager``'s swallow counters must not assume.
private final class AbandoningPeripheralManager: PeripheralManaging, Sendable {

    /// The queue that confines every method and every event delivery.
    let queue: DispatchQueue

    nonisolated(unsafe) private var _radioState: CentralState
    nonisolated(unsafe) private var _eventHandler: ((PeripheralHostEvent) -> Void)?
    nonisolated(unsafe) private var _addedServices: [ServiceIdentifier] = []
    nonisolated(unsafe) private var _startAdvertisingCallCount = 0
    nonisolated(unsafe) private var _onAdd: ((GATTService) -> Void)?
    nonisolated(unsafe) private var _completesAdds = true

    init(queue: DispatchQueue, state: CentralState) {
        self.queue = queue
        self._radioState = state
    }

    static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    var eventHandler: ((PeripheralHostEvent) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _eventHandler }
        set { dispatchPrecondition(condition: .onQueue(queue)); _eventHandler = newValue }
    }

    var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _radioState
    }

    var isAdvertising: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return _startAdvertisingCallCount > 0 && _radioState == .poweredOn
    }

    /// The services that this child received a request to publish, in order.
    var addedServices: [ServiceIdentifier] {
        dispatchPrecondition(condition: .onQueue(queue))
        return _addedServices
    }

    /// The number of times that this child received a request to advertise.
    var startAdvertisingCallCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _startAdvertisingCallCount
    }

    /// Called synchronously from ``add(_:)``, before its completion is scheduled. A test uses this
    /// hook to make the radio go away in the middle of an operation.
    var onAdd: ((GATTService) -> Void)? {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _onAdd }
        set { dispatchPrecondition(condition: .onQueue(queue)); _onAdd = newValue }
    }

    /// Whether ``add(_:)`` reports a completion at all. The radio is still publishing when its
    /// power goes, so the composite holds a batch that only a power-down can settle.
    var completesAdds: Bool {
        get { dispatchPrecondition(condition: .onQueue(queue)); return _completesAdds }
        set { dispatchPrecondition(condition: .onQueue(queue)); _completesAdds = newValue }
    }

    func add(_ service: GATTService) {
        dispatchPrecondition(condition: .onQueue(queue))
        _addedServices.append(service.identifier)
        _onAdd?(service)
        queue.async { [self] in
            guard _radioState == .poweredOn, _completesAdds else { return }
            _eventHandler?(.didAddService(service.identifier, error: nil))
        }
    }

    func startAdvertising(_ advertisement: PeripheralAdvertisement) {
        dispatchPrecondition(condition: .onQueue(queue))
        _startAdvertisingCallCount += 1
        queue.async { [self] in
            guard _radioState == .poweredOn else { return }
            _eventHandler?(.didStartAdvertising(error: nil))
        }
    }

    func stopAdvertising() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    func removeAllHostedServices() {
        dispatchPrecondition(condition: .onQueue(queue))
        _addedServices.removeAll()
    }

    func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return true
    }

    /// Simulates a radio state change. Delivers `didUpdateState` on ``queue``.
    func simulateStateChange(_ newState: CentralState) {
        queue.async { [self] in
            _radioState = newState
            _eventHandler?(.didUpdateState(newState))
        }
    }

    /// Simulates the child publishing a service of its own. The composite never issued this
    /// completion, so it must forward it.
    func publishOnItsOwn(_ identifier: ServiceIdentifier) {
        queue.async { [self] in _eventHandler?(.didAddService(identifier, error: nil)) }
    }

    /// Simulates the child starting an advertisement of its own, for the same reason.
    func advertiseOnItsOwn() {
        queue.async { [self] in _eventHandler?(.didStartAdvertising(error: nil)) }
    }
}
#endif
