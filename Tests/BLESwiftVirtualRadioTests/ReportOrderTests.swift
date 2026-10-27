//
//  ReportOrderTests.swift
//  BLESwiftVirtualRadioTests
//

import BLESwift
import BLESwiftCore
import BLESwiftVirtualRadio
import Foundation
import Testing

/// A device's subscription reports reach its handler in the order the radio applied the
/// changes (#76): a subscribe whose report is still in flight is finished before the
/// unsubscribe of whatever drops it, whichever path drops it, and a handler that calls back
/// into the radio from inside a report neither deadlocks nor sees its own reports out of
/// order. `burstLeavesNoChain` is a chain-hygiene test only: the remote's serial chain
/// already orders the calls it makes, so it proves nothing about ordering.
@Suite("Subscription report order")
struct ReportOrderTests {

    /// A handler whose subscribe report does not return until the test releases it, so the
    /// test controls exactly when the radio's subscribe finishes reporting — and can land a
    /// drop while it is suspended.
    private actor GatedSubscribeHandler: VirtualDeviceHandler {
        /// Each change in the order the handler *finished* it, which is the order a hosted
        /// `PeripheralHost` would act on them.
        private(set) var log: [Bool] = []
        let subscriptions: AsyncStream<Bool>
        private let subscriptionsContinuation: AsyncStream<Bool>.Continuation
        /// Yields once the subscribe is suspended on the gate.
        let blocked: AsyncStream<Void>
        private let blockedContinuation: AsyncStream<Void>.Continuation
        private let gate: AsyncStream<Void>

        init(gate: AsyncStream<Void>) {
            self.gate = gate
            (subscriptions, subscriptionsContinuation) = AsyncStream.makeStream()
            (blocked, blockedContinuation) = AsyncStream.makeStream()
        }

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .success(Data())
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .success(())
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
            if isSubscribed {
                blockedContinuation.yield(())
                for await _ in gate { break }
            }
            log.append(isSubscribed)
            subscriptionsContinuation.yield(isSubscribed)
        }
    }

    /// What ``ReentrantHandler`` does on hearing a subscribe.
    private enum Reentry {
        case setServicesEmpty
        case disconnect
    }

    /// A handler that calls back into the radio from inside its own subscribe report — the
    /// shape that would deadlock if the radio waited for the reports that call enqueues.
    private actor ReentrantHandler: VirtualDeviceHandler {
        private(set) var log: [Bool] = []
        let subscriptions: AsyncStream<Bool>
        private let subscriptionsContinuation: AsyncStream<Bool>.Continuation
        private let reentry: Reentry
        private var handle: VirtualDeviceHandle?

        init(reentry: Reentry) {
            self.reentry = reentry
            (subscriptions, subscriptionsContinuation) = AsyncStream.makeStream()
        }

        func attach(_ handle: VirtualDeviceHandle) {
            self.handle = handle
        }

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .success(Data())
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .success(())
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
            if isSubscribed {
                switch reentry {
                case .setServicesEmpty: await handle?.setServices([])
                case .disconnect: await handle?.disconnect()
                }
            }
            log.append(isSubscribed)
            subscriptionsContinuation.yield(isSubscribed)
        }
    }

    /// A connected `Central` subscribed to the fixture's dynamic characteristic, with the
    /// handler's subscribe report suspended on the gate.
    private static func subscribeAndBlock(
        on radio: VirtualRadio,
        device: VirtualDevice,
        handler: GatedSubscribeHandler,
        label: String
    ) async throws -> (central: Central, backend: VirtualCentralBackend, id: PeripheralIdentifier, stream: Task<Void, Never>) {
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, backend, _) = await RecordingDevice.central(on: radio, label: label)
        let peripheral = try await central.connect(id)
        let stream = Task {
            do {
                for try await _ in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {}
            } catch {}
        }
        _ = await RecordingDevice.first(of: handler.blocked)
        #expect(await radio.isSubscribed(session: backend.sessionID, characteristic: RecordingDevice.control))
        return (central, backend, id, stream)
    }

    /// The error the first `.disconnected` event for `id` on `events` carries.
    private static func disconnectError(for id: PeripheralIdentifier, on events: AsyncStream<ConnectionEvent>) async -> NSError? {
        for await event in events {
            if case .disconnected(let peripheral, let error, _) = event, peripheral == id {
                return error.map { $0 as NSError }
            }
        }
        return nil
    }

    /// Runs `trigger` off the test task, since it cannot return until the gate opens. The
    /// test then waits for the synchronous table change the drop makes before it opens the
    /// gate: the ordering under test is of a drop that has *landed* while the subscribe
    /// report is suspended, not one that arrives after it returned — and the gate opening
    /// first would let the unfixed radio pass by luck.
    private static func launch(_ trigger: @escaping @Sendable () async -> Void) async -> Task<Void, Never> {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            startedContinuation.yield(())
            await trigger()
        }
        _ = await RecordingDevice.first(of: started)
        return task
    }

    @Test("A forced disconnect's unsubscribe waits for the subscribe report in flight", .timeLimit(.minutes(1)))
    func forcedDisconnectWaitsForTheSubscribe() async throws {
        let radio = VirtualRadio()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let handler = GatedSubscribeHandler(gate: gate)
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let (central, backend, id, stream) = try await Self.subscribeAndBlock(
            on: radio, device: device, handler: handler, label: "ReportOrderTests.forcedDisconnect"
        )
        let events = await central.connectionEvents()

        let drop = await Self.launch { await handle.disconnect() }
        await RecordingDevice.waitFor { await !radio.isConnected(session: backend.sessionID, device: id.uuid) }
        release.yield(())

        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        await drop.value
        #expect(await handler.log == [true, false])
        #expect(await Self.disconnectError(for: id, on: events)?.code == VirtualRadio.peripheralDisconnectedError.code)
        #expect(await radio.subscriberCount(device: id.uuid, characteristic: RecordingDevice.control) == 0)
        #expect(await !radio.isConnected(session: backend.sessionID, device: id.uuid))
        #expect(await radio.reportChainCount == 0)

        release.finish()
        stream.cancel()
    }

    @Test("A removal's unsubscribe waits for the subscribe report in flight", .timeLimit(.minutes(1)))
    func removalWaitsForTheSubscribe() async throws {
        let radio = VirtualRadio()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let handler = GatedSubscribeHandler(gate: gate)
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let (central, backend, id, stream) = try await Self.subscribeAndBlock(
            on: radio, device: device, handler: handler, label: "ReportOrderTests.remove"
        )
        let events = await central.connectionEvents()

        let removal = await Self.launch { await handle.remove() }
        await RecordingDevice.waitFor { await !radio.isConnected(session: backend.sessionID, device: id.uuid) }
        release.yield(())

        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        await removal.value
        #expect(await handler.log == [true, false])
        #expect(await Self.disconnectError(for: id, on: events)?.code == VirtualRadio.deviceRemovedError.code)
        #expect(await radio.subscriberCount(device: id.uuid, characteristic: RecordingDevice.control) == 0)
        #expect(await !radio.isConnected(session: backend.sessionID, device: id.uuid))
        #expect(!radio.knownDeviceIDs.withLock { $0.contains(id.uuid) })
        #expect(await radio.reportChainCount == 0)

        release.finish()
        stream.cancel()
    }

    @Test("setServices dropping the characteristic waits for the subscribe report in flight", .timeLimit(.minutes(1)))
    func setServicesWaitsForTheSubscribe() async throws {
        let radio = VirtualRadio()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let handler = GatedSubscribeHandler(gate: gate)
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let (central, backend, id, stream) = try await Self.subscribeAndBlock(
            on: radio, device: device, handler: handler, label: "ReportOrderTests.setServices"
        )

        let republish = await Self.launch { await handle.setServices([]) }
        await RecordingDevice.waitFor { await radio.subscriberCount(device: id.uuid, characteristic: RecordingDevice.control) == 0 }
        release.yield(())

        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        await republish.value
        #expect(await handler.log == [true, false])
        #expect(await radio.subscriberCount(device: id.uuid, characteristic: RecordingDevice.control) == 0)
        // The service went, not the connection.
        #expect(await radio.isConnected(session: backend.sessionID, device: id.uuid))
        #expect(await RecordingDevice.isConnected(central, id))
        #expect(await radio.reportChainCount == 0)

        release.finish()
        stream.cancel()
        try await central.disconnect(id)
    }

    @Test("A re-registration's retirement waits for the subscribe report in flight, and the new handler hears nothing", .timeLimit(.minutes(1)))
    func reregistrationWaitsForTheSubscribe() async throws {
        let radio = VirtualRadio()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let oldHandler = GatedSubscribeHandler(gate: gate)
        let device = RecordingDevice.make(handler: oldHandler)
        await radio.register(device)
        let (central, backend, id, stream) = try await Self.subscribeAndBlock(
            on: radio, device: device, handler: oldHandler, label: "ReportOrderTests.reregister"
        )
        let events = await central.connectionEvents()

        let newHandler = RecordingHandler()
        let reregister = await Self.launch {
            await radio.register(RecordingDevice.make(identifier: id.uuid, handler: newHandler))
        }
        await RecordingDevice.waitFor { await !radio.isConnected(session: backend.sessionID, device: id.uuid) }
        release.yield(())

        #expect(await RecordingDevice.first(of: oldHandler.subscriptions) == true)
        #expect(await RecordingDevice.first(of: oldHandler.subscriptions) == false)
        await reregister.value
        #expect(await oldHandler.log == [true, false])
        #expect(await newHandler.subscriptionLog.isEmpty)
        #expect(await Self.disconnectError(for: id, on: events)?.code == VirtualRadio.deviceRemovedError.code)
        #expect(await radio.subscriberCount(device: id.uuid, characteristic: RecordingDevice.control) == 0)
        #expect(await !radio.isConnected(session: backend.sessionID, device: id.uuid))
        #expect(radio.knownDeviceIDs.withLock { $0.contains(id.uuid) })
        #expect(await radio.reportChainCount == 0)

        release.finish()
        stream.cancel()
    }

    @Test("A handler calling setServices from inside its subscribe report completes, and hears the unsubscribe after it", .timeLimit(.minutes(1)))
    func reentrantSetServicesDoesNotDeadlock() async throws {
        let radio = VirtualRadio()
        let handler = ReentrantHandler(reentry: .setServicesEmpty)
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        await handler.attach(handle)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, backend, _) = await RecordingDevice.central(on: radio, label: "ReportOrderTests.reentrantSetServices")
        let peripheral = try await central.connect(id)

        let stream = Task {
            do {
                for try await _ in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {}
            } catch {}
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        #expect(await handler.log == [true, false])
        #expect(await radio.subscriberCount(device: id.uuid, characteristic: RecordingDevice.control) == 0)
        #expect(await radio.isConnected(session: backend.sessionID, device: id.uuid))
        #expect(await radio.reportChainCount == 0)

        stream.cancel()
        try await central.disconnect(id)
    }

    @Test("A handler calling disconnect from inside its subscribe report completes, and hears the unsubscribe after it", .timeLimit(.minutes(1)))
    func reentrantDisconnectDoesNotDeadlock() async throws {
        let radio = VirtualRadio()
        let handler = ReentrantHandler(reentry: .disconnect)
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        await handler.attach(handle)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, backend, _) = await RecordingDevice.central(on: radio, label: "ReportOrderTests.reentrantDisconnect")
        let peripheral = try await central.connect(id)
        let events = await central.connectionEvents()

        let stream = Task {
            do {
                for try await _ in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {}
            } catch {}
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        #expect(await handler.log == [true, false])
        #expect(await Self.disconnectError(for: id, on: events)?.code == VirtualRadio.peripheralDisconnectedError.code)
        #expect(await radio.subscriberCount(device: id.uuid, characteristic: RecordingDevice.control) == 0)
        #expect(await !radio.isConnected(session: backend.sessionID, device: id.uuid))
        #expect(await radio.reportChainCount == 0)

        stream.cancel()
    }

    /// Every `CentralEvent` a backend delivered, read and written on the backend's queue only.
    private final class EventLog: @unchecked Sendable {
        var events: [CentralEvent] = []
    }

    @Test("A forced disconnect with nothing in flight delivers didDisconnect before it returns", .timeLimit(.minutes(1)))
    func forcedDisconnectWithNothingInFlightIsImmediate() async throws {
        let radio = VirtualRadio()
        let handler = RecordingHandler()
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let identifier = device.descriptor.identifier
        let queue = DispatchQueue(label: "ReportOrderTests.immediate")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await RecordingDevice.onQueue(queue) {
            backend.eventHandler = { log.events.append($0) }
            return backend.retrievePeripherals(withIdentifiers: [identifier]).first as! VirtualPeripheralRemote
        }
        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await backend.waitForPendingWork()
        await RecordingDevice.onQueue(queue) {}
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .connected)
        #expect(await radio.reportChainCount == 0)

        // No subscription to drop and no report queued: the didDisconnect went out in the
        // same actor turn as the drop, so once the queue has run what the radio sent it,
        // before `disconnect()` returned, the event is there — nothing else to wait for.
        await RecordingDevice.onQueue(queue) { log.events.removeAll() }
        await handle.disconnect()
        await RecordingDevice.onQueue(queue) {}
        let disconnects = await RecordingDevice.onQueue(queue) {
            log.events.compactMap { event -> NSError?? in
                if case .didDisconnect(let peripheral, let error) = event, peripheral.uuid == identifier { return .some(error) }
                return nil
            }
        }
        #expect(disconnects.count == 1)
        #expect(disconnects.first??.code == VirtualRadio.peripheralDisconnectedError.code)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        #expect(await !radio.isConnected(session: backend.sessionID, device: identifier))
        #expect(await radio.reportChainCount == 0)
        #expect(await handler.subscriptionLog.isEmpty)
    }

    @Test("A burst of subscribes and unsubscribes leaves no report chain behind", .timeLimit(.minutes(1)))
    func burstLeavesNoChain() async throws {
        let radio = VirtualRadio()
        let handler = RecordingHandler()
        let device = RecordingDevice.make(handler: handler)
        await radio.register(device)
        let identifier = device.descriptor.identifier
        let queue = DispatchQueue(label: "ReportOrderTests.burst")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let remote = await RecordingDevice.onQueue(queue) {
            backend.eventHandler = { _ in }
            return backend.retrievePeripherals(withIdentifiers: [identifier]).first as! VirtualPeripheralRemote
        }

        // Connected and discovered the way a `Central` does it, each answer landed before
        // the next request, since the remote ignores a subscribe for a characteristic it has
        // not discovered.
        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await backend.waitForPendingWork()
        await RecordingDevice.onQueue(queue) { remote.discoverServices(nil) }
        await remote.waitForPendingWork()
        await RecordingDevice.onQueue(queue) {}
        await RecordingDevice.onQueue(queue) { remote.discoverCharacteristics(nil, for: RecordingDevice.service) }
        await remote.waitForPendingWork()
        await RecordingDevice.onQueue(queue) {}

        let rounds = 1000
        await RecordingDevice.onQueue(queue) {
            for _ in 0..<rounds {
                remote.setNotifyValue(true, for: RecordingDevice.control)
                remote.setNotifyValue(false, for: RecordingDevice.control)
            }
        }
        await remote.waitForPendingWork()

        let log = await handler.subscriptionLog.map(\.isSubscribed)
        #expect(log.count == rounds * 2)
        #expect(log == Array(repeating: [true, false], count: rounds).flatMap { $0 })
        #expect(await radio.reportChainCount == 0)
        #expect(await radio.subscriberCount(device: identifier, characteristic: RecordingDevice.control) == 0)
    }
}
