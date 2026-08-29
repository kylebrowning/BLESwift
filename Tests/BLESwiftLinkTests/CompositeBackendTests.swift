//
//  CompositeBackendTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
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

    @Test("startAdvertising emits exactly one didStartAdvertising; isAdvertising is allSatisfy")
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

    @Test("updateValue is the AND of every child's return")
    func updateValueIsTheAndOfChildren() async {
        let queue = DispatchSerialQueue(label: "CompositeBackendTests.update")
        let first = FakePeripheralManager(queue: queue, state: .poweredOn)
        let second = FakePeripheralManager(queue: queue, state: .poweredOn)
        let composite = CompositePeripheralManager(backends: [first, second], queue: queue)

        #expect(await onQueue(queue) {
            composite.updateValue(Data([1]), for: Self.measurement, onSubscribed: nil)
        })

        await onQueue(queue) { second.scriptedUpdateValueReturns = [false] }
        #expect(await onQueue(queue) {
            composite.updateValue(Data([2]), for: Self.measurement, onSubscribed: nil)
        } == false)

        // Every child still saw both pushes — the AND never short-circuits the fan-out.
        #expect(await onQueue(queue) { first.updateValueCalls.count } == 2)
        #expect(await onQueue(queue) { second.updateValueCalls.count } == 2)
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
