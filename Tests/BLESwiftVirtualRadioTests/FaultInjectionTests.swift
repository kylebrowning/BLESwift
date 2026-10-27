//
//  FaultInjectionTests.swift
//  BLESwiftVirtualRadioTests
//

import BLESwift
import BLESwiftCore
import BLESwiftVirtualRadio
import Foundation
import Testing
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// Fault injection through `VirtualDeviceHandle` (#67), each kind observed through a real
/// `Central`: the error that reaches the caller carries the domain and code the fault was
/// armed with.
@Suite("Fault injection")
struct FaultInjectionTests {

    /// `CBError.peerRemovedPairingInformation`, built by hand so the suite runs where
    /// CoreBluetooth does not exist.
    private static let peerRemovedPairingInformation = NSError(domain: "CBErrorDomain", code: 14)

    // MARK: - Connection failures

    @Test("Codes match CoreBluetooth's")
    func codesMatchCoreBluetooth() {
        #if canImport(CoreBluetooth)
        #expect(CBError.Code.peerRemovedPairingInformation.rawValue == Self.peerRemovedPairingInformation.code)
        #expect(CBError.Code.peripheralDisconnected.rawValue == VirtualRadio.peripheralDisconnectedError.code)
        #expect(CBError.errorDomain == VirtualRadio.peripheralDisconnectedError.domain)
        #endif
        #expect(VirtualRadio.peripheralDisconnectedError.domain == "CBErrorDomain")
        #expect(VirtualRadio.peripheralDisconnectedError.code == 7)
    }

    @Test("failConnections(times: 1) fails the next connect with the armed error and the one after succeeds", .timeLimit(.minutes(1)))
    func failOnce() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.failOnce")

        await handle.failConnections(with: Self.peerRemovedPairingInformation)
        let failure = await RecordingDevice.failure { try await central.connect(id) }
        #expect(failure?.domain == "CBErrorDomain")
        #expect(failure?.code == 14)
        #expect(await RecordingDevice.isDisconnected(central, id))

        let peripheral = try await central.connect(id)
        #expect(try await peripheral.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)
    }

    @Test("failConnections(times: 2) fails the next two connects and the third succeeds", .timeLimit(.minutes(1)))
    func failTwice() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.failTwice")

        // `connect` counts down `.some(2)` to `.some(1)` and disarms at `.some(1)`, so both
        // steps of the countdown are crossed before the attempt that succeeds.
        await handle.failConnections(with: Self.peerRemovedPairingInformation, times: 2)
        for attempt in 1...2 {
            let failure = await RecordingDevice.failure { try await central.connect(id) }
            #expect(failure?.domain == "CBErrorDomain", "attempt \(attempt)")
            #expect(failure?.code == 14, "attempt \(attempt)")
            #expect(await RecordingDevice.isDisconnected(central, id), "attempt \(attempt)")
        }

        let peripheral = try await central.connect(id)
        #expect(try await peripheral.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)
    }

    @Test("failConnections(times: nil) fails every attempt until cleared", .timeLimit(.minutes(1)))
    func failUntilCleared() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.failUntilCleared")

        await handle.failConnections(with: Self.peerRemovedPairingInformation, times: nil)
        for _ in 0..<3 {
            let failure = await RecordingDevice.failure { try await central.connect(id) }
            #expect(failure?.domain == "CBErrorDomain")
            #expect(failure?.code == 14)
        }

        await handle.clearConnectionFailures()
        let peripheral = try await central.connect(id)
        #expect(await RecordingDevice.isConnected(central, id))
        try await peripheral.disconnect()
    }

    @Test("A connection failure is dropped with the registration", .timeLimit(.minutes(1)))
    func failureGoesWithTheRegistration() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.registration")

        await handle.failConnections(with: Self.peerRemovedPairingInformation, times: nil)
        #expect(await RecordingDevice.failure { try await central.connect(id) }?.code == 14)

        await handle.remove()
        await radio.register(device)
        let peripheral = try await central.connect(id)
        #expect(try await peripheral.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)
    }

    // MARK: - Forced disconnects

    @Test("disconnect() drops a connected Central with the error, unsubscribes it, and lets it reconnect", .timeLimit(.minutes(1)))
    func forcedDisconnect() async throws {
        let radio = VirtualRadio()
        let handler = RecordingHandler()
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, backend, queue) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.forcedDisconnect")
        let peripheral = try await central.connect(id)

        // Two subscriptions, each armed before the drop: both must be reported back.
        let controlStream = Task { () -> Error? in
            do {
                for try await _ in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {}
                return nil
            } catch {
                return error
            }
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        let measurementStream = Task { () -> Error? in
            do {
                for try await _ in peripheral.notifications(for: RecordingDevice.measurement) as AsyncThrowingStream<Data, Error> {}
                return nil
            } catch {
                return error
            }
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)

        let events = await central.connectionEvents()
        await handle.disconnect()

        var observed: (error: NSError?, willReconnect: Bool)?
        for await event in events {
            if case .disconnected(let peripheral, let error, let willReconnect) = event, peripheral == id {
                observed = (error.map { $0 as NSError }, willReconnect)
                break
            }
        }
        #expect(observed?.error?.domain == "CBErrorDomain")
        #expect(observed?.error?.code == 7)
        #expect(observed?.willReconnect == false)
        #expect((await controlStream.value as NSError?)?.code == 7)
        #expect((await measurementStream.value as NSError?)?.code == 7)

        // The handler heard both unsubscribes.
        #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        #expect(await handler.subscriptionLog.map(\.isSubscribed) == [true, true, false, false])

        // The Central and the remote agree the link is gone.
        #expect(await RecordingDevice.isDisconnected(central, id))
        let remoteState = await RecordingDevice.onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [id.uuid]).first?.connectionState
        }
        #expect(remoteState == .disconnected)

        // And a reconnect works.
        let again = try await central.connect(id)
        #expect(try await again.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)
    }

    @Test("disconnect() with a custom error reports that error", .timeLimit(.minutes(1)))
    func forcedDisconnectCustomError() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.customError")
        _ = try await central.connect(id)

        let events = await central.connectionEvents()
        await handle.disconnect(error: NSError(domain: "CBErrorDomain", code: 6))

        var observed: NSError?
        for await event in events {
            if case .disconnected(_, let error, _) = event {
                observed = error.map { $0 as NSError }
                break
            }
        }
        #expect(observed?.domain == "CBErrorDomain")
        #expect(observed?.code == 6)
    }

    @Test("disconnect(_:) targets one central and leaves the other connected", .timeLimit(.minutes(1)))
    func targetedDisconnect() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (centralA, backendA, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.targeted.A")
        let (centralB, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.targeted.B")
        _ = try await centralA.connect(id)
        let peripheralB = try await centralB.connect(id)

        let eventsA = await centralA.connectionEvents()
        await handle.disconnect([Subscriber(id: backendA.sessionID, maximumUpdateValueLength: 0)])

        var dropped = false
        for await event in eventsA {
            if case .disconnected(let peripheral, _, _) = event, peripheral == id { dropped = true; break }
        }
        #expect(dropped)
        #expect(await RecordingDevice.isDisconnected(centralA, id))

        // B's read is served from the same actor that just dropped A, so its success proves
        // the radio still holds B's connection.
        #expect(await RecordingDevice.isConnected(centralB, id))
        #expect(try await peripheralB.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)
    }

    // MARK: - ATT errors

    @Test("setATTError fails reads, writes with response, and subscribes, and leaves writes without response alone", .timeLimit(.minutes(1)))
    func attErrors() async throws {
        let radio = VirtualRadio()
        let handler = RecordingHandler()
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.attErrors")
        let peripheral = try await central.connect(id)

        await handle.setATTError(.insufficientEncryption, for: RecordingDevice.measurement)
        await handle.setATTError(.insufficientEncryption, for: RecordingDevice.control)

        // A static-value characteristic fails too: the injected answer precedes the database.
        let read = await RecordingDevice.failure { try await peripheral.read(from: RecordingDevice.measurement) as Data }
        #expect(read?.domain == "CBATTErrorDomain")
        #expect(read?.code == ATTError.insufficientEncryption.rawValue)

        let write = await RecordingDevice.failure { try await peripheral.write(Data([1]), to: RecordingDevice.control) }
        #expect(write?.domain == "CBATTErrorDomain")
        #expect(write?.code == ATTError.insufficientEncryption.rawValue)

        // No response, no error: the write reaches the handler as if nothing were armed.
        try await peripheral.write(Data([2]), to: RecordingDevice.control, type: .withoutResponse)
        #expect(await RecordingDevice.first(of: handler.writes) == Data([2]))

        // Enabling notifications fails, and the handler never hears of it.
        let subscribe = await RecordingDevice.failure { () async throws -> Data? in
            for try await value in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        #expect(subscribe?.domain == "CBATTErrorDomain")
        #expect(subscribe?.code == ATTError.insufficientEncryption.rawValue)
        #expect(await handler.subscriptionLog.isEmpty)

        // Cleared, everything is served again.
        await handle.setATTError(nil, for: RecordingDevice.measurement)
        await handle.setATTError(nil, for: RecordingDevice.control)
        #expect(try await peripheral.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)
        try await peripheral.write(Data([3]), to: RecordingDevice.control)
        #expect(await handler.written == [Data([2]), Data([3])])
        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        await handle.notify(Data([4]), for: RecordingDevice.control, to: nil)
        #expect(try await notifications.value == Data([4]))
    }

    @Test("setATTError(operations: .read) leaves writes unaffected", .timeLimit(.minutes(1)))
    func attErrorScopedToReads() async throws {
        let radio = VirtualRadio()
        let handler = RecordingHandler()
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.scoped")
        let peripheral = try await central.connect(id)

        await handle.setATTError(.insufficientAuthentication, for: RecordingDevice.control, operations: .read)

        try await peripheral.write(Data([9]), to: RecordingDevice.control)
        #expect(await handler.written == [Data([9])])

        // Dynamic, so the handler's `.success` is what the read would otherwise return.
        let read = await RecordingDevice.failure { try await peripheral.read(from: RecordingDevice.control) as Data }
        #expect(read?.domain == "CBATTErrorDomain")
        #expect(read?.code == ATTError.insufficientAuthentication.rawValue)

        // Clearing only `.read` on a characteristic that has nothing else armed clears it.
        await handle.setATTError(nil, for: RecordingDevice.control, operations: .read)
        #expect(try await peripheral.read(from: RecordingDevice.control) as Data == Data([0xD1]))
    }

    // MARK: - Stale handles

    @Test("A stale handle's fault calls do nothing", .timeLimit(.minutes(1)))
    func staleHandle() async throws {
        let radio = VirtualRadio()
        let handler = RecordingHandler()
        let device = RecordingDevice.make(handler: handler)
        let stale = await radio.register(device)
        await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "FaultInjectionTests.stale")

        await stale.failConnections(with: Self.peerRemovedPairingInformation, times: nil)
        let peripheral = try await central.connect(id)

        await stale.setATTError(.insufficientEncryption, for: RecordingDevice.measurement)
        #expect(try await peripheral.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)

        // The disconnect, had it landed, would have had the radio refuse this read with
        // `invalidHandle` (which the `Central` reports as `notConnected`); the radio serves it
        // from the same actor turn the stale call was refused on.
        await stale.disconnect()
        #expect(try await peripheral.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)
        #expect(await RecordingDevice.isConnected(central, id))
    }
}

/// A forced disconnect racing a consumer's own cancel, and a cancel queued behind an armed
/// connection failure: whichever reaches the radio first settles the remote, and the other
/// must deliver nothing on top.
@Suite("Fault injection — races with cancelPeripheralConnection")
struct FaultInjectionRaceTests {

    /// Every `CentralEvent` a backend delivered, read and written on the backend's queue only.
    private final class EventLog: @unchecked Sendable {
        var events: [CentralEvent] = []
    }

    /// `backend`'s remote for `device`, with `log` attached as the event handler.
    private static func attach(_ backend: VirtualCentralBackend, log: EventLog, device: UUID, on queue: DispatchQueue) async -> VirtualPeripheralRemote {
        await RecordingDevice.onQueue(queue) {
            backend.eventHandler = { log.events.append($0) }
            return backend.retrievePeripherals(withIdentifiers: [device]).first as! VirtualPeripheralRemote
        }
    }

    /// Runs every piece of radio work `backend` has queued, then flushes its deliveries.
    private static func drain(_ backend: VirtualCentralBackend, on queue: DispatchQueue) async {
        await backend.waitForPendingWork()
        await RecordingDevice.onQueue(queue) {}
    }

    @Test("A forced disconnect racing a cancel delivers exactly one didDisconnect", .timeLimit(.minutes(1)))
    func forcedDisconnectRacingCancel() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let queue = DispatchQueue(label: "FaultInjectionRaceTests.disconnect")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        for iteration in 0..<200 {
            await RecordingDevice.onQueue(queue) {
                log.events.removeAll()
                backend.connect(remote, options: nil, requiresANCS: false)
            }
            await Self.drain(backend, on: queue)
            #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .connected)

            queue.async { backend.cancelPeripheralConnection(remote) }
            await handle.disconnect()
            await Self.drain(backend, on: queue)

            let disconnects = await RecordingDevice.onQueue(queue) {
                log.events.filter { if case .didDisconnect = $0 { return true } else { return false } }.count
            }
            #expect(disconnects == 1, "iteration \(iteration)")
            #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        }
    }

    @Test("A forced disconnect racing a connect leaves the remote agreeing with the radio", .timeLimit(.minutes(1)))
    func forcedDisconnectRacingConnect() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let queue = DispatchQueue(label: "FaultInjectionRaceTests.connect")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        for iteration in 0..<3000 {
            await RecordingDevice.onQueue(queue) {
                log.events.removeAll()
                backend.connect(remote, options: nil, requiresANCS: false)
            }
            // Not awaited behind the connect: the point is to land on the actor anywhere
            // between the connect's radio call and its hop back to the queue.
            await handle.disconnect()
            await Self.drain(backend, on: queue)

            let radioConnected = await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier)
            let (remoteConnected, order) = await RecordingDevice.onQueue(queue) {
                let order = log.events.compactMap { event -> String? in
                    switch event {
                    case .didConnect: return "didConnect"
                    case .didDisconnect: return "didDisconnect"
                    default: return nil
                    }
                }
                return (remote.connectionState == .connected, order)
            }
            #expect(remoteConnected == radioConnected, "iteration \(iteration): remote \(remoteConnected), radio \(radioConnected), events \(order)")
            if let disconnectIndex = order.firstIndex(of: "didDisconnect") {
                #expect(!order[disconnectIndex...].contains("didConnect"), "iteration \(iteration): \(order)")
            }
        }
    }

    /// Drains `backend` until a drain produces no new events, bounded: a handler that
    /// re-connects from inside a delivery enqueues more work behind each drain.
    private static func drainUntilSettled(_ backend: VirtualCentralBackend, log: EventLog, on queue: DispatchQueue) async -> Bool {
        for _ in 0..<10 {
            let before = await RecordingDevice.onQueue(queue) { log.events.count }
            await Self.drain(backend, on: queue)
            let after = await RecordingDevice.onQueue(queue) { log.events.count }
            if after == before { return true }
        }
        return false
    }

    @Test("A forced disconnect racing a reconnect from the disconnect handler never delivers a stale didConnect", .timeLimit(.minutes(1)))
    func forcedDisconnectRacingReconnect() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let queue = DispatchQueue(label: "FaultInjectionRaceTests.reconnect")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await RecordingDevice.onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [device.descriptor.identifier]).first as! VirtualPeripheralRemote
        }
        // Mimics the provider's `CentralSession` re-sending a link client's connect: every
        // disconnect that carries an error is answered with a new connect, synchronously,
        // from inside the delivery.
        await RecordingDevice.onQueue(queue) {
            backend.eventHandler = { event in
                log.events.append(event)
                if case .didDisconnect(_, let error) = event, error != nil {
                    backend.connect(remote, options: nil, requiresANCS: false)
                }
            }
        }

        for iteration in 0..<3000 {
            await RecordingDevice.onQueue(queue) {
                log.events.removeAll()
                backend.connect(remote, options: nil, requiresANCS: false)
            }
            await handle.disconnect()
            #expect(await Self.drainUntilSettled(backend, log: log, on: queue), "iteration \(iteration) did not settle")

            let radioConnected = await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier)
            let remoteConnected = await RecordingDevice.onQueue(queue) { remote.connectionState == .connected }
            let order = await Self.terminalEvents(log, on: queue)
            #expect(remoteConnected == radioConnected, "iteration \(iteration): remote \(remoteConnected), radio \(radioConnected), events \(order)")
            for (previous, next) in zip(order, order.dropFirst()) {
                #expect(!(previous == "didConnect" && next == "didConnect"), "iteration \(iteration): \(order)")
            }

            // Back to `.disconnected` for the next iteration; the cancel's error-free
            // `didDisconnect` triggers no reconnect.
            await RecordingDevice.onQueue(queue) { backend.cancelPeripheralConnection(remote) }
            #expect(await Self.drainUntilSettled(backend, log: log, on: queue))
            #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        }
    }

    /// The terminal connection events in `log`, in order.
    private static func terminalEvents(_ log: EventLog, on queue: DispatchQueue) async -> [String] {
        await RecordingDevice.onQueue(queue) {
            log.events.compactMap { event -> String? in
                switch event {
                case .didConnect: return "didConnect"
                case .didDisconnect: return "didDisconnect"
                case .didFailToConnect(_, let error): return "didFailToConnect(\(error.map { "\($0.domain) \($0.code)" } ?? "nil"))"
                default: return nil
                }
            }
        }
    }

    @Test("A connect on a connected remote delivers one more didConnect and leaves the radio alone", .timeLimit(.minutes(1)))
    func connectWhileConnected() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        await radio.register(device)
        let queue = DispatchQueue(label: "FaultInjectionRaceTests.connectWhileConnected")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await Self.drain(backend, on: queue)
        #expect(await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier))

        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await Self.drain(backend, on: queue)
        #expect(await Self.terminalEvents(log, on: queue) == ["didConnect", "didConnect"])
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .connected)
        #expect(await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier))
    }

    @Test("A connect on a connecting remote is answered by the pending attempt alone", .timeLimit(.minutes(1)))
    func connectWhileConnecting() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        await radio.register(device)
        let queue = DispatchQueue(label: "FaultInjectionRaceTests.connectWhileConnecting")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        await RecordingDevice.onQueue(queue) {
            backend.connect(remote, options: nil, requiresANCS: false)
            backend.connect(remote, options: nil, requiresANCS: false)
        }
        await Self.drain(backend, on: queue)
        #expect(await Self.terminalEvents(log, on: queue) == ["didConnect"])
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .connected)
    }

    @Test("A connect on a disconnecting remote fails with connectWhileDisconnectingError, then the cancel completes", .timeLimit(.minutes(1)))
    func connectWhileDisconnecting() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        await radio.register(device)
        let queue = DispatchQueue(label: "FaultInjectionRaceTests.connectWhileDisconnecting")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await Self.drain(backend, on: queue)
        await RecordingDevice.onQueue(queue) {
            log.events.removeAll()
            backend.cancelPeripheralConnection(remote)
            backend.connect(remote, options: nil, requiresANCS: false)
        }
        await Self.drain(backend, on: queue)
        #expect(await Self.terminalEvents(log, on: queue) == ["didFailToConnect(BLESwiftProvider 11)", "didDisconnect"])
        #expect(VirtualCentralBackend.connectWhileDisconnectingError.code == 11)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        #expect(await !radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier))
    }

    @Test("A cancel queued behind a successful connect still delivers didConnect, then didDisconnect", .timeLimit(.minutes(1)))
    func cancelBehindConnect() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        await radio.register(device)
        let queue = DispatchQueue(label: "FaultInjectionRaceTests.cancelBehindConnect")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        // The cancel finds the remote `.connecting` and marks it `.disconnecting` — not
        // `.disconnected` — so the connect's late hop still applies, and the cancel's own
        // answer follows it: the order a `Central` whose connect timed out relies on.
        await RecordingDevice.onQueue(queue) {
            backend.connect(remote, options: nil, requiresANCS: false)
            backend.cancelPeripheralConnection(remote)
        }
        await Self.drain(backend, on: queue)

        let terminal = await RecordingDevice.onQueue(queue) {
            log.events.compactMap { event -> String? in
                switch event {
                case .didConnect: return "didConnect"
                case .didDisconnect: return "didDisconnect"
                case .didFailToConnect: return "didFailToConnect"
                default: return nil
                }
            }
        }
        #expect(terminal == ["didConnect", "didDisconnect"])
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        #expect(await !radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier))
    }

    @Test("A cancel queued behind an armed connection failure delivers didFailToConnect and nothing else", .timeLimit(.minutes(1)))
    func cancelBehindConnectionFailure() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let queue = DispatchQueue(label: "FaultInjectionRaceTests.failure")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        // Deterministic, not a race: both calls land on the queue in one turn, so the cancel
        // is always queued behind the failed connect in the chain.
        await handle.failConnections(with: NSError(domain: "CBErrorDomain", code: 14), times: 1)
        await RecordingDevice.onQueue(queue) {
            backend.connect(remote, options: nil, requiresANCS: false)
            backend.cancelPeripheralConnection(remote)
        }
        await Self.drain(backend, on: queue)

        let terminal = await RecordingDevice.onQueue(queue) {
            log.events.compactMap { event -> String? in
                switch event {
                case .didFailToConnect: return "didFailToConnect"
                case .didDisconnect: return "didDisconnect"
                default: return nil
                }
            }
        }
        #expect(terminal == ["didFailToConnect"])
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
    }
}

/// A forced disconnect's `didDisconnect` must not reach the `Central` until the handler
/// has been told about every dropped subscription — otherwise a reconnecting `Central`
/// re-subscribes while the old unsubscribes are still in flight, and the handler's log
/// shows a live subscriber leaving.
@Suite("Fault injection — forced disconnect ordering")
struct ForcedDisconnectOrderingTests {

    /// A handler whose unsubscribe does not return until the test releases it, so the test
    /// controls exactly when the radio's forced disconnect finishes reporting.
    private actor GatedHandler: VirtualDeviceHandler {
        private(set) var log: [Bool] = []
        let subscriptions: AsyncStream<Bool>
        private let subscriptionsContinuation: AsyncStream<Bool>.Continuation
        /// Yields once the unsubscribe is suspended on the gate.
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

        /// Logged on completion, not arrival: what a hosted `PeripheralHost` acts on is the
        /// unsubscribe it has finished handling, so the log records the order the handler
        /// *finished* each change in.
        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
            if !isSubscribed {
                blockedContinuation.yield(())
                for await _ in gate { break }
            }
            log.append(isSubscribed)
            subscriptionsContinuation.yield(isSubscribed)
        }
    }

    @Test("A reconnecting Central re-subscribes only after the handler heard the unsubscribe", .timeLimit(.minutes(1)))
    func unsubscribePrecedesResubscribe() async throws {
        let radio = VirtualRadio()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let handler = GatedHandler(gate: gate)
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, queue) = await RecordingDevice.central(on: radio, label: "ForcedDisconnectOrderingTests")
        let peripheral = try await central.connect(id, reconnect: .always(backoff: .zero))

        let stream = Task {
            for try await _ in peripheral.notifications(for: RecordingDevice.control, survivesReconnect: true) as AsyncThrowingStream<Data, Error> {}
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)

        let drop = Task { await handle.disconnect() }
        _ = await RecordingDevice.first(of: handler.blocked)

        // The unsubscribe is suspended. Flush the Central's queue: anything the radio sent
        // it before awaiting the handler has now been handled.
        await RecordingDevice.onQueue(queue) {}
        if await RecordingDevice.isConnected(central, id) {
            release.yield(())
            #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
            #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        } else {
            // The Central already heard the disconnect while the unsubscribe was still in
            // flight — the misordering under test. Let it finish re-subscribing before the
            // unsubscribe returns, so the ordering lands in the log instead of being hidden
            // by how quickly the release wins the race.
            #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
            release.yield(())
            #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        }
        await drop.value
        #expect(await handler.log == [true, false, true])

        // Teardown unsubscribes once more; finish the gate so that one is never held.
        release.finish()
        stream.cancel()
        try await central.disconnect(id)
    }

    @Test("A reconnecting Central re-subscribes to a re-registered device only after the handler heard the unsubscribe (#73)", .timeLimit(.minutes(1)))
    func unsubscribePrecedesResubscribeAcrossReregistration() async throws {
        let radio = VirtualRadio()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let handler = GatedHandler(gate: gate)
        let device = RecordingDevice.make(handler: handler)
        await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, backend, queue) = await RecordingDevice.central(on: radio, label: "ForcedDisconnectOrderingTests.reregister")
        let peripheral = try await central.connect(id, reconnect: .always(backoff: .zero))

        let stream = Task {
            for try await _ in peripheral.notifications(for: RecordingDevice.control, survivesReconnect: true) as AsyncThrowingStream<Data, Error> {}
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)

        // The same device — same identifier, same handler instance — registered again while
        // the Central is connected and subscribed. The identifier never leaves the radio, so
        // the Central's reconnect lands on the new registration at once.
        let reregister = Task { await radio.register(device) }
        _ = await RecordingDevice.first(of: handler.blocked)

        await RecordingDevice.onQueue(queue) {}
        if await RecordingDevice.isConnected(central, id) {
            release.yield(())
            #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
            #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        } else {
            #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
            release.yield(())
            #expect(await RecordingDevice.first(of: handler.subscriptions) == false)
        }
        await reregister.value
        #expect(await handler.log == [true, false, true])
        // The radio agrees with what the handler last heard: one live subscriber.
        #expect(await radio.subscriberCount(device: id.uuid, characteristic: RecordingDevice.control) == 1)
        #expect(await radio.isSubscribed(session: backend.sessionID, characteristic: RecordingDevice.control))

        release.finish()
        stream.cancel()
        try await central.disconnect(id)
    }
}
