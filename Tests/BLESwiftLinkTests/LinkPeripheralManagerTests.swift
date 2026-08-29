//
//  LinkPeripheralManagerTests.swift
//  BLESwiftLinkTests
//

// Sockets in a CI simulator are unreliable, exactly as `LinkCentralTests` describes, so this
// suite is compiled out there; the simulator-side path is covered by the two-simulator E2E.
#if !targetEnvironment(simulator)
import BLESwiftCore
import BLESwiftLink
import BLESwiftSimulatorLink
import Dispatch
import Foundation
import Synchronization
import Testing

/// A scripted provider for the peripheral role: accepts the handshake, records the requests a
/// ``LinkPeripheralManager`` sends, and lets a test inject events a real provider would never
/// send — a stale acknowledgement, say.
///
/// The peripheral-role counterpart to `ScriptedProvider`.
final class ScriptedHostProvider: Sendable {
    let listener: LinkListener
    let requests = Mutex<[HostRequest]>([])
    private let connection = Mutex<LinkConnection?>(nil)

    init() throws {
        listener = try LinkListener(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: 0),
            codec: .json,
            queue: DispatchQueue(label: "scripted.host")
        )
        listener.onConnection = { [weak self] link in
            guard let self else { return }
            self.connection.withLock { $0 = link }
            link.onMessage = { [weak self] message in
                guard let self else { return }
                switch message {
                case .clientHello:
                    link.send(.serverHello(ServerHello(
                        protocolVersion: LinkProtocol.version,
                        accepted: true,
                        reason: nil,
                        providerName: "scripted-host"
                    )))
                    link.send(.hostEvent(.didUpdateState(WireCentralState(.poweredOn))))
                case .hostRequest(let request):
                    self.requests.withLock { $0.append(request) }
                default:
                    break
                }
            }
        }
    }

    func start() async throws { try await listener.start() }
    var endpoint: LinkEndpoint { LinkEndpoint(host: "127.0.0.1", port: listener.port) }
    func emit(_ event: HostWireEvent) { connection.withLock { $0 }?.send(.hostEvent(event)) }
    func dropClient() { connection.withLock { $0 }?.cancel() }

    func stop() {
        connection.withLock { $0 }?.cancel()
        listener.cancel()
    }
}

@Suite("LinkPeripheralManager")
struct LinkPeripheralManagerTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)

    /// Hops onto `queue` to run `body` and returns its result — the door for off-queue test
    /// code to touch queue-confined state.
    private func onQueue<T: Sendable>(_ queue: DispatchSerialQueue, _ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// The sequences of every `updateValue` the provider has received, in order.
    private static func updateSequences(_ provider: ScriptedHostProvider) -> [UInt64] {
        provider.requests.withLock { requests in
            requests.compactMap {
                guard case .updateValue(let sequence, _, _, _) = $0 else { return nil }
                return sequence
            }
        }
    }

    @Test("A read request carrying a negative offset drops the session instead of trapping")
    func negativeReadOffsetDropsTheSession() async throws {
        let provider = try ScriptedHostProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "linkperipheralmanager.badoffset")
        let link = LinkPeripheralManager(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "badoffset",
            codec: .json,
            retryInterval: .milliseconds(50)
        )
        defer { provider.stop(); link.shutdown() }

        let states = Mutex<[CentralState]>([])
        let reads = Mutex<Int>(0)
        await onQueue(queue) {
            link.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .didReceiveRead: reads.withLock { $0 += 1 }
                default: break
                }
            }
        }
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .poweredOn } }

        // An offset a handler would slice its value at — `value[offset...]` — and trap on.
        // It is refused at the boundary instead: the session goes, and the client redials.
        provider.emit(.didReceiveRead(WireReadRequest(
            token: UUID(),
            central: WireSubscriber(id: UUID(), maximumUpdateValueLength: 20),
            characteristic: WireCharacteristicRef(Self.measurement),
            offset: -1
        )))

        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .unsupported } }
        await waitFor(timeout: .seconds(10)) { states.withLock { $0.last == .poweredOn } }
        #expect(states.withLock { $0.last } == .poweredOn)
        // The malformed request never reached the host.
        #expect(reads.withLock { $0 } == 0)
    }

    @Test("A stop right behind a start leaves the manager reporting not advertising")
    func stopBehindStartDoesNotLatchAdvertising() async throws {
        let provider = try ScriptedHostProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "linkperipheralmanager.advertising")
        let link = LinkPeripheralManager(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "advertising",
            codec: .json,
            retryInterval: .milliseconds(50)
        )
        defer { provider.stop(); link.shutdown() }

        let states = Mutex<[CentralState]>([])
        let starts = Mutex<Int>(0)
        await onQueue(queue) {
            link.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .didStartAdvertising: starts.withLock { $0 += 1 }
                default: break
                }
            }
        }
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .poweredOn } }

        // Both calls on one queue turn — the interleaving a provider answers by applying the
        // start and then the stop, with the start's completion already on its way back.
        await onQueue(queue) {
            link.startAdvertising(PeripheralAdvertisement(localName: "Latched", serviceUUIDs: [Self.service]))
            link.stopAdvertising()
        }
        await waitFor(timeout: .seconds(5)) {
            provider.requests.withLock { requests in
                requests.contains { if case .stopAdvertising = $0 { return true }; return false }
            }
        }

        // The completion of the start the stop cancelled. It is still reported to the host —
        // a `startAdvertising` awaiting it must not hang — but it may not claim the radio.
        provider.emit(.didStartAdvertising(error: nil))
        await waitFor(timeout: .seconds(5)) { starts.withLock { $0 } == 1 }
        #expect(starts.withLock { $0 } == 1)
        #expect(await onQueue(queue) { link.isAdvertising } == false)

        // A start with nothing behind it still claims it.
        await onQueue(queue) {
            link.startAdvertising(PeripheralAdvertisement(localName: "Latched", serviceUUIDs: [Self.service]))
        }
        provider.emit(.didStartAdvertising(error: nil))
        await waitFor(timeout: .seconds(5)) { starts.withLock { $0 } == 2 }
        #expect(await onQueue(queue) { link.isAdvertising })
    }

    @Test("A stale update acknowledgement cannot open the next session's window")
    func staleUpdateAcknowledgementIsIgnored() async throws {
        let provider = try ScriptedHostProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "linkperipheralmanager.staleack")
        let link = LinkPeripheralManager(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "staleack",
            codec: .json,
            retryInterval: .milliseconds(50)
        )
        defer { provider.stop(); link.shutdown() }

        let states = Mutex<[CentralState]>([])
        let readyCount = Mutex<Int>(0)
        let advertising = Mutex(false)
        await onQueue(queue) {
            link.eventHandler = { event in
                switch event {
                case .didUpdateState(let state): states.withLock { $0.append(state) }
                case .readyToUpdateSubscribers: readyCount.withLock { $0 += 1 }
                case .didStartAdvertising: advertising.withLock { $0 = true }
                default: break
                }
            }
        }
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .poweredOn } }
        #expect(readyCount.withLock { $0 } == 0)

        // ---- Fill the window on the first session ----
        let window = LinkFlowControl.updateValueWindow
        let filled = await onQueue(queue) {
            (0..<window).map { _ in link.updateValue(Data([0, 72]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(filled.allSatisfy { $0 })
        #expect(await onQueue(queue) { link.updateValue(Data([0, 72]), for: Self.measurement, onSubscribed: nil) } == false)
        await waitFor(timeout: .seconds(5)) { Self.updateSequences(provider).count == window }
        let stale = Self.updateSequences(provider)
        #expect(stale.count == window)

        // ---- The session resets. Its outstanding pushes go with it — but the provider's
        // acknowledgements for them may already be on the wire. ----
        provider.dropClient()
        await waitFor(timeout: .seconds(5)) { states.withLock { $0.last == .unsupported } }
        await waitFor(timeout: .seconds(10)) { states.withLock { $0.last == .poweredOn } }
        // The reconnect releases the host that was blocked at the drop, exactly once.
        await waitFor(timeout: .seconds(5)) { readyCount.withLock { $0 } == 1 }
        #expect(readyCount.withLock { $0 } == 1)

        // ---- The second session fills the window again, with fresh sequences ----
        let refilled = await onQueue(queue) {
            (0..<window).map { _ in link.updateValue(Data([0, 73]), for: Self.measurement, onSubscribed: nil) }
        }
        #expect(refilled.allSatisfy { $0 })
        #expect(await onQueue(queue) { link.updateValue(Data([0, 73]), for: Self.measurement, onSubscribed: nil) } == false)
        await waitFor(timeout: .seconds(5)) { Self.updateSequences(provider).count == 2 * window }
        let live = Self.updateSequences(provider).filter { !stale.contains($0) }
        #expect(live.count == window)

        // ---- Every acknowledgement from the first session now lands. None of those sequences
        // is outstanding any more, so none of them may credit this session's window. ----
        for sequence in stale {
            provider.emit(.updateValueDelivered(sequence: sequence))
        }
        // And one for a sequence that was never sent at all, for good measure.
        provider.emit(.updateValueDelivered(sequence: .max))

        // A barrier: the link is ordered, so an event behind those acknowledgements cannot be
        // observed until every one of them has been handled. The window must still be shut.
        provider.emit(.didStartAdvertising(error: nil))
        await waitFor(timeout: .seconds(5)) { advertising.withLock { $0 } }
        #expect(readyCount.withLock { $0 } == 1)
        #expect(await onQueue(queue) { link.updateValue(Data([0, 74]), for: Self.measurement, onSubscribed: nil) } == false)

        // ---- An acknowledgement this session did earn opens it, and nothing else does ----
        provider.emit(.updateValueDelivered(sequence: try #require(live.first)))
        await waitFor(timeout: .seconds(5)) { readyCount.withLock { $0 } == 2 }
        #expect(readyCount.withLock { $0 } == 2)
        #expect(await onQueue(queue) { link.updateValue(Data([0, 75]), for: Self.measurement, onSubscribed: nil) })
    }
}
#endif
