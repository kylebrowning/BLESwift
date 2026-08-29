//
//  VirtualCentralBackend.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Dispatch
import Foundation
import Synchronization

/// A `CentralManaging` served by a ``VirtualRadio`` instead of CoreBluetooth
/// — hand one to `Central(backend:queue:)` and the resulting `Central` talks to the radio's
/// virtual devices with no hardware involved.
///
/// Any number of backends may share one radio; each registers under its own session
/// identifier, so scans, connections, and subscriptions never leak between them.
///
/// **Concurrency — queue-confined, not lock-protected.** Every stored property is
/// `nonisolated(unsafe)` and touched only on ``queue``, which every `CentralManaging`
/// method asserts at entry. Work reaches the radio actor through one serial chain of
/// `Task`s rooted in this backend's attachment (see `enqueue(_:)`) and every event is
/// delivered back with `queue.async`, never inline — the delivery contract
/// `CentralManaging` requires.
public final class VirtualCentralBackend: CentralManaging, Sendable {

    /// The queue every method and event delivery is confined to.
    public let queue: DispatchSerialQueue

    /// This backend's identity to the radio. Also the `Subscriber` id that
    /// device handlers see for traffic originating here.
    public let sessionID = UUID()

    private let radio: VirtualRadio

    nonisolated(unsafe) private var _eventHandler: ((CentralEvent) -> Void)?

    /// The remote vended for each identifier this backend has been asked for, so the same
    /// instance is returned every time — the object the radio's events are routed to.
    ///
    /// **Bounded, least recently vended first.** The same cap, for the same reason, as the
    /// sighting history above and the provider session's own remote table: a long-lived
    /// backend asked for identifier after identifier would otherwise grow one remote per
    /// identifier ever named, for the life of the process. Only a remote that is
    /// `.disconnected` — nothing connecting, connected, or disconnecting — is ever dropped;
    /// anything else is still carrying a live connection whose events must reach the very
    /// instance the caller is holding, so it is kept however old it is. Forgetting one costs
    /// a caller nothing: retrieving that identifier again mints a fresh remote, and
    /// ``connect(_:options:requiresANCS:)`` re-files a remote the cap evicted rather than
    /// ignoring it.
    nonisolated(unsafe) private var _remotes: [UUID: VirtualPeripheralRemote] = [:]

    /// ``_remotes``' keys in least-recently-vended order, which is what the cap evicts from.
    nonisolated(unsafe) private var _remoteOrder: [UUID] = []

    /// How many remotes ``_remotes`` keeps.
    private let maximumRemotes: Int

    /// The remote table's default size, used by the public initializer. Tests override it to
    /// force eviction without naming a thousand identifiers.
    package static let defaultMaximumRemotes = 1024

    nonisolated(unsafe) private var _announcedState = false

    /// Identifiers this backend has reported a sighting for. A device removed from the radio
    /// after being seen stays retrievable exactly as CoreBluetooth keeps vending a
    /// `CBPeripheral` for a peer it has scanned; the connect attempt is what then fails.
    ///
    /// **Bounded, oldest first.** Of the two ways to keep a long-lived session's sighting
    /// history from growing without limit — pruning identifiers the radio no longer knows, or
    /// capping the history — this takes the cap, because pruning is the one that changes
    /// behavior: a removed device would stop being retrievable, which is exactly the
    /// CoreBluetooth-shaped property the set exists to provide. The cap only forgets sightings
    /// ``maximumDiscovered`` devices old, which no client can still be holding an identifier
    /// from that it has not also connected to.
    nonisolated(unsafe) private var _discovered: Set<UUID> = []

    /// The order ``_discovered`` was filled in, so the cap can drop the oldest sighting.
    nonisolated(unsafe) private var _discoveryOrder: [UUID] = []

    /// How many sightings ``_discovered`` remembers.
    private let maximumDiscovered: Int

    /// The sighting history's default size, used by the public initializer. Tests override it
    /// to force eviction without reporting a thousand sightings.
    package static let defaultMaximumDiscovered = 1024

    /// The serial chain of radio work, rooted in this backend's attachment. Swift guarantees
    /// no ordering between independent `Task`s, so a `scan` and the `stopScan` right behind it
    /// could otherwise reach the actor in either order — leaving a duplicate-reporting
    /// repeater running for a scan that has already been stopped.
    nonisolated(unsafe) private var _work: Task<Void, Never>!

    /// Backs ``bluetoothAuthorization``; a `static var` isn't scoped to any one backend's
    /// queue, so it is `Mutex`-protected rather than queue-confined.
    private static let authorizationBox = Mutex<BluetoothAuthorization>(.allowedAlways)

    /// The authorization status this backend reports. Defaults to `.allowedAlways` — a
    /// virtual radio is never gated by the system's Bluetooth permission.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        get { authorizationBox.withLock { $0 } }
        set { authorizationBox.withLock { $0 = newValue } }
    }

    /// Creates a backend served by `radio` and confined to `queue`.
    ///
    /// ``radioState`` is `CentralState.poweredOn` from construction; the
    /// matching `didUpdateState` is delivered once, when a non-`nil` ``eventHandler`` is
    /// first attached — mirroring CoreBluetooth, which reports its state only through the
    /// delegate.
    ///
    /// - Parameters:
    ///   - radio: The radio hosting the virtual devices to serve.
    ///   - queue: The queue every method and event delivery is confined to — the same
    ///     queue the owning `Central` is constructed with.
    public convenience init(radio: VirtualRadio, queue: DispatchSerialQueue) {
        self.init(
            radio: radio,
            queue: queue,
            maximumDiscovered: Self.defaultMaximumDiscovered,
            maximumRemotes: Self.defaultMaximumRemotes
        )
    }

    /// Creates a backend whose sighting history holds at most `maximumDiscovered`
    /// identifiers and whose remote table holds at most `maximumRemotes` — the designated
    /// initializer, for tests that cannot report ``defaultMaximumDiscovered`` sightings or
    /// name ``defaultMaximumRemotes`` identifiers to force an eviction.
    ///
    /// - Parameters:
    ///   - radio: The radio hosting the virtual devices to serve.
    ///   - queue: The queue every method and event delivery is confined to.
    ///   - maximumDiscovered: How many sightings to remember.
    ///   - maximumRemotes: How many peripheral remotes to keep.
    package init(
        radio: VirtualRadio,
        queue: DispatchSerialQueue,
        maximumDiscovered: Int,
        maximumRemotes: Int = VirtualCentralBackend.defaultMaximumRemotes
    ) {
        self.radio = radio
        self.queue = queue
        self.maximumDiscovered = maximumDiscovered
        self.maximumRemotes = maximumRemotes
        let session = sessionID
        // Weak, so the radio's registration never keeps this backend alive; the strong
        // reference the hop takes lasts only as long as the delivery itself.
        let sink: @Sendable (CentralEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.queue.async { self.deliver(event) }
        }
        // The root of the chain: nothing this backend asks of the radio can outrun the
        // attachment that gives the radio somewhere to answer.
        _work = Task { [radio] in
            await radio.attach(session: session, centralSink: sink)
        }
    }

    /// Detaches from the radio, immediately and then again behind whatever work is still
    /// queued.
    ///
    /// The first detach is unconditional and comes *before* the chain is awaited: it is what
    /// cancels a duplicate-reporting scan repeater, and a chain still waiting on a radio
    /// answer that never comes would otherwise leave that repeater running for the life of
    /// the process. The second detach covers the opposite order — a chain whose `attach` had
    /// not run yet would re-register the session behind the first detach — and is free when
    /// the session is already gone, since `detach` is idempotent.
    ///
    /// Reading `_work` off-queue is safe here: `deinit` runs only once every reference is
    /// gone, and every queued delivery holds one.
    deinit {
        let radio = self.radio
        let session = sessionID
        let work = _work
        Task {
            await radio.detach(session: session)
            await work?.value
            await radio.detach(session: session)
        }
    }

    /// Appends `body` to the serial chain of radio work, so it runs after the attachment and
    /// after every operation queued before it. Must be called on ``queue``.
    private func enqueue(_ body: @escaping @Sendable () async -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = _work
        _work = Task {
            await previous?.value
            await body()
        }
    }

    /// Delivers `event` to ``eventHandler``. Must be called on ``queue``.
    ///
    /// A disconnect also settles the affected remote's ``BLESwiftCore/PeripheralRemote/connectionState``
    /// first, so it never reports `.connected` to a handler reacting to its own disconnect —
    /// this is the path a radio-initiated disconnect (a removed device) arrives on.
    private func deliver(_ event: CentralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        if case .didDisconnect(let peripheral, _) = event {
            _remotes[peripheral.uuid]?.setConnectionState(.disconnected)
        }
        if case .didDiscover(let peripheral, _, _) = event {
            remember(peripheral.uuid)
        }
        _eventHandler?(event)
    }

    /// Records a sighting of `identifier`, forgetting the oldest one once the history is
    /// full. Must be called on ``queue``.
    private func remember(_ identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discovered.insert(identifier).inserted else { return }
        _discoveryOrder.append(identifier)
        guard _discoveryOrder.count > maximumDiscovered else { return }
        _discovered.remove(_discoveryOrder.removeFirst())
    }

    /// The remote for `identifier`, created on first use and reused until the cap forgets
    /// it. Must be called on ``queue``.
    private func remote(for identifier: UUID) -> VirtualPeripheralRemote {
        dispatchPrecondition(condition: .onQueue(queue))
        if let existing = _remotes[identifier] {
            touch(identifier)
            return existing
        }
        let created = VirtualPeripheralRemote(
            identifier: identifier,
            radio: radio,
            session: sessionID,
            queue: queue,
            name: nil
        )
        file(created)
        return created
    }

    /// Files `remote` under its identifier, evicting a stale one first so the insert this is
    /// about to make cannot itself be what the cap drops — a remote nothing has connected yet
    /// is disconnected, which is exactly what the cap considers droppable. Must be called on
    /// ``queue``.
    private func file(_ remote: VirtualPeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        evictStaleRemotes(reserving: _remotes[remote.identifier] == nil ? 1 : 0)
        _remotes[remote.identifier] = remote
        touch(remote.identifier)
    }

    /// Moves `identifier` to the most-recently-vended end of ``_remoteOrder``. Must be called
    /// on ``queue``.
    private func touch(_ identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let index = _remoteOrder.firstIndex(of: identifier) {
            _remoteOrder.remove(at: index)
        }
        _remoteOrder.append(identifier)
    }

    /// Drops the least recently vended disconnected remotes until the table is back within
    /// ``maximumRemotes``, detaching each one's event handler on the way out so nothing that
    /// still holds it can deliver into a backend that has forgotten it. A remote in any other
    /// connection state is left alone however old it is. Must be called on ``queue``.
    ///
    /// - Parameter reserving: How many slots the caller is about to fill, kept free on top of
    ///   the entries already in the table.
    private func evictStaleRemotes(reserving: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        let limit = maximumRemotes - reserving
        guard _remotes.count > limit else { return }
        var overflow = _remotes.count - limit
        var kept: [UUID] = []
        kept.reserveCapacity(_remoteOrder.count)
        for identifier in _remoteOrder {
            guard let candidate = _remotes[identifier] else { continue }
            guard overflow > 0, candidate.connectionState == .disconnected else {
                kept.append(identifier)
                continue
            }
            candidate.eventHandler = nil
            _remotes.removeValue(forKey: identifier)
            overflow -= 1
        }
        _remoteOrder = kept
    }

    // MARK: - CentralManaging

    /// Receives every `CentralEvent` this backend produces, on ``queue``.
    /// The first non-`nil` attachment also triggers the one-shot
    /// `didUpdateState(.poweredOn)`.
    public var eventHandler: ((CentralEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
            guard newValue != nil, !_announcedState else { return }
            _announcedState = true
            queue.async { [self] in deliver(.didUpdateState(.poweredOn)) }
        }
    }

    /// Always `CentralState.poweredOn` — a virtual radio is never off.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return .poweredOn
    }

    /// Starts a radio scan. Every advertising device matching `services` is reported once
    /// immediately; with `options.allowDuplicates`, matching devices are re-reported once
    /// per second until ``stopScan()``.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [radio, sessionID] in
            await radio.startScan(session: sessionID, services: services, allowDuplicates: options.allowDuplicates)
        }
    }

    /// Stops the active scan, if any.
    public func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue { [radio, sessionID] in
            await radio.stopScan(session: sessionID)
        }
    }

    /// Connects to a virtual device. Succeeds for any registered device, advertising or
    /// not; an unregistered identifier fails with ``VirtualRadio/unknownDeviceError``.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        // **A remote the cap evicted is re-filed rather than refused.** The table is bounded,
        // so a caller holding a remote retrieved long enough ago can find its entry gone by
        // the time it connects, and dropping the request would leave that caller waiting for
        // a `didConnect` nothing was ever going to send. The test is on the remote's *owner*,
        // which no eviction changes; a remote belonging to another backend, or one this
        // backend has since replaced for the same identifier, is still ignored.
        guard let remote = peripheral as? VirtualPeripheralRemote, remote.isOwned(by: sessionID) else { return }
        if let filed = _remotes[remote.identifier] {
            guard filed === remote else { return }
        } else {
            file(remote)
        }
        remote.setConnectionState(.connecting)
        let device = remote.identifier
        enqueue { [radio, sessionID, queue] in
            // Connect-and-name in one actor hop: a second hop for the name could observe a
            // `remove()` that landed in between and rename a live connection to `nil`.
            let (failure, name) = await radio.connect(session: sessionID, device: device) { event in
                queue.async { remote.deliver(event) }
            }
            queue.async { [self] in
                if let failure {
                    remote.setConnectionState(.disconnected)
                    deliver(.didFailToConnect(remote.peripheralIdentifier, error: failure))
                } else {
                    remote.updateName(name)
                    remote.setConnectionState(.connected)
                    deliver(.didConnect(remote.peripheralIdentifier))
                }
            }
        }
    }

    /// Cancels a connection, delivering `didDisconnect` with no error — CoreBluetooth
    /// reports an explicit cancellation as an error-free disconnect.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let remote = peripheral as? VirtualPeripheralRemote, remote === _remotes[remote.identifier] else { return }
        remote.setConnectionState(.disconnecting)
        let device = remote.identifier
        enqueue { [radio, sessionID, queue] in
            await radio.disconnect(session: sessionID, device: device)
            queue.async { [self] in
                remote.setConnectionState(.disconnected)
                deliver(.didDisconnect(remote.peripheralIdentifier, error: nil))
            }
        }
    }

    /// Returns one remote per requested identifier this backend actually knows — a device
    /// currently registered on the radio, or one this backend has reported a sighting for.
    /// **Identifiers it does not know are omitted, not vended as placeholders**, exactly as
    /// CoreBluetooth omits a `UUID` its stack has never seen.
    ///
    /// That omission is what makes this backend safe to compose: a
    /// ``CompositeCentral`` resolves an identifier against every child and keeps the first
    /// answer, so a backend that vended a remote for *any* `UUID` would shadow every sibling
    /// and make a real (or injected) peripheral unreachable.
    ///
    /// A remote is created on first use and the same instance is returned for the life of
    /// this backend, so a `Central` attaching an event handler to a retrieved peripheral is
    /// attaching it to the object the radio's events are routed to.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return identifiers.compactMap { identifier in
            // Read live from the radio, never from a pushed snapshot: a device registered a
            // moment ago must be retrievable *now*, without waiting for an actor hop and a
            // queue hop to deliver the news — the provider's own sessions register a device
            // and connect to it in one synchronous flow.
            guard radio.knownDeviceIDs.withLock({ $0.contains(identifier) }) || _discovered.contains(identifier) else {
                return nil
            }
            let created = remote(for: identifier)
            if created.name == nil {
                enqueue { [radio, queue] in
                    let name = await radio.name(of: identifier)
                    queue.async { created.updateName(name) }
                }
            }
            return created
        }
    }

    /// Always empty — "connected to the system by another app" has no meaning for an
    /// in-process radio, whose connections all belong to this backend.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return []
    }

    /// A no-op — the virtual radio produces no system connection events, exactly as
    /// CoreBluetooth on macOS does not.
    public func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?) {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// A no-op, for the same reason as ``registerForConnectionEvents(services:peripherals:)``.
    public func unregisterForConnectionEvents() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
#endif
