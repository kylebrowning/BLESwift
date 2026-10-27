//
//  LatencyTests.swift
//  BLESwiftVirtualRadioTests
//

import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import BLESwiftVirtualRadio
import Dispatch
import Foundation
import Testing

/// Device delays and `Central`'s timeouts on a `ManualClock` (#68): every delayed path is
/// driven to its deadline, or just short of it, by advancing the clock — never by waiting.
@Suite("Latency on a manual clock")
struct LatencyTests {

    /// A handler that counts the reads that reach it, so a test can assert a delayed read
    /// is still pending — the radio has not called through — without waiting to see
    /// whether it does.
    private actor CountingHandler: VirtualDeviceHandler {
        private(set) var reads = 0

        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            reads += 1
            return .success(Data([0xD1]))
        }

        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .success(())
        }

        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
    }

    /// Every `CentralEvent` a backend delivered, read and written on the backend's queue
    /// only — and published on a stream, so a test can wait for the one it expects after an
    /// advance instead of draining and hoping the resumed task has hopped by then.
    private final class EventLog: @unchecked Sendable {
        var events: [CentralEvent] = []
        let stream: AsyncStream<CentralEvent>
        private let continuation: AsyncStream<CentralEvent>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream()
        }

        func append(_ event: CentralEvent) {
            events.append(event)
            continuation.yield(event)
        }

        /// Suspends until a `didConnect` has been delivered.
        func waitForConnect() async {
            for await event in stream {
                if case .didConnect = event { return }
            }
        }

        var connects: Int { events.filter { if case .didConnect = $0 { return true } else { return false } }.count }

        /// Every termination event, in delivery order: `"didDisconnect(<code or nil>)"` or
        /// `"didFailToConnect(<code>)"`.
        var terminations: [String] {
            events.compactMap { event in
                switch event {
                case .didDisconnect(_, let error):
                    let code: String = error.map { String(($0 as NSError).code) } ?? "nil"
                    return "didDisconnect(\(code))"
                case .didFailToConnect(_, let error):
                    let code: String = error.map { String(($0 as NSError).code) } ?? "nil"
                    return "didFailToConnect(\(code))"
                default: return nil
                }
            }
        }
        var disconnects: [NSError?] {
            events.compactMap { event in
                if case .didDisconnect(_, let error) = event { return .some(error as NSError?) } else { return nil }
            }
        }
    }

    /// A `Central` on a fresh `VirtualCentralBackend` over `radio`, its timers on `clock`,
    /// waited to `.poweredOn`.
    private static func central(
        on radio: VirtualRadio,
        clock: any Clock<Duration>,
        label: String
    ) async -> (central: Central, backend: VirtualCentralBackend, queue: DispatchQueue) {
        let queue = DispatchQueue(label: label)
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let central = Central(backend: backend, queue: queue, configuration: Configuration(clock: clock))
        await RecordingDevice.waitFor { central.state == .poweredOn }
        return (central, backend, queue)
    }

    /// `backend`'s remote for `device`, with `log` attached as the event handler.
    private static func attach(_ backend: VirtualCentralBackend, log: EventLog, device: UUID, on queue: DispatchQueue) async -> VirtualPeripheralRemote {
        await RecordingDevice.onQueue(queue) {
            backend.eventHandler = { log.append($0) }
            return backend.retrievePeripherals(withIdentifiers: [device]).first as! VirtualPeripheralRemote
        }
    }

    /// Runs every piece of radio work `backend` — and `remote`, when one is involved — has
    /// queued, then flushes their deliveries. A delayed GATT request sleeps on the remote's
    /// chain, not the backend's, so an assertion about what it left behind must wait on the
    /// remote too.
    private static func drain(_ backend: VirtualCentralBackend, remote: VirtualPeripheralRemote? = nil, on queue: DispatchQueue) async {
        await backend.waitForPendingWork()
        await remote?.waitForPendingWork()
        await RecordingDevice.onQueue(queue) {}
    }

    /// A device with `latency`, served by `handler`.
    private static func device(latency: VirtualLatency, handler: any VirtualDeviceHandler) -> VirtualDevice {
        var device = RecordingDevice.make(handler: handler)
        device.descriptor.latency = latency
        return device
    }

    // MARK: - GATT latency

    @Test("A read with 5 s latency is pending at 4.9 s and answered at 5 s", .timeLimit(.minutes(1)))
    func readLatency() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let handler = CountingHandler()
        let device = Self.device(latency: VirtualLatency(read: .seconds(5)), handler: handler)
        await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "LatencyTests.read")
        let peripheral = try await central.connect(id)

        let read = Task { try await peripheral.read(from: RecordingDevice.control) as Data }
        await clock.waitForSleepers(1)

        clock.advance(by: .milliseconds(4900))
        #expect(clock.sleeperCount == 1)
        #expect(await handler.reads == 0)

        clock.advance(by: .milliseconds(100))
        #expect(try await read.value == Data([0xD1]))
        #expect(await handler.reads == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test("A disconnect during a delayed read fails the read and the handler is never called", .timeLimit(.minutes(1)))
    func disconnectDuringDelayedRead() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let handler = CountingHandler()
        let device = Self.device(latency: VirtualLatency(read: .seconds(5)), handler: handler)
        await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, backend, queue) = await Self.central(on: radio, clock: clock, label: "LatencyTests.disconnectDuringRead")
        let peripheral = try await central.connect(id)

        let read = Task { try await peripheral.read(from: RecordingDevice.control) as Data }
        await clock.waitForSleepers(1)
        try await peripheral.disconnect()
        #expect(await RecordingDevice.isDisconnected(central, id))

        // `Central.disconnect` is what fails the read, with `explicitDisconnect`. The delay
        // then runs out on a connection the radio no longer holds, and its `invalidHandle`
        // answer goes unconsumed; that nothing reached the handler is the assertion — made
        // only once the remote's chain, where the delayed read sleeps, has run it through.
        clock.advance(by: .seconds(5))
        await #expect(throws: BLESwiftError.explicitDisconnect) { try await read.value }
        let remote = await RecordingDevice.onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [id.uuid]).first as! VirtualPeripheralRemote
        }
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await handler.reads == 0)
        #expect(clock.sleeperCount == 0)
    }

    @Test("Zero latency registers no sleeper, and setLatency affects only later operations", .timeLimit(.minutes(1)))
    func zeroLatencyAndSetLatency() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let handler = RecordingHandler()
        let device = RecordingDevice.make(handler: handler)
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "LatencyTests.zero")

        // The whole undelayed surface: connect, discovery, read, write, subscribe.
        let peripheral = try await central.connect(id)
        #expect(clock.sleeperCount == 0)
        #expect(try await peripheral.read(from: RecordingDevice.measurement) as Data == RecordingDevice.measurementValue)
        try await peripheral.write(Data([1]), to: RecordingDevice.control)
        #expect(await RecordingDevice.first(of: handler.writes) == Data([1]))
        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        await handle.notify(Data([2]), for: RecordingDevice.control, to: nil)
        #expect(try await notifications.value == Data([2]))
        #expect(clock.sleeperCount == 0)

        // A delay set now applies to the next read; clearing it while that read is still
        // delayed leaves the read its delay, and the read after it has none.
        await handle.setLatency(VirtualLatency(read: .seconds(5)))
        let delayed = Task { try await peripheral.read(from: RecordingDevice.control) as Data }
        await clock.waitForSleepers(1)
        await handle.setLatency(.none)
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(5))
        #expect(try await delayed.value == Data([0xD1]))
        #expect(try await peripheral.read(from: RecordingDevice.control) as Data == Data([0xD1]))
        #expect(clock.sleeperCount == 0)
    }

    // MARK: - Connect latency

    @Test("A 30 s connect timeout fires against a 60 s connect delay, and the attempt never lands", .timeLimit(.minutes(1)))
    func connectTimeout() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let device = Self.device(latency: VirtualLatency(connect: .seconds(60)), handler: RecordingHandler())
        await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, backend, queue) = await Self.central(on: radio, clock: clock, label: "LatencyTests.connectTimeout")

        let attempt = Task { try await central.connect(id, timeout: .seconds(30)) }
        // Two sleepers: the device's connect delay and the Central's timeout.
        await clock.waitForSleepers(2)
        clock.advance(by: .seconds(30))
        await #expect(throws: BLESwiftError.connectionTimedOut) { try await attempt.value }
        // The timeout's cancel withdrew the delayed attempt: its sleep is gone too.
        #expect(clock.sleeperCount == 0)
        #expect(await RecordingDevice.isDisconnected(central, id))

        // Past the delay the attempt would have landed at: nothing connects.
        clock.advance(by: .seconds(30))
        await Self.drain(backend, on: queue)
        #expect(await RecordingDevice.isDisconnected(central, id))
        #expect(await radio.isConnected(session: backend.sessionID, device: id.uuid) == false)
        let remoteState = await RecordingDevice.onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [id.uuid]).first?.connectionState
        }
        #expect(remoteState == .disconnected)
    }

    @Test("A cancel during a delayed connect delivers one didDisconnect(nil) at once, and the radio never sees the attempt", .timeLimit(.minutes(1)))
    func cancelDuringDelayedConnect() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let device = Self.device(latency: VirtualLatency(connect: .seconds(60)), handler: RecordingHandler())
        await radio.register(device)
        let queue = DispatchQueue(label: "LatencyTests.cancelDuringConnect")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await clock.waitForSleepers(1)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .connecting)

        await RecordingDevice.onQueue(queue) { backend.cancelPeripheralConnection(remote) }
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await RecordingDevice.onQueue(queue) { log.disconnects } == [nil])
        #expect(await RecordingDevice.onQueue(queue) { log.connects } == 0)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        #expect(await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier) == false)
        #expect(clock.sleeperCount == 0)

        // Past the delay: nothing more.
        clock.advance(by: .seconds(60))
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await RecordingDevice.onQueue(queue) { log.disconnects } == [nil])
        #expect(await RecordingDevice.onQueue(queue) { log.connects } == 0)
        #expect(await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier) == false)
    }

    @Test("Through Central: disconnect during a delayed connect fails the connect and resolves, with no clock advance", .timeLimit(.minutes(1)))
    func disconnectDuringDelayedConnectThroughCentral() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let device = Self.device(latency: VirtualLatency(connect: .seconds(60)), handler: RecordingHandler())
        await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, backend, _) = await Self.central(on: radio, clock: clock, label: "LatencyTests.disconnectDuringConnect")

        let attempt = Task { try await central.connect(id, timeout: .seconds(15)) }
        await clock.waitForSleepers(2)
        try await central.disconnect(id)
        await #expect(throws: BLESwiftError.explicitDisconnect) { try await attempt.value }
        #expect(await RecordingDevice.isDisconnected(central, id))
        #expect(await radio.isConnected(session: backend.sessionID, device: id.uuid) == false)
        #expect(clock.sleeperCount == 0)
    }

    @Test("A cancel and a connect in one queue turn during a delayed connect fail the connect as behind an undelayed cancel", .timeLimit(.minutes(1)))
    func cancelThenConnectInOneTurn() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let device = Self.device(latency: VirtualLatency(connect: .seconds(60)), handler: RecordingHandler())
        let handle = await radio.register(device)
        let queue = DispatchQueue(label: "LatencyTests.cancelThenConnect")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await clock.waitForSleepers(1)

        // Same turn: the cancel's `didDisconnect` has not hopped yet, so the connect lands on
        // a `.disconnecting` remote — and must fail the way it does behind an undelayed cancel,
        // not start a second delayed attempt the cancel's hop then settles out from under.
        await RecordingDevice.onQueue(queue) {
            backend.cancelPeripheralConnection(remote)
            backend.connect(remote, options: nil, requiresANCS: false)
        }
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await RecordingDevice.onQueue(queue) { log.terminations } == ["didDisconnect(nil)", "didFailToConnect(11)"])
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        #expect(await RecordingDevice.onQueue(queue) { remote.hasPendingConnect } == false)
        #expect(await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier) == false)
        #expect(clock.sleeperCount == 0)

        // Past every deadline there could have been: nothing more.
        clock.advance(by: .seconds(120))
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await RecordingDevice.onQueue(queue) { log.terminations } == ["didDisconnect(nil)", "didFailToConnect(11)"])
        #expect(await RecordingDevice.onQueue(queue) { log.connects } == 0)

        // With the delay cleared, a connect and cancel in one turn take the undelayed path and
        // leave the remote and the radio agreeing: connected, then cancelled, once.
        await handle.setLatency(.none)
        await RecordingDevice.onQueue(queue) {
            log.events.removeAll()
            backend.connect(remote, options: nil, requiresANCS: false)
            backend.cancelPeripheralConnection(remote)
        }
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await RecordingDevice.onQueue(queue) { log.terminations } == ["didDisconnect(nil)"])
        #expect(await RecordingDevice.onQueue(queue) { log.connects } == 1)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        #expect(await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier) == false)
        #expect(clock.sleeperCount == 0)
    }

    @Test("A connect right after a cancelled delayed connect waits out its own delay, not the first one's", .timeLimit(.minutes(1)))
    func reconnectAfterCancelledDelayedConnect() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let device = Self.device(latency: VirtualLatency(connect: .seconds(60)), handler: RecordingHandler())
        await radio.register(device)
        let queue = DispatchQueue(label: "LatencyTests.reconnectAfterCancel")
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let log = EventLog()
        let remote = await Self.attach(backend, log: log, device: device.descriptor.identifier, on: queue)

        // First attempt: deadline at 60 s. Cancelled at 30 s.
        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(30))
        await RecordingDevice.onQueue(queue) { backend.cancelPeripheralConnection(remote) }
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await RecordingDevice.onQueue(queue) { log.disconnects } == [nil])

        // Second attempt: deadline at 90 s.
        await RecordingDevice.onQueue(queue) { backend.connect(remote, options: nil, requiresANCS: false) }
        await clock.waitForSleepers(1)

        // Past the first attempt's deadline: still connecting.
        clock.advance(by: .seconds(30))
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await RecordingDevice.onQueue(queue) { log.connects } == 0)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .connecting)
        #expect(await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier) == false)

        // Past the second's: connected, once. The advance only resumes the sleeper, so the
        // outcome is awaited rather than drained for.
        clock.advance(by: .seconds(30))
        await log.waitForConnect()
        await Self.drain(backend, remote: remote, on: queue)
        #expect(await RecordingDevice.onQueue(queue) { log.connects } == 1)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .connected)
        #expect(await radio.isConnected(session: backend.sessionID, device: device.descriptor.identifier))
        #expect(clock.sleeperCount == 0)
    }

    // MARK: - Central's own timers

    @Test("A scan timeout runs on the injected clock", .timeLimit(.minutes(1)))
    func scanTimeout() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let (central, _, _) = await Self.central(on: radio, clock: clock, label: "LatencyTests.scanTimeout")

        // Nothing is registered, so the stream can only end by its timeout.
        let scan = await central.scan(services: [RecordingDevice.service], timeout: .seconds(20))
        let finished = Task { () -> Int in
            var sightings = 0
            for try await _ in scan { sightings += 1 }
            return sightings
        }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(20))
        // Finished cleanly — no error — with nothing seen.
        #expect(try await finished.value == 0)
        #expect(clock.sleeperCount == 0)
    }

    @Test("A reconnect backoff runs on the injected clock", .timeLimit(.minutes(1)))
    func reconnectBackoff() async throws {
        let clock = ManualClock()
        let radio = VirtualRadio(clock: clock)
        let device = RecordingDevice.make(handler: RecordingHandler())
        let handle = await radio.register(device)
        let id = PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil)
        let (central, _, _) = await Self.central(on: radio, clock: clock, label: "LatencyTests.reconnectBackoff")
        _ = try await central.connect(id, reconnect: .always(backoff: .seconds(45)))

        let events = await central.connectionEvents()
        await handle.disconnect()

        var iterator = events.makeAsyncIterator()
        var willReconnect: Bool?
        while let event = await iterator.next() {
            if case .disconnected(let peripheral, _, let reconnecting) = event, peripheral == id {
                willReconnect = reconnecting
                break
            }
        }
        #expect(willReconnect == true)

        // The backoff is parked on the clock; nothing reconnects until it is advanced.
        await clock.waitForSleepers(1)
        #expect(await RecordingDevice.isDisconnected(central, id))
        clock.advance(by: .seconds(45))

        var attempt: Int?
        var reconnected = false
        while let event = await iterator.next() {
            if case .reconnecting(let peripheral, let number) = event, peripheral == id { attempt = number }
            if case .connected(let peripheral) = event, peripheral == id { reconnected = true; break }
        }
        #expect(attempt == 1)
        #expect(reconnected)
        #expect(await RecordingDevice.isConnected(central, id))
    }
}
