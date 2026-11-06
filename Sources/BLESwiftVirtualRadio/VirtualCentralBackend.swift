//
//  VirtualCentralBackend.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import Dispatch
import Foundation
import BLESwiftCompat17

/// A `CentralManaging` that a ``VirtualRadio`` serves instead of CoreBluetooth.
/// Give one to `Central(backend:queue:)`. The resulting `Central` talks to the radio's virtual
/// devices. No hardware is necessary.
///
/// Any number of backends can share one radio. Each registers under its own session identifier, so
/// scans, connections, and subscriptions never leak between backends.
///
/// **Concurrency: the queue confines the state. A lock does not protect it.**
/// Every stored property is `nonisolated(unsafe)` and code touches it only on ``queue``. Every
/// `CentralManaging` method asserts this at entry. Work reaches the radio actor through one serial
/// chain of `Task`s, rooted in the backend's attachment. See `enqueue(_:)`. The backend delivers
/// every event back with `queue.async`, never inline, as `CentralManaging` requires.
public final class VirtualCentralBackend: CentralManaging, Sendable {

    /// The queue that confines every method and every event delivery.
    public let queue: DispatchQueue

    /// The identity of this backend to the radio. It is also the `Subscriber` id that device
    /// handlers see for traffic that starts here.
    public let sessionID = UUID()

    private let radio: VirtualRadio

    nonisolated(unsafe) private var _eventHandler: ((CentralEvent) -> Void)?

    /// The remote that the backend vended for each identifier. The backend returns the same
    /// instance each time, and the radio routes its events to it.
    ///
    /// **Bounded. The least recently vended remote leaves first.**
    /// Without a cap, a long-lived backend asked for identifier after identifier would grow one
    /// remote for each identifier ever named.
    ///
    /// The backend drops only a `.disconnected` remote (nothing connecting, connected, or
    /// disconnecting). Any other remote carries a live connection, and its events must reach the
    /// instance that the caller holds, so the backend keeps it however old it is.
    ///
    /// A caller loses nothing when the backend forgets a remote. If the caller retrieves that
    /// identifier again, the backend creates a new remote. ``connect(_:options:requiresANCS:)``
    /// files an evicted remote again and does not ignore it.
    nonisolated(unsafe) private var _remotes: [UUID: VirtualPeripheralRemote] = [:]

    /// The keys of ``_remotes`` in least-recently-vended order. The cap evicts from the start of
    /// this list.
    nonisolated(unsafe) private var _remoteOrder: [UUID] = []

    /// How many remotes ``_remotes`` keeps.
    private let maximumRemotes: Int

    /// The default size of the remote table. Tests override it to force eviction.
    package static let defaultMaximumRemotes = 1024

    nonisolated(unsafe) private var _announcedState = false

    /// The identifiers for which this backend reported a sighting. A device that the radio removed
    /// after the sighting stays retrievable. CoreBluetooth also keeps vending a `CBPeripheral` for
    /// a peer that it scanned, and the connect attempt then fails.
    ///
    /// **Bounded. The oldest sighting leaves first.** The code caps the history. It does not prune
    /// identifiers that the radio no longer knows, because that would make a removed device
    /// unretrievable. The cap forgets only sightings that are ``maximumDiscovered`` devices old. A
    /// client cannot still hold an identifier from such an old sighting unless it also connected to
    /// that device.
    nonisolated(unsafe) private var _discovered: Set<UUID> = []

    /// The order in which ``_discovered`` was filled. The cap drops the oldest sighting.
    nonisolated(unsafe) private var _discoveryOrder: [UUID] = []

    /// How many sightings ``_discovered`` remembers.
    private let maximumDiscovered: Int

    /// The default size of the sighting history. Tests override it to force eviction.
    package static let defaultMaximumDiscovered = 1024

    /// The serial chain of radio work, rooted in the backend's attachment. Swift gives no ordering
    /// between independent `Task`s. Without the chain, a `scan` and the `stopScan` after it could
    /// reach the actor in either order, and a duplicate-reporting repeater would keep running for a
    /// stopped scan.
    nonisolated(unsafe) private var _work: Task<Void, Never>!

    /// The authorization status that this backend reports. It is always `.allowedAlways`.
    ///
    /// The value is constant and not settable, because the system's Bluetooth permission never
    /// gates a virtual radio. A test that needs a denied backend uses the fakes of
    /// `BLESwiftTestSupport`, whose `bluetoothAuthorization` is scripted.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// Creates a backend that `radio` serves and that `queue` confines.
    ///
    /// ``radioState`` is `CentralState.poweredOn` from construction. The matching `didUpdateState`
    /// arrives once, when code first attaches a non-`nil` ``eventHandler``.
    ///
    /// - Parameters:
    ///   - radio: The radio that hosts the virtual devices to serve.
    ///   - queue: The queue that confines every method and event delivery. It must be serial and be
    ///     the queue that the owning `Central` uses.
    public convenience init(radio: VirtualRadio, queue: DispatchQueue) {
        self.init(
            radio: radio,
            queue: queue,
            maximumDiscovered: Self.defaultMaximumDiscovered,
            maximumRemotes: Self.defaultMaximumRemotes
        )
    }

    /// Creates a backend whose sighting history holds at most `maximumDiscovered` identifiers and
    /// whose remote table holds at most `maximumRemotes`. This is the designated initializer. Tests
    /// use it to force an eviction.
    ///
    /// - Parameters:
    ///   - radio: The radio that hosts the virtual devices to serve.
    ///   - queue: The queue that confines every method and event delivery.
    ///   - maximumDiscovered: How many sightings to remember.
    ///   - maximumRemotes: How many peripheral remotes to keep.
    package init(
        radio: VirtualRadio,
        queue: DispatchQueue,
        maximumDiscovered: Int,
        maximumRemotes: Int = VirtualCentralBackend.defaultMaximumRemotes
    ) {
        self.radio = radio
        self.queue = queue
        self.maximumDiscovered = maximumDiscovered
        self.maximumRemotes = maximumRemotes
        let session = sessionID
        // The reference is weak, so the radio's registration never keeps this backend alive. The
        // hop's strong reference lasts only as long as the delivery.
        let sink: @Sendable (CentralEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.queue.async { self.deliver(event) }
        }
        // The root of the chain. Nothing that this backend asks of the radio can outrun the
        // attachment.
        _work = Task { [radio] in
            await radio.attach(session: session, centralSink: sink)
        }
    }

    /// Detaches from the radio twice: once immediately, and once behind the work still queued.
    ///
    /// The first detach is unconditional and comes *before* the code awaits the chain. It cancels a
    /// duplicate-reporting scan repeater. Without it, a chain that waits on a radio answer that
    /// never comes would leave that repeater running for the life of the process.
    ///
    /// The second detach covers the opposite order. A chain whose `attach` did not run yet would
    /// register the session again behind the first detach. It costs nothing when the session is
    /// already gone, because `detach` is idempotent.
    ///
    /// The code also cancels every remote's delayed connect attempt, on ``queue``. The attempt did
    /// not reach the radio, so the detach drops nothing for it. Its sleep would otherwise hold the
    /// remote for the rest of a delay that no backend will answer.
    ///
    /// It is safe to read `_work` and `_remotes` off-queue here. `deinit` runs only after every
    /// reference is gone, and every queued delivery holds one.
    deinit {
        let radio = self.radio
        let session = sessionID
        let work = _work
        let remotes = Array(_remotes.values)
        queue.async {
            for remote in remotes { remote.cancelPendingConnect() }
        }
        Task {
            await radio.detach(session: session)
            await work?.value
            await radio.detach(session: session)
        }
    }

    /// Appends `body` to the serial chain of radio work, so it runs after the attachment and every
    /// earlier operation. Call this method on ``queue``.
    private func enqueue(_ body: @escaping @Sendable () async -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = _work
        _work = Task {
            await previous?.value
            await body()
        }
    }

    /// Suspends until every piece of radio work queued so far has run. This is the chain's tail at
    /// the moment this method reads it on ``queue``. It does not await the deliveries that the
    /// chain hopped onto the queue. To flush them, run an empty block on the queue afterward.
    ///
    /// This is a test hook, not API. A test uses it to assert on what a race left behind.
    package func waitForPendingWork() async {
        let work = await withCheckedContinuation { (continuation: CheckedContinuation<Task<Void, Never>?, Never>) in
            queue.async { continuation.resume(returning: self._work) }
        }
        await work?.value
    }

    /// Delivers `event` to ``eventHandler``. Call this method on ``queue``.
    ///
    /// A disconnect first settles the affected remote's
    /// ``BLESwiftCore/PeripheralRemote/connectionState``, so the remote never reports `.connected`
    /// to a handler that reacts to its own disconnect. A radio-initiated disconnect, such as a
    /// device removal, arrives on this path.
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

    /// Records a sighting of `identifier` and forgets the oldest sighting when the history is full.
    /// Call this method on ``queue``.
    private func remember(_ identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _discovered.insert(identifier).inserted else { return }
        _discoveryOrder.append(identifier)
        guard _discoveryOrder.count > maximumDiscovered else { return }
        _discovered.remove(_discoveryOrder.removeFirst())
    }

    /// The remote for `identifier`. It is created on first use and reused until the cap forgets it.
    /// Call this method on ``queue``.
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

    /// Files `remote` under its identifier. It evicts a stale remote first, so the cap cannot drop
    /// the remote being added. A remote that was never connected is `.disconnected`, so the cap can
    /// drop it. Call this method on ``queue``.
    private func file(_ remote: VirtualPeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        evictStaleRemotes(reserving: _remotes[remote.identifier] == nil ? 1 : 0)
        _remotes[remote.identifier] = remote
        touch(remote.identifier)
    }

    /// Moves `identifier` to the most-recently-vended end of ``_remoteOrder``. Call this method on
    /// ``queue``.
    private func touch(_ identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let index = _remoteOrder.firstIndex(of: identifier) {
            _remoteOrder.remove(at: index)
        }
        _remoteOrder.append(identifier)
    }

    /// Drops the least recently vended disconnected remotes until the table is within
    /// ``maximumRemotes``. It detaches each dropped remote's event handler, so nothing that still
    /// holds the remote can deliver into a backend that forgot it. It never touches a remote in
    /// another connection state. Call this method on ``queue``.
    ///
    /// - Parameter reserving: How many slots the caller is about to fill. The method keeps them
    ///   free.
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

    /// Receives every `CentralEvent` that this backend produces, on ``queue``. The first non-`nil`
    /// attachment also triggers the one-shot `didUpdateState(.poweredOn)`.
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

    /// Always `CentralState.poweredOn`. A virtual radio is never off.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return .poweredOn
    }

    /// Starts a radio scan. The backend reports every advertising device that matches `services`
    /// once, immediately. With `options.allowDuplicates`, it reports matching devices again once
    /// each second until ``stopScan()``.
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

    /// Connects to a virtual device, advertising or not. The backend delivers the outcome as
    /// `didConnect` or `didFailToConnect`, never inline.
    ///
    /// - An unregistered identifier fails with ``VirtualRadio/unknownDeviceError``.
    /// - A device with an armed failure (``VirtualDeviceHandle/failConnections(with:times:)``)
    ///   fails with that error, unchanged.
    /// - A device with a connect delay (``VirtualLatency/connect``) sleeps first. A cancel during
    ///   the sleep withdraws the attempt.
    ///
    /// The remote's `connectionState` decides the result. `.disconnected` sends the attempt to the
    /// radio. `.connected` delivers `didConnect` and changes nothing. `.connecting` does nothing,
    /// and the pending attempt answers both requests. `.disconnecting` delivers `didFailToConnect`
    /// with ``connectWhileDisconnectingError``, after the cancel's `didDisconnect`. See
    /// <doc:InProcessMocking#Driving-the-backend-directly>.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        // **A remote that the cap evicted is filed again, not refused.** A caller that holds a
        // remote retrieved long ago can find its entry gone. Dropping the request would leave that
        // caller waiting for a `didConnect` that nothing sends. The test is on the remote's
        // *owner*, which eviction never changes. A remote that belongs to another backend is still
        // ignored.
        //
        // A remote that this backend later *replaced* for the same identifier is different. The
        // radio sends that identifier's events to the newer object, so the older remote could never
        // complete a connect. The code fails it, so the caller does not wait for its connect
        // timeout.
        guard let remote = peripheral as? VirtualPeripheralRemote, remote.isOwned(by: sessionID) else { return }
        if let filed = _remotes[remote.identifier] {
            guard filed === remote else {
                // Hopped, never inline. The consumer calls `connect(_:options:requiresANCS:)`
                // synchronously, and the seam forbids re-entry into its handler from inside that
                // call.
                queue.async { [self] in
                    deliver(.didFailToConnect(remote.peripheralIdentifier, error: Self.stalePeripheralHandleError))
                }
                return
            }
        } else {
            file(remote)
        }
        switch remote.connectionState {
        case .connected:
            queue.async { [self] in deliver(.didConnect(remote.peripheralIdentifier)) }
            return
        case .connecting:
            return
        case .disconnecting:
            // Go through the chain, not a bare `queue.async` from this turn. The cancel posts its
            // `didDisconnect` from its chain step, which can finish before or after this turn ends.
            // A failure posted from here would race it. Behind that step, the failure always
            // follows.
            enqueue { [queue] in
                queue.async { [self] in
                    deliver(.didFailToConnect(remote.peripheralIdentifier, error: Self.connectWhileDisconnectingError))
                }
            }
            return
        case .disconnected:
            break
        }
        remote.setConnectionState(.connecting)
        // Nothing should be pending on a `.disconnected` remote, because every path that settles
        // one clears it. The token already refuses a stale task's hop. The cancel removes that
        // task's sleeper, which a `ManualClock` would otherwise count until a deadline that nobody
        // waits on.
        remote.cancelPendingConnect()
        let attempt = remote.beginConnectAttempt()
        let device = remote.identifier
        // Read the delay synchronously, on this queue, from the mirror that the radio keeps. The
        // decision whether the attempt sleeps first cannot wait on an actor hop.
        let delay = radio.connectLatencies.withLock { $0[device] ?? .zero }
        guard delay > .zero else {
            enqueueConnect(of: remote, attempt: attempt)
            return
        }
        remote.pendingConnect = Task { [weak self, clock = radio.clock, queue] in
            // A cancelled sleep ends the attempt. The attempt was withdrawn or the backend went
            // away, and the cancel already settled and reported the remote.
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self else { return }
            queue.async {
                // Clear this attempt's task on every exit, so a hop that applies nothing never
                // leaves a stale task for a later cancel. A newer attempt's task is not this hop's
                // to clear.
                let wasPending = remote.pendingConnect != nil && remote.connectAttempt == attempt
                if wasPending { remote.pendingConnect = nil }
                guard wasPending, remote.connectionState == .connecting else { return }
                self.enqueueConnect(of: remote, attempt: attempt)
            }
        }
    }

    /// Appends connect attempt `attempt` of `remote` to the serial chain. This is the body of
    /// ``connect(_:options:requiresANCS:)`` for a `.disconnected` remote. An undelayed attempt
    /// takes it at once, and a delayed attempt after its delay. Call this method on ``queue``.
    private func enqueueConnect(of remote: VirtualPeripheralRemote, attempt: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        let device = remote.identifier
        enqueue { [radio, sessionID, queue] in
            // Connect and name in one actor hop. A second hop for the name could see a `remove()`
            // that landed in between and rename a live connection to `nil`.
            let outcome = await radio.connect(session: sessionID, device: device) { event in
                queue.async { remote.deliver(event) }
            }
            queue.async { [self] in
                // Only the current attempt's hop applies anything. A forced disconnect can land
                // between the radio call and this hop and settle the remote, and the consumer (a
                // reconnecting `Central`, or the provider's `CentralSession` resending a link
                // client's connect) can then connect again at once. Without the guard, this hop
                // would mark the *new* attempt's `.connecting` remote `.connected`, or fail it,
                // with the old attempt's answer. The radio would hold nothing. See
                // `VirtualPeripheralRemote.connectAttempt`.
                guard remote.connectAttempt == attempt else { return }
                if let failure = outcome.error {
                    remote.setConnectionState(.disconnected)
                    deliver(.didFailToConnect(remote.peripheralIdentifier, error: failure))
                } else {
                    // A disconnect that already settled the remote wins, even with no newer
                    // attempt. The radio's `connect` returned success on the actor, but this hop is
                    // enqueued afterward. A forced disconnect or a removal can land in between and
                    // enqueue its `didDisconnect` first. `deliver` then sets the remote
                    // `.disconnected` and the consumer fails its connect. Marking it `.connected`
                    // here would leave a remote with no radio connection, and a later cancel would
                    // deliver nothing. A cancel in between sets `.disconnecting`, not
                    // `.disconnected`, so a cancel queued behind a connect still gets its
                    // `didConnect` and then its `didDisconnect`.
                    guard remote.connectionState != .disconnected else { return }
                    remote.updateName(outcome.name)
                    // Run before `.connected` and `didConnect`. A handler that sizes its chunks
                    // from `maximumWriteValueLength(for:)` in its connect callback must see the
                    // negotiated value, not the last connection's.
                    remote.updateMaximumWriteWithoutResponseLength(outcome.maximumWriteWithoutResponseLength)
                    remote.setConnectionState(.connected)
                    deliver(.didConnect(remote.peripheralIdentifier))
                }
            }
        }
    }

    /// The error that a connect fails with when the remote it received is no longer the remote that
    /// this backend filed for that identifier.
    ///
    /// The code is 8, not 7, because 7 is already `CentralSession.l2capCreditRejected` in the same
    /// `BLESwiftProvider` domain. A caller that switches on the code can then tell the failures
    /// apart.
    public static var stalePeripheralHandleError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "stale peripheral handle"]
        )
    }

    /// The error that a connect fails with when the remote it received is `.disconnecting`. A
    /// ``cancelPeripheralConnection(_:)`` is in flight and will settle the remote `.disconnected`.
    /// See ``connect(_:options:requiresANCS:)``.
    ///
    /// The code is 11, because the `BLESwiftProvider` domain already uses 1 through 10.
    public static var connectWhileDisconnectingError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "connect requested while a disconnect is in progress"]
        )
    }

    /// Cancels a connection and delivers `didDisconnect` with no error, as CoreBluetooth does for
    /// an explicit cancel.
    ///
    /// - A remote that is already disconnected: nothing happens.
    /// - A connection that a forced ``VirtualDeviceHandle/disconnect(_:error:)`` or a removal
    ///   dropped first: this call removes nothing and delivers nothing. The forced event owns the
    ///   `didDisconnect`.
    /// - An attempt that still sleeps out its connect delay: the attempt never reaches the radio.
    ///   The remote becomes `.disconnecting`, then `.disconnected` with `didDisconnect(nil)`. A
    ///   `connect` in between fails with ``connectWhileDisconnectingError``.
    /// - An attempt that an armed failure already failed: nothing follows `didFailToConnect`.
    ///
    /// The backend delivers `didDisconnect` only when this call removed the connection. See
    /// <doc:InProcessMocking#Cancelling-a-connection>.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let remote = peripheral as? VirtualPeripheralRemote, remote === _remotes[remote.identifier] else { return }
        guard remote.connectionState != .disconnected else { return }
        if remote.pendingConnect != nil {
            remote.cancelPendingConnect()
            remote.invalidateConnectAttempt()
            remote.setConnectionState(.disconnecting)
            queue.async { [self] in
                // No guard, by design. While the remote is `.disconnecting`, no connect takes a
                // token and no path changes the state, so this hop is the only one that can settle
                // it. `deliver(_:)` settles it, as on every `didDisconnect`.
                deliver(.didDisconnect(remote.peripheralIdentifier, error: nil))
            }
            return
        }
        remote.setConnectionState(.disconnecting)
        let device = remote.identifier
        enqueue { [radio, sessionID, queue] in
            let removed = await radio.disconnect(session: sessionID, device: device)
            queue.async { [self] in
                guard removed else { return }
                // `deliver(_:)` settles the remote `.disconnected`, as on every `didDisconnect`.
                deliver(.didDisconnect(remote.peripheralIdentifier, error: nil))
            }
        }
    }

    /// Returns one remote for each requested identifier that this backend knows: a device that is
    /// registered on the radio now, or one for which this backend reported a sighting. **The method
    /// omits unknown identifiers. It does not vend placeholders.** CoreBluetooth also omits a
    /// `UUID` that its stack has never seen.
    ///
    /// This makes the backend safe to compose. `BLESwiftProvider`'s `CompositeCentral` resolves an
    /// identifier against every child and keeps the first answer. A backend that vended a remote
    /// for *any* `UUID` would shadow every sibling, and a real or injected peripheral would be
    /// unreachable.
    ///
    /// The backend creates a remote on first use and returns the same instance for its life. A
    /// `Central` that attaches an event handler to a retrieved peripheral thus attaches it to the
    /// object that the radio routes its events to.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return identifiers.compactMap { identifier in
            // Read the device list live from the radio, not from a pushed snapshot. A device
            // registered a moment ago must be retrievable *now*, without an actor hop and a queue
            // hop. The provider's sessions register a device and connect to it in one synchronous
            // flow.
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

    /// Always empty. An in-process radio has no connections that another app holds.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return []
    }

    /// Does nothing. The virtual radio produces no system connection events.
    public func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?) {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// Does nothing, for the same reason as ``registerForConnectionEvents(services:peripherals:)``.
    public func unregisterForConnectionEvents() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
