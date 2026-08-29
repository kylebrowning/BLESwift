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
import Synchronization
import Testing

/// ``CompositeCentral``/``CompositePeripheralManager``: one backend made of several, with
/// every call fanned out and every event fanned in on the single shared queue.
@Suite("Composite backends")
struct CompositeBackendTests {

    // MARK: - Helpers

    /// Hops onto `queue` to run `body` and returns its result — the sanctioned door for
    /// off-queue test code to touch queue-confined state, and (because `queue` is serial)
    /// a flush of every previously-scheduled `.async` delivery.
    private func onQueue<T: Sendable>(_ queue: DispatchSerialQueue, _ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

    private static var service: GATTService {
        GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable])
        ])
    }

    // MARK: - CompositeCentral

    @Test("Composite state is .poweredOn when any child is, and is announced once on attach")
    func stateIsPoweredOnWhenAnyChildIs() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.state")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.stateFlip")
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

        // One child off is not enough — the composite is still served by the other.
        first.simulateStateChange(.poweredOff)
        _ = await onQueue(queue) { true }
        #expect(states.withLock { $0 } == [.poweredOn])

        second.simulateStateChange(.poweredOff)
        await waitFor { states.withLock { $0.count == 2 } }
        #expect(states.withLock { $0 } == [.poweredOn, .poweredOff])

        // A redundant child update does not re-emit.
        second.simulateStateChange(.poweredOff)
        _ = await onQueue(queue) { true }
        #expect(states.withLock { $0 } == [.poweredOn, .poweredOff])
    }

    @Test("Every call fans out to every child")
    func callsFanOutToEveryChild() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.fanOut")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.retrieve")
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

        // First backend wins the duplicate.
        let winner = await onQueue(queue) {
            composite.retrievePeripherals(withIdentifiers: [shared.identifier]).first.map { $0 === shared } ?? false
        }
        #expect(winner)
    }

    @Test("retrieveConnectedPeripherals concatenates across children")
    func retrieveConnectedReachesEveryChild() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.retrieveConnected")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.connect")
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

        // Retrieve and connect in one hop — `any PeripheralRemote` is not `Sendable`, so
        // the remote never leaves the queue it is confined to.
        let retrievedCount = await onQueue(queue) {
            let retrieved = composite.retrievePeripherals(withIdentifiers: [peripheral.identifier])
            for remote in retrieved { composite.connect(remote, options: nil, requiresANCS: false) }
            return retrieved.count
        }
        #expect(retrievedCount == 1)

        await waitFor { connected.withLock { !$0.isEmpty } }
        #expect(connected.withLock { $0 }.contains(peripheral.identifier))
        // Fanned out to every child; mismatched families would have been silent no-ops.
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.central")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.detach")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.rescan")
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

        // CoreBluetooth would have dropped both on a child that is not powered on, so the
        // composite does not issue them at all — it holds them.
        #expect(await onQueue(queue) { first.scanCallCount } == 1)
        #expect(await onQueue(queue) { second.scanCallCount } == 0)
        #expect(await onQueue(queue) { second.connectionEventRegistrationCount } == 0)

        second.simulateStateChange(.poweredOn)
        await waitFor { await self.onQueue(queue) { second.scanCallCount } == 1 }

        #expect(await onQueue(queue) { second.scanCallCount } == 1)
        #expect(await onQueue(queue) { second.lastScanServices } == [Self.heartRate])
        #expect(await onQueue(queue) { second.lastScanOptions } == options)
        #expect(await onQueue(queue) { second.connectionEventRegistrationCount } == 1)
        // The child that was on all along was issued the scan exactly once.
        #expect(await onQueue(queue) { first.scanCallCount } == 1)
        // Logged once for the child, not once per operation it was skipped for.
        #expect(skipped.withLock { $0.count } == 1)
        #expect(skipped.withLock { $0.first }?.contains("composite child 1") == true)
    }

    @Test("A scan stopped before a child powers on is not re-issued to it")
    func aStoppedScanIsNotReissued() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.rescanStopped")
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
        // Two flushes: the state change hops onto the queue, and the composite's reconciliation
        // runs inline on the delivery it schedules.
        _ = await onQueue(queue) { true }
        _ = await onQueue(queue) { true }

        #expect(await onQueue(queue) { second.scanCallCount } == 0)
        #expect(await onQueue(queue) { second.connectionEventRegistrationCount } == 0)
    }

    // MARK: - CompositePeripheralManager

    @Test("add emits exactly one didAddService after every child has reported")
    func addEmitsOneCompletion() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.add")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.addError")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.advertise")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.advertise.offline")
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

        // The powered-off child was skipped, never asked to advertise, and could not report —
        // so the composite is advertising exactly as much as it can be.
        #expect(await onQueue(queue) { offline.isAdvertising } == false)
        #expect(await onQueue(queue) { online.isAdvertising })
        #expect(await onQueue(queue) { composite.isAdvertising })

        // And a stop still takes it back down: nothing online is advertising any more.
        await onQueue(queue) { composite.stopAdvertising() }
        #expect(await onQueue(queue) { composite.isAdvertising } == false)
    }

    @Test("Every child is offered every push, and a refusal does not stop the fan-out")
    func everyChildIsOfferedEveryPush() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.update")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        #expect(await onQueue(queue) {
            composite.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil)
        })

        // The second child refuses. The composite queues the value for it — one child being
        // busy is not the whole composite's window closing — and still answers `true`.
        await onQueue(queue) { second.scriptedUpdateValueReturns = [false] }
        #expect(await onQueue(queue) {
            composite.updateValue(Data([2]), for: Self.measurement, onSubscribed: nil)
        })

        // Both children were offered both pushes: the refusal never short-circuits the
        // fan-out, and the first child is not held back by the second.
        #expect(await onQueue(queue) { first.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { second.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { first.updateValueCalls.map(\.value) } == [Data([1]), Data([2])])
    }

    @Test("A push one child refused reaches it once, from its own FIFO, after it is ready")
    func aRefusedPushIsDeliveredOnceFromTheChildsQueue() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.retry")
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
        // The second child's transmit queue is full, so it refuses; the value goes into that
        // child's FIFO and the composite still answers `true` — nothing is lost, and the
        // caller is not asked to re-offer a value one child already has.
        await onQueue(queue) { refusing.scriptedUpdateValueReturns = [false] }
        #expect(await onQueue(queue) {
            composite.updateValue(value, for: Self.measurement, onSubscribed: nil)
        })
        #expect(await onQueue(queue) { accepting.updateValueCalls.count } == 1)
        #expect(await onQueue(queue) { refusing.updateValueCalls.count } == 1)

        // That child's window reopens: its FIFO drains, and the value reaches it — once. The
        // child that already took it is not pushed to a second time, or its subscribers would
        // see a duplicate.
        refusing.simulateReadyToUpdate()
        await waitFor { ready.withLock { $0 } == 1 }
        #expect(await onQueue(queue) { accepting.updateValueCalls.count } == 1)
        #expect(await onQueue(queue) { refusing.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { refusing.updateValueCalls.map(\.value) } == [value, value])
        // Both offers carried the value; only the second was accepted, so exactly one
        // notification reached that child's subscribers.

        // And the next push fans out to every child again, from an empty FIFO.
        #expect(await onQueue(queue) {
            composite.updateValue(Data([0x5A]), for: Self.measurement, onSubscribed: nil)
        })
        #expect(await onQueue(queue) { accepting.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { refusing.updateValueCalls.count } == 3)
    }

    @Test("A child that falls a whole window behind closes the composite's window")
    func afullChildQueueClosesTheWindow() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.window")
        let accepting = FakePeripheralManager(queue: queue, state: .poweredOn)
        let refusing = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [accepting, refusing], queue: queue)

        let ready = Mutex<Int>(0)
        await onQueue(queue) {
            composite.eventHandler = { event in
                if case .readyToUpdateSubscribers = event { ready.withLock { $0 += 1 } }
            }
        }

        // The second child refuses everything, so its FIFO fills to the window.
        let window = LinkFlowControl.updateValueWindow
        await onQueue(queue) { refusing.scriptedUpdateValueReturns = Array(repeating: false, count: window + 4) }
        for index in 0..<window {
            #expect(await onQueue(queue) {
                composite.updateValue(Data([UInt8(index % 256)]), for: Self.measurement, onSubscribed: nil)
            }, "push \(index) should have been queued")
        }

        // Full: the composite's window closes, and the refused push reaches nobody — so the
        // caller's re-offer of it is still that value's first delivery.
        let acceptedByFirst = await onQueue(queue) { accepting.updateValueCalls.count }
        #expect(acceptedByFirst == window)
        #expect(await onQueue(queue) {
            composite.updateValue(Data([0xFF]), for: Self.measurement, onSubscribed: nil)
        } == false)
        #expect(await onQueue(queue) { accepting.updateValueCalls.count } == window)

        // The refusing child comes back: its FIFO drains, and one readiness reaches the host.
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.windowLog")
        let accepting = FakePeripheralManager(queue: queue, state: .poweredOn)
        let refusing = FakePeripheralManager(queue: queue, state: .poweredOn)
        let lines = Mutex<[String]>([])
        let composite = CompositePeripheralManager(
            backends: [accepting, refusing],
            queue: queue,
            log: { line in lines.withLock { $0.append(line) } }
        )

        // The second child refuses everything, permanently: nothing drains its FIFO.
        let window = LinkFlowControl.updateValueWindow
        await onQueue(queue) { refusing.scriptedUpdateValueReturns = Array(repeating: false, count: window + 8) }
        for index in 0..<window {
            #expect(await onQueue(queue) {
                composite.updateValue(Data([UInt8(index % 256)]), for: Self.measurement, onSubscribed: nil)
            }, "push \(index) should have been queued")
        }
        // Pushes past the full FIFO are refused, and earn no further lines.
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

    @Test("Concurrent pushes reach every child exactly once, in per-child order")
    func concurrentPushesAreDeliveredOncePerChild() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.concurrent")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        // Two tasks pushing at once. Every push still lands on `queue`, so the composite sees
        // some interleaving of the two sequences — whichever it is, each value must reach
        // each child exactly once, and each task's own values must stay in order.
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.identicalPayloads")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        // Same value, same characteristic, same (absent) subscriber list — two separate
        // pushes all the same. Neither may be mistaken for a retry of the other.
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.ready")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.peripheralState")
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
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.addPoweredOff")
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

        // The powered-off child can never report a completion, so the composite must not wait
        // on it: the aggregate arrives from the powered-on child alone.
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
        // Nothing was even offered to the radio that is off.
        #expect(await onQueue(queue) { real.addedServices.isEmpty })
        #expect(await onQueue(queue) { real.startAdvertisingCallCount } == 0)
    }

    @Test("A child that is not powered on never fills a FIFO, so the window never latches")
    func aPoweredOffChildNeverClosesTheWindow() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.windowPoweredOff")
        let virtual = FakePeripheralManager(queue: queue, state: .poweredOn)
        let real = FakePeripheralManager(queue: queue, state: .poweredOff)
        let composite = CompositePeripheralManager(backends: [virtual, real], queue: queue)

        // Far past the window: the powered-off child is skipped outright rather than queued
        // for, so no FIFO ever fills and the composite keeps accepting pushes.
        let pushes = LinkFlowControl.updateValueWindow * 2
        for index in 0..<pushes {
            #expect(await onQueue(queue) {
                composite.updateValue(Data([UInt8(index % 256)]), for: Self.measurement, onSubscribed: nil)
            }, "push \(index) should have been accepted")
        }

        #expect(await onQueue(queue) { virtual.updateValueCalls.count } == pushes)
        #expect(await onQueue(queue) { real.updateValueCalls.isEmpty })
    }

    @Test("A child powering on later is caught up with the services and the advertisement")
    func aChildPoweringOnIsCaughtUp() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.powerUp")
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

        // The Mac's radio comes on mid-session: the composite republishes what it is hosting.
        real.simulateStateChange(.poweredOn)
        await waitFor {
            await onQueue(queue) { real.addedServices.count == 1 && real.startAdvertisingCallCount == 1 }
        }
        #expect(await onQueue(queue) { real.addedServices.first?.identifier } == Self.heartRate)
        #expect(await onQueue(queue) { real.lastAdvertisement?.localName } == "Composite")

        // The catch-up is the composite's own business: the host hears no second completion.
        _ = await onQueue(queue) { true }
        #expect(added.withLock { $0 } == [nil])
        #expect(started.withLock { $0 } == [nil])

        // And it now takes its share of the pushes.
        #expect(await onQueue(queue) {
            composite.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil)
        })
        #expect(await onQueue(queue) { real.updateValueCalls.count } == 1)
    }

    @Test("A child powering off mid-add settles the pending it still owed")
    func aChildPoweringOffMidAddSettlesThePending() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.powerDownMidAdd")
        let virtual = FakePeripheralManager(queue: queue, state: .poweredOn)
        let real = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [virtual, real], queue: queue)

        let added = Mutex<[NSError?]>([])
        let failure = NSError(domain: "CompositeBackendTests", code: 13)
        await onQueue(queue) {
            // The radio drops out from inside the fan-out, after the composite has issued the
            // add to it but before its completion is delivered — and that completion carries
            // an error, so a settlement that carried it would be visible here.
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

        // Settled by the power-off, not by the child's own late completion — which is
        // swallowed, so the host never hears the aggregate twice.
        #expect(added.withLock { $0 } == [nil])
        #expect(await onQueue(queue) { composite.radioState } == .poweredOn)
    }

    @Test("respond and removeAllHostedServices fan out to every child")
    func respondAndRemoveFanOut() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.respond")
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
}
#endif
