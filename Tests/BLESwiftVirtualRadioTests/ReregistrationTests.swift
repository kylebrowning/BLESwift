//
//  ReregistrationTests.swift
//  BLESwiftVirtualRadioTests
//

import BLESwift
import BLESwiftCore
import BLESwiftVirtualRadio
import Foundation
import Testing

/// Registering an identifier that is still registered — what a link client redialing under
/// a stable `hostIdentifier` produces — retires the old registration as a removal would
/// (#73): every connected central hears `didDisconnect` with `deviceRemovedError`, the old
/// handler hears each unsubscribe, the new handler hears nothing, and the identifier never
/// leaves the radio.
@Suite("Re-registration")
struct ReregistrationTests {

    @Test("Through a Central: a connected, subscribed device re-registered drops the central with code 2 and tells only the old handler", .timeLimit(.minutes(1)))
    func throughCentral() async throws {
        let radio = VirtualRadio()
        let oldHandler = RecordingHandler()
        let identifier = UUID()
        let device = RecordingDevice.make(identifier: identifier, handler: oldHandler)
        await radio.register(device)
        let id = PeripheralIdentifier(uuid: identifier, name: nil)
        let (central, backend, queue) = await RecordingDevice.central(on: radio, label: "ReregistrationTests.central")
        let peripheral = try await central.connect(id)

        let stream = Task { () -> Error? in
            do {
                for try await _ in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {}
                return nil
            } catch {
                return error
            }
        }
        #expect(await RecordingDevice.first(of: oldHandler.subscriptions) == true)
        #expect(await radio.isSubscribed(session: backend.sessionID, characteristic: RecordingDevice.control))

        // The same identifier, registered again with a different handler.
        let newHandler = RecordingHandler()
        let events = await central.connectionEvents()
        await radio.register(RecordingDevice.make(identifier: identifier, handler: newHandler))

        var observed: (error: NSError?, willReconnect: Bool)?
        for await event in events {
            if case .disconnected(let peripheral, let error, let willReconnect) = event, peripheral == id {
                observed = (error.map { $0 as NSError }, willReconnect)
                break
            }
        }
        #expect(observed?.error?.domain == "BLESwiftProvider")
        #expect(observed?.error?.code == VirtualRadio.deviceRemovedError.code)
        #expect(observed?.willReconnect == false)
        #expect((await stream.value as NSError?)?.code == VirtualRadio.deviceRemovedError.code)

        // The old handler heard its subscriber leave; the new one, which never saw it
        // arrive, heard nothing.
        #expect(await RecordingDevice.first(of: oldHandler.subscriptions) == false)
        #expect(await oldHandler.subscriptionLog.map(\.isSubscribed) == [true, false])
        #expect(await newHandler.subscriptionLog.isEmpty)
        #expect(await radio.subscriberCount(device: identifier, characteristic: RecordingDevice.control) == 0)
        #expect(await !radio.isConnected(session: backend.sessionID, device: identifier))

        // The identifier never left the radio, and the Central and remote agree the link is gone.
        #expect(radio.knownDeviceIDs.withLock { $0.contains(identifier) })
        #expect(await RecordingDevice.isDisconnected(central, id))
        let remoteState = await RecordingDevice.onQueue(queue) {
            backend.retrievePeripherals(withIdentifiers: [identifier]).first?.connectionState
        }
        #expect(remoteState == .disconnected)

        // A connect reaches the new registration, and its handler answers the read.
        let again = try await central.connect(id)
        #expect(try await again.read(from: RecordingDevice.control) as Data == Data([0xD1]))
        #expect(await radio.isConnected(session: backend.sessionID, device: identifier))
        #expect(await newHandler.subscriptionLog.isEmpty)
    }

    /// Every `CentralEvent` a backend delivered, read and written on the backend's queue only.
    private final class EventLog: @unchecked Sendable {
        var events: [CentralEvent] = []
    }

    /// Runs every piece of radio work `remote` has queued, then flushes its deliveries.
    private static func drain(_ remote: VirtualPeripheralRemote, on queue: DispatchQueue) async {
        await remote.waitForPendingWork()
        await RecordingDevice.onQueue(queue) {}
    }

    @Test("Through the backend: a re-registration delivers exactly one didDisconnect with code 2, settles the remote, and lets it reconnect", .timeLimit(.minutes(1)))
    func throughBackend() async throws {
        let radio = VirtualRadio()
        let oldHandler = RecordingHandler()
        let identifier = UUID()
        await radio.register(RecordingDevice.make(identifier: identifier, handler: oldHandler))
        let queue = DispatchQueue(label: "ReregistrationTests.backend")
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

        // Subscribed through the remote, the way a `Central` does it: discovery first, each
        // step's answer landed before the next is asked for — the remote ignores a
        // characteristic discovery for a service it has not discovered, and a subscribe for
        // a characteristic it has not.
        await RecordingDevice.onQueue(queue) { remote.discoverServices(nil) }
        await Self.drain(remote, on: queue)
        await RecordingDevice.onQueue(queue) { remote.discoverCharacteristics(nil, for: RecordingDevice.service) }
        await Self.drain(remote, on: queue)
        await RecordingDevice.onQueue(queue) { remote.setNotifyValue(true, for: RecordingDevice.control) }
        #expect(await RecordingDevice.first(of: oldHandler.subscriptions) == true)

        let newHandler = RecordingHandler()
        await RecordingDevice.onQueue(queue) { log.events.removeAll() }
        await radio.register(RecordingDevice.make(identifier: identifier, handler: newHandler))
        await backend.waitForPendingWork()
        await RecordingDevice.onQueue(queue) {}

        let disconnects = await RecordingDevice.onQueue(queue) {
            log.events.compactMap { event -> NSError?? in
                if case .didDisconnect(let peripheral, let error) = event, peripheral.uuid == identifier { return .some(error) }
                return nil
            }
        }
        #expect(disconnects.count == 1)
        #expect(disconnects.first??.domain == "BLESwiftProvider")
        #expect(disconnects.first??.code == VirtualRadio.deviceRemovedError.code)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .disconnected)
        #expect(await !radio.isConnected(session: backend.sessionID, device: identifier))

        #expect(await RecordingDevice.first(of: oldHandler.subscriptions) == false)
        #expect(await oldHandler.subscriptionLog.map(\.isSubscribed) == [true, false])
        #expect(await newHandler.subscriptionLog.isEmpty)
        #expect(await radio.subscriberCount(device: identifier, characteristic: RecordingDevice.control) == 0)
        #expect(radio.knownDeviceIDs.withLock { $0.contains(identifier) })

        // The same remote connects to the new registration.
        await RecordingDevice.onQueue(queue) {
            log.events.removeAll()
            backend.connect(remote, options: nil, requiresANCS: false)
        }
        await backend.waitForPendingWork()
        await RecordingDevice.onQueue(queue) {}
        let connects = await RecordingDevice.onQueue(queue) {
            log.events.filter { if case .didConnect = $0 { return true } else { return false } }.count
        }
        #expect(connects == 1)
        #expect(await RecordingDevice.onQueue(queue) { remote.connectionState } == .connected)
        #expect(await radio.isConnected(session: backend.sessionID, device: identifier))
        #expect(await newHandler.subscriptionLog.isEmpty)
    }

    @Test("Re-registering an identifier nothing is connected to disconnects nobody and tells nobody", .timeLimit(.minutes(1)))
    func idleReregistration() async throws {
        let radio = VirtualRadio()
        let oldHandler = RecordingHandler()
        let newHandler = RecordingHandler()
        let identifier = UUID()
        let first = await radio.register(RecordingDevice.make(identifier: identifier, handler: oldHandler))
        let second = await radio.register(RecordingDevice.make(identifier: identifier, handler: newHandler))
        #expect(first !== second)
        #expect(await oldHandler.subscriptionLog.isEmpty)
        #expect(await newHandler.subscriptionLog.isEmpty)
        #expect(radio.knownDeviceIDs.withLock { $0.contains(identifier) })

        let id = PeripheralIdentifier(uuid: identifier, name: nil)
        let (central, _, _) = await RecordingDevice.central(on: radio, label: "ReregistrationTests.idle")
        let peripheral = try await central.connect(id)
        #expect(try await peripheral.read(from: RecordingDevice.control) as Data == Data([0xD1]))
    }
}
