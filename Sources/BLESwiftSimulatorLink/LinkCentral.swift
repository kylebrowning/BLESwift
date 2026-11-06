//
//  LinkCentral.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// A `CentralManaging` that a provider process backs, not a local `CBCentralManager`. It sends each
/// call to the provider over one `LinkClientSession`. It turns each `CentralWireEvent` that comes
/// back into a `CentralEvent`, or into a `PeripheralEvent` of a ``LinkPeripheral``.
///
/// Give one to `Central(backend:queue:)`. Pass the *same* `DispatchQueue`:
///
/// ```swift
/// let queue = DispatchQueue(label: "ble")
/// let central = Central(backend: LinkCentral(endpoint: endpoint, queue: queue), queue: queue)
/// ```
///
/// - ``radioState`` is `.unsupported` until the provider reports its state.
/// - If an established link drops, the central reports each connected peripheral as disconnected
///   with `LinkError.providerDisconnected`. The state returns to `.unsupported`.
/// - Call every member on ``queue``. Events arrive with `queue.async`.
///
/// For the full rules, see <doc:BLESwiftSimulatorLink#Backend-rules>.
public final class LinkCentral: CentralManaging, Sendable {

    /// The queue to which the central confines every request, mirror update, and event delivery.
    /// The owning `Central` must be constructed with the same queue.
    public let queue: DispatchQueue

    /// The client session that this central owns. The central holds it strongly for its whole
    /// lifetime.
    private let session: LinkClientSession

    nonisolated(unsafe) private var _eventHandler: ((CentralEvent) -> Void)?
    nonisolated(unsafe) private var _radioState: CentralState = .unsupported
    nonisolated(unsafe) private var _didDeliverInitialState = false
    /// Every peripheral that this central gave out, so that the central returns the same
    /// instance for a given identifier. The provider's wire events go to this object.
    ///
    /// **The table has a limit. It drops the least recently sighted entry first.** A long scan in
    /// a busy room would grow this table without limit, with one mirror for each identifier ever
    /// seen. When the table has more than ``maximumPeripherals`` entries, the central drops the
    /// least recently sighted ones. It drops only entries that are `.disconnected`. A live
    /// operation still refers to anything that is connecting, connected, or disconnecting, so the
    /// central skips such an entry, however old it is.
    ///
    /// The reason for a cap and not a prune is the same as in `VirtualCentralBackend`. If the
    /// central forgets a peripheral that it sighted many sightings ago, no client is stranded
    /// unless the client also connected to it. The central does not refuse a forgotten
    /// identifier, and the next retrieval creates a new mirror.
    nonisolated(unsafe) private var _peripherals: [UUID: LinkPeripheral] = [:]

    /// The keys of ``_peripherals`` in least-recently-sighted order. The cap evicts from this
    /// list. An update is linear, over a list that ``maximumPeripherals`` bounds.
    nonisolated(unsafe) private var _sightingOrder: [UUID] = []

    /// The number of peripheral mirrors that this central keeps.
    private let maximumPeripherals: Int

    /// The default size of the mirror table. Every public initializer uses it. Tests override it
    /// to force eviction without creating a thousand identifiers.
    package static let defaultMaximumPeripherals = 1024

    nonisolated(unsafe) private var _nextChannelIdentifier: UInt32 = 1
    nonisolated(unsafe) private var _channels: [UInt32: ChannelEntry] = [:]

    /// One L2CAP channel that this central tunnels, and the peripheral that owns it, so that a
    /// disconnect can tear down exactly that peripheral's channels.
    private struct ChannelEntry {
        let channel: LinkL2CAPChannel
        let peripheral: UUID
    }

    /// Creates a central that controls the provider at `endpoint`, and starts dialing it at once.
    /// Reconnection is automatic, at `retryInterval`.
    ///
    /// - Parameters:
    ///   - endpoint: The host and port of the provider.
    ///   - queue: The serial queue to which this central is confined. It is the instance with
    ///     which the owning `Central` is constructed.
    ///   - clientName: A name that people can read, sent in the handshake for provider-side logs.
    ///     The default is the name of the current process.
    ///   - codec: The codec that encodes messages. The default is `LinkCodec.binaryPropertyList`.
    ///   - retryInterval: How long to wait before a new dial after a failure. The default is two
    ///     seconds.
    public convenience init(
        endpoint: LinkEndpoint,
        queue: DispatchQueue,
        clientName: String = ProcessInfo.processInfo.processName,
        codec: LinkCodec = .binaryPropertyList,
        retryInterval: Duration = .seconds(2)
    ) {
        self.init(
            endpoint: endpoint,
            queue: queue,
            clientName: clientName,
            codec: codec,
            retryInterval: retryInterval,
            maximumPeripherals: Self.defaultMaximumPeripherals
        )
    }

    /// Creates a central whose mirror table holds at most `maximumPeripherals` peripherals. This
    /// is the designated initializer. Tests use it because they cannot create
    /// ``defaultMaximumPeripherals`` identifiers to force an eviction.
    ///
    /// - Parameters:
    ///   - endpoint: The host and port of the provider.
    ///   - queue: The serial queue to which this central is confined.
    ///   - clientName: A name that people can read, sent in the handshake.
    ///   - codec: The codec that encodes messages.
    ///   - retryInterval: How long to wait before a new dial after a failure.
    ///   - maximumPeripherals: The number of peripheral mirrors to keep.
    package init(
        endpoint: LinkEndpoint,
        queue: DispatchQueue,
        clientName: String = ProcessInfo.processInfo.processName,
        codec: LinkCodec = .binaryPropertyList,
        retryInterval: Duration = .seconds(2),
        maximumPeripherals: Int
    ) {
        self.queue = queue
        self.maximumPeripherals = maximumPeripherals
        self.session = LinkClientSession(
            endpoint: endpoint,
            role: .central,
            clientName: clientName,
            codec: codec,
            queue: queue,
            retryInterval: retryInterval
        )
        // The captures are weak. This central owns the session, so a strong capture would make
        // a cycle, and `deinit`, which stops the session, would never run.
        session.onDisconnected = { [weak self] _ in self?.handleLinkDropped() }
        session.onMessage = { [weak self] message in self?.handle(message) }
        session.start()
    }

    deinit {
        session.stop()
        // This is the same teardown as ``shutdown()``, but without the queue hop, which it
        // cannot take: a `queue.async` cannot capture an object that is deallocating. Without
        // this teardown, the table would go with the central untouched, and every writer that
        // is suspended for credit would stay parked on a continuation that nothing resumes. The
        // provider's events can no longer reach a central that does not exist. `deinit` is the
        // last reference by definition, so the table belongs to this thread to take, without
        // the queue's protection.
        let doomed = _channels
        _channels = [:]
        for entry in doomed.values {
            entry.channel.remoteClosed(error: LinkError.providerDisconnected.nsError)
        }
    }

    /// Whether the provider accepted the handshake and the link is live.
    public var isProviderConnected: Bool {
        session.isConnected
    }

    /// Stops the session, then runs the teardown that a dropped link runs:
    ///
    /// - Every connected peripheral is disconnected with `LinkError.providerDisconnected`.
    /// - Every open L2CAP channel fails.
    /// - The state drops to `.unsupported`.
    ///
    /// Then it detaches every event handler, one turn later, including the handler of this
    /// central and the handler of each of its peripherals. Repeated calls are safe, and it is
    /// safe to call from any thread. Nothing calls it in production, because `deinit` does the
    /// same work on its own.
    ///
    /// **The teardown runs before the handlers go. The handlers go one turn later.**
    /// `session.stop()` marks the session stopped before the code observes the connection's
    /// terminal transition, so the session's `onDisconnected` never fires. Without this teardown,
    /// a consumer in the middle of a `read` would wait for a completion that nothing delivers and
    /// would not fail. `deliver(_:)` hands its event to the *next* queue turn, so clearing the
    /// handler in this block would lose every event that this teardown just produced. Thus the
    /// code queues the clearing behind those events.
    public func shutdown() {
        session.stop()
        queue.async { [self] in
            handleLinkDropped()
            queue.async { [self] in
                _eventHandler = nil
                for peripheral in _peripherals.values {
                    peripheral.detachEventHandler()
                }
            }
        }
    }

    // MARK: - CentralManaging

    /// The Bluetooth authorization status of the app. It is always `.allowedAlways`, because the
    /// provider process is responsible for authorization and would have refused the handshake
    /// otherwise.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// The last radio state that the provider reported. The value is `.unsupported` while no
    /// provider is connected.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _radioState
    }

    /// Receives every `CentralEvent` that the central translated from the provider's wire
    /// events.
    ///
    /// When an app attaches a handler, the central schedules the delivery of the current
    /// ``radioState``. This mirrors the `centralManagerDidUpdateState(_:)` that CoreBluetooth
    /// sends after an app sets a delegate. It also makes the first `.unsupported` observable when
    /// the provider is never reachable.
    public var eventHandler: ((CentralEvent) -> Void)? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return _eventHandler
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            _eventHandler = newValue
            guard newValue != nil, !_didDeliverInitialState else { return }
            _didDeliverInitialState = true
            deliver(.didUpdateState(_radioState))
        }
    }

    /// Asks the provider to start a scan.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.scan(services: services?.map(\.uuidString), allowDuplicates: options.allowDuplicates))
    }

    /// Asks the provider to stop the scan.
    public func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.stopScan)
    }

    /// Asks the provider to connect to `peripheral`. The function ignores a peripheral from
    /// another shim family, as the seam specifies.
    ///
    /// **The central files again a mirror that the cap evicted. It does not refuse it.** The table
    /// has a limit, so a caller can hold a peripheral that it retrieved long ago, and the entry
    /// can be gone when the caller connects. If the central dropped the request, the caller would
    /// wait for a `didConnect` that nobody sends. The identity check is on the peripheral's
    /// *owner*, which no eviction changes. The central ignores only a peripheral that belongs to
    /// another central.
    ///
    /// **The central fails a mirror that it replaced. It does not ignore it.** An eviction and
    /// then a new retrieval of the same identifier create a second mirror, and the provider's
    /// wire events for that identifier go to the new mirror. A connect on the old mirror could
    /// never complete, and if the central dropped the request, the caller would wait for its
    /// connect timeout for an outcome that is already settled. Thus the central answers the
    /// request. It delivers `didFailToConnect` with ``stalePeripheralHandleError``, on ``queue``,
    /// like every other event.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let target = peripheral as? LinkPeripheral, target.isOwned(by: self) else { return }
        guard let filed = _peripherals[target.identifier] else {
            _peripherals[target.identifier] = target
            touch(target.identifier)
            // Mark the peripheral as connecting *before* the cap runs, so the eviction that this
            // insert can trigger cannot choose the peripheral that the code is connecting.
            target.markConnecting()
            evictStalePeripherals(reserving: 0)
            send(.connect(peripheral: target.identifier, options: options.map(WireConnectOptions.init), requiresANCS: requiresANCS))
            return
        }
        guard filed === target else {
            deliver(.didFailToConnect(target.peripheralIdentifier, error: Self.stalePeripheralHandleError))
            return
        }
        target.markConnecting()
        send(.connect(peripheral: target.identifier, options: options.map(WireConnectOptions.init), requiresANCS: requiresANCS))
    }

    /// The error with which a connect fails when the peripheral that the caller passed is no
    /// longer the mirror that this central filed for that identifier.
    ///
    /// The error is in `LinkError.domain`, but it is not one of the cases of `LinkError`. It is a
    /// client-side refusal and not a failure that the link reported.
    public static var stalePeripheralHandleError: NSError {
        NSError(
            domain: LinkError.domain,
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "stale peripheral handle"]
        )
    }

    /// Asks the provider to cancel `peripheral`'s connection or connection attempt. The function
    /// ignores a peripheral from another shim family.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let target = peripheral as? LinkPeripheral, _peripherals[target.identifier] === target else { return }
        target.markDisconnecting()
        send(.cancelConnection(peripheral: target.identifier))
    }

    /// Returns this central's peripheral for each identifier. It creates a placeholder for an
    /// identifier that it has not seen. It always returns the same instance for a given
    /// identifier, so a `Central` that attaches an event handler to a retrieved peripheral
    /// attaches it to the object to which the code routes the wire events.
    ///
    /// **Every identifier gets a peripheral, seen or not.** This call is synchronous, with no
    /// round trip to ask the provider what it scanned. Thus nothing here can tell a previously
    /// seen identifier from an invented identifier, and the function omits none. This is
    /// intended. A placeholder lets `Central.connect(identifier:)` reach a peripheral that the
    /// provider's passthrough radio knows from an earlier run of the client process, although no
    /// scan in *this* process sighted it. An identifier that nothing knows fails where it must
    /// fail, at the connect. The provider answers `didFailToConnect` with
    /// `VirtualRadio.unknownDeviceError` (the `BLESwiftProvider` domain, code `1`).
    ///
    /// This is the one place where the link's answer is wider than the promise of
    /// `Central.knownPeripherals(withIdentifiers:)`, whose contract omits unrecognized
    /// identifiers. See the article "Running in the iOS Simulator" in BLESwift.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return identifiers.map { peripheral(for: $0) }
    }

    /// Every cached peripheral that is connected and that exposes at least one of `services` in
    /// its mirror cache.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        let wanted = Set(services)
        return _peripherals.values
            .filter { $0.connectionState == .connected && !wanted.isDisjoint(with: $0.discoveredServices) }
            .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
    }

    /// Asks the provider to register for system connection events.
    public func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?) {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.registerForConnectionEvents(services: services?.map(\.uuidString), peripherals: peripherals))
    }

    /// Asks the provider to cancel an earlier connection-event registration.
    public func unregisterForConnectionEvents() {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.unregisterForConnectionEvents)
    }

    // MARK: - Sending

    /// Sends `request` over the link. This is the peripherals' one door to the session.
    func send(_ request: CentralRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        session.send(.centralRequest(request))
    }

    /// Allocates the next local L2CAP channel id. The ids are monotonic from 1, so `0` is never a
    /// live channel. A failed open can use `0` for "no channel".
    func allocateChannelIdentifier() -> UInt32 {
        dispatchPrecondition(condition: .onQueue(queue))
        let identifier = _nextChannelIdentifier
        _nextChannelIdentifier &+= 1
        return identifier
    }

    // MARK: - L2CAP channels

    /// Creates the client half of an L2CAP channel under `identifier` and files it against
    /// `peripheral`. The channel is then ready for the provider's `didOpenL2CAPChannel` to give
    /// to `Central`. ``LinkPeripheral/openL2CAPChannel(_:)`` calls this before it sends the open
    /// request.
    @discardableResult
    func registerChannel(_ identifier: UInt32, psm: L2CAPPSM, peripheral: UUID) -> LinkL2CAPChannel {
        dispatchPrecondition(condition: .onQueue(queue))
        // The send closure hops onto `queue`, because a channel's methods run wherever its
        // consumer is. The closure is also the point where the code deregisters a channel after
        // a client-initiated close, which the provider answers with no event of its own.
        let channel = LinkL2CAPChannel(channel: identifier, psm: psm) { [weak self] request in
            guard let self else { return }
            queue.async { [self] in
                if case .l2capClose(let closing) = request { _channels.removeValue(forKey: closing) }
                send(request)
            }
        }
        _channels[identifier] = ChannelEntry(channel: channel, peripheral: peripheral)
        return channel
    }

    /// The number of peripheral mirrors that this central holds. Read it on ``queue``.
    ///
    /// This is a test hook. A malformed event must cost the session and must not file a mirror
    /// for the peripheral that the event named.
    package var peripheralCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _peripherals.count
    }

    /// The number of L2CAP channels that this central has filed. These are the client halves of
    /// opens that are live or that still wait for their completion.
    ///
    /// This is a test hook. A failed open must leave nothing in the table. Call it on
    /// ``queue``.
    package var openChannelCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return _channels.count
    }

    /// Tears down every channel that `predicate` selects. It reports `error` on each inbound
    /// stream and drops the channels from the table. Call it on ``queue``.
    private func closeChannels(matching predicate: (ChannelEntry) -> Bool, error: Error?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let doomed = _channels.filter { predicate($0.value) }
        for identifier in doomed.keys { _channels.removeValue(forKey: identifier) }
        for entry in doomed.values { entry.channel.remoteClosed(error: error) }
    }

    // MARK: - Peripheral table

    /// The peripheral for `identifier`. The central creates and caches it if it has not seen
    /// it.
    private func peripheral(for identifier: UUID, name: String? = nil) -> LinkPeripheral {
        dispatchPrecondition(condition: .onQueue(queue))
        if let existing = _peripherals[identifier] {
            existing.record(name: name)
            touch(identifier)
            return existing
        }
        // Evict *before* the insert and never after. A mirror that this central just created is
        // `.disconnected`, which the cap calls stale. If all other entries are busy, the table
        // would answer the overflow by dropping the mirror that the code is about to give to the
        // caller. The caller would hold an unfiled object, and the provider's events could never
        // reach it. The code reserves a slot for the insert, so the table still settles at
        // ``maximumPeripherals`` whenever it can.
        evictStalePeripherals(reserving: 1)
        let created = LinkPeripheral(identifier: identifier, name: name, central: self, queue: queue)
        _peripherals[identifier] = created
        touch(identifier)
        return created
    }

    /// Moves `identifier` to the most-recently-sighted end of ``_sightingOrder``. Call it on
    /// ``queue``.
    private func touch(_ identifier: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let index = _sightingOrder.firstIndex(of: identifier) {
            _sightingOrder.remove(at: index)
        }
        _sightingOrder.append(identifier)
    }

    /// Drops the least recently sighted `.disconnected` mirrors until the table is within
    /// ``maximumPeripherals`` again. The function leaves a peripheral in any other connection
    /// state alone, because a connect, a live connection, or a cancellation in flight still
    /// refers to it, and the provider's events for it must reach the instance that its owner
    /// holds. Call it on ``queue``.
    ///
    /// - Parameter reserving: The number of slots that the caller is about to fill. The function
    ///   keeps them free in addition to the entries that are already in the table.
    private func evictStalePeripherals(reserving: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        let limit = maximumPeripherals - reserving
        guard _peripherals.count > limit else { return }
        var overflow = _peripherals.count - limit
        var kept: [UUID] = []
        kept.reserveCapacity(_sightingOrder.count)
        for identifier in _sightingOrder {
            guard let candidate = _peripherals[identifier] else { continue }
            guard overflow > 0, candidate.connectionState == .disconnected else {
                kept.append(identifier)
                continue
            }
            // Detach the mirror before it goes, as `CentralSession` and `VirtualCentralBackend`
            // detach the remotes that their own caps evict. An owner that still holds this mirror
            // keeps its handler alive with it, but the mirror is no longer a way for this central
            // to deliver. A later event for the same identifier reaches the new mirror that the
            // code created in its place, and this mirror must stay silent.
            candidate.detachEventHandler()
            _peripherals.removeValue(forKey: identifier)
            overflow -= 1
        }
        _sightingOrder = kept
    }

    // MARK: - Link lifecycle

    /// Handles a link that dropped after it was established. Everything that was connected is now
    /// unreachable, and the radio state is unknowable again.
    private func handleLinkDropped() {
        dispatchPrecondition(condition: .onQueue(queue))
        let error = LinkError.providerDisconnected.nsError
        closeChannels(matching: { _ in true }, error: error)
        for peripheral in _peripherals.values where peripheral.connectionState != .disconnected {
            let identifier = peripheral.peripheralIdentifier
            peripheral.markDisconnected()
            deliver(.didDisconnect(identifier, error: error))
        }
        guard _radioState != .unsupported else { return }
        _radioState = .unsupported
        deliver(.didUpdateState(.unsupported))
    }

    /// Routes an inbound message. A message that is not a `Central`-role event is not a concern
    /// of this client.
    private func handle(_ message: LinkMessage) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard case .centralEvent(let event) = message else { return }
        do {
            try handle(event)
        } catch {
            // A provider that puts a field on the wire that no BLESwift type can hold is faulty.
            // The field can be an identifier that no identifier accepts, or a negotiated maximum
            // that no caller can divide by. Drop the session and dial again. Do not trap this
            // process on behalf of the provider.
            session.dropConnection()
        }
    }

    // MARK: - Wire events

    /// Translates one ``CentralWireEvent`` into updates of the mirror cache and the
    /// `CentralEvent` or `PeripheralEvent` that it stands for. The code applies the updates
    /// inline and delivers the events on the next queue tick.
    ///
    /// **The code validates every field before it calls `peripheral(for:)`.** A throw from this
    /// method drops the session, so anything that the code gave to the mirror table first
    /// outlives the event that never happened. `peripheral(for:)` *creates* an entry for an
    /// unknown identifier. A `.disconnected` mirror that the code filed for a malformed event
    /// stays in the table, shows up to the caller across the reconnect that follows, and can
    /// evict a real mirror when it enters. Thus each case below first reads its identifiers,
    /// lengths, and advertisements into local values, and only then asks for the mirror to which
    /// it applies them.
    private func handle(_ event: CentralWireEvent) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {

        case .didUpdateState(let state):
            // Do NOT set `_didDeliverInitialState` here, on purpose. A provider state that lands
            // before a handler is attached would otherwise suppress the once-only delivery of the
            // setter, and `Central.state` would stay `.unknown` against a healthy provider. The
            // attach always delivers `_radioState`, which this assignment has already updated.
            _radioState = state.state
            deliver(.didUpdateState(state.state))

        case .didDiscover(let uuid, let name, let advertisement, let rssi):
            // Validate this before touching the mirror table. See the note above the switch.
            let data = try advertisement.advertisementData
            let target = peripheral(for: uuid, name: name)
            deliver(.didDiscover(
                peripheral: target.peripheralIdentifier,
                advertisement: data,
                rssi: rssi
            ))

        case .didConnect(let uuid, let name, let maximumWriteWithResponse, let maximumWriteWithoutResponse):
            // Validate this before mirroring anything. A maximum of zero makes
            // `Peripheral.writeChunked` loop forever, and a negative maximum makes it trap. Refuse
            // a provider that reports either value, as for a malformed identifier: drop the
            // session and not the process.
            let withResponse = try WireLengthValidation.validated(maximumWriteWithResponse)
            let withoutResponse = try WireLengthValidation.validated(maximumWriteWithoutResponse)
            let target = peripheral(for: uuid)
            target.markConnected(
                name: name,
                maximumWriteWithResponse: withResponse,
                maximumWriteWithoutResponse: withoutResponse
            )
            deliver(.didConnect(target.peripheralIdentifier))

        case .didFailToConnect(let uuid, let error):
            let target = peripheral(for: uuid)
            let identifier = target.peripheralIdentifier
            target.markDisconnected()
            closeChannels(matching: { $0.peripheral == uuid }, error: error?.nsError ?? Self.disconnectedError)
            deliver(.didFailToConnect(identifier, error: error?.nsError))

        case .didDisconnect(let uuid, let error):
            let target = peripheral(for: uuid)
            let identifier = target.peripheralIdentifier
            target.markDisconnected()
            closeChannels(matching: { $0.peripheral == uuid }, error: error?.nsError ?? Self.disconnectedError)
            deliver(.didDisconnect(identifier, error: error?.nsError))

        case .connectionEventDidOccur(let uuid, let connected):
            deliver(.connectionEventDidOccur(peripheral: uuid, event: connected ? .peerConnected : .peerDisconnected))

        case .didUpdateANCSAuthorization(let uuid, let authorized):
            peripheral(for: uuid).setANCSAuthorized(authorized)
            deliver(.didUpdateANCSAuthorization(peripheral: uuid, authorized: authorized))

        case .didDiscoverServices(let uuid, let services, let error):
            let discovered = try services.map { ServiceIdentifier(uuid: try WireIdentifierValidation.validated($0)) }
            let target = peripheral(for: uuid)
            target.recordDiscoveredServices(discovered)
            target.deliver(.didDiscoverServices(error: error?.nsError))

        case .didDiscoverCharacteristics(let uuid, let service, let characteristics, let error):
            let serviceIdentifier = ServiceIdentifier(uuid: try WireIdentifierValidation.validated(service))
            var discovered: [CharacteristicIdentifier: CharacteristicProperties] = [:]
            // Build the dictionary by subscript, on purpose. Two wire entries whose UUID strings
            // differ only in case are one `CharacteristicIdentifier`, and the last one reported
            // wins. Building the dictionary from the pairs would trap on the collision.
            for characteristic in characteristics {
                let identifier = CharacteristicIdentifier(
                    uuid: try WireIdentifierValidation.validated(characteristic.uuid),
                    service: serviceIdentifier
                )
                discovered[identifier] = CharacteristicProperties(rawValue: characteristic.properties)
            }
            let target = peripheral(for: uuid)
            target.replaceCharacteristics(discovered, for: serviceIdentifier)
            target.deliver(.didDiscoverCharacteristics(service: serviceIdentifier, error: error?.nsError))

        case .didDiscoverDescriptors(let uuid, let characteristic, let descriptors, let error):
            let characteristicIdentifier = try characteristic.identifier
            let discovered = try descriptors.map {
                DescriptorIdentifier(
                    uuid: try WireIdentifierValidation.validated($0),
                    characteristic: characteristicIdentifier
                )
            }
            let target = peripheral(for: uuid)
            target.replaceDescriptors(discovered, for: characteristicIdentifier)
            target.deliver(.didDiscoverDescriptors(characteristic: characteristicIdentifier, error: error?.nsError))

        case .didWriteValue(let uuid, let characteristic, let error):
            let identifier = try characteristic.identifier
            peripheral(for: uuid).deliver(.didWriteValue(characteristic: identifier, error: error?.nsError))

        case .writeWithoutResponseAccepted(let uuid, let sequence):
            let target = peripheral(for: uuid)
            if target.acknowledgeWriteWithoutResponse(sequence: sequence) {
                target.deliver(.isReadyToSendWriteWithoutResponse)
            }

        case .didUpdateValue(let uuid, let characteristic, let value, let error):
            let identifier = try characteristic.identifier
            peripheral(for: uuid).deliver(.didUpdateValue(
                characteristic: identifier,
                value: value,
                error: error?.nsError
            ))

        case .didUpdateNotificationState(let uuid, let characteristic, let isNotifying, let error):
            let identifier = try characteristic.identifier
            let target = peripheral(for: uuid)
            target.setNotifying(isNotifying, for: identifier)
            target.deliver(.didUpdateNotificationState(characteristic: identifier, isNotifying: isNotifying, error: error?.nsError))

        case .didUpdateValueForDescriptor(let uuid, let descriptor, let value, let error):
            let identifier = try descriptor.identifier
            peripheral(for: uuid).deliver(.didUpdateValueForDescriptor(
                descriptor: identifier,
                value: value,
                error: error?.nsError
            ))

        case .didWriteValueForDescriptor(let uuid, let descriptor, let error):
            let identifier = try descriptor.identifier
            peripheral(for: uuid).deliver(.didWriteValueForDescriptor(descriptor: identifier, error: error?.nsError))

        case .didReadRSSI(let uuid, let rssi, let error):
            peripheral(for: uuid).deliver(.didReadRSSI(rssi, error: error?.nsError))

        case .didModifyServices(let uuid, let invalidated):
            let services = try invalidated.map { ServiceIdentifier(uuid: try WireIdentifierValidation.validated($0)) }
            let target = peripheral(for: uuid)
            target.invalidate(services: services)
            target.deliver(.didModifyServices(services))

        case .didOpenL2CAPChannel(let uuid, let identifier, _, let error):
            let target = peripheral(for: uuid)
            if let error {
                _channels.removeValue(forKey: identifier)
                target.deliver(.didOpenL2CAPChannel(channel: nil, error: error.nsError))
                return
            }
            guard let entry = _channels[identifier] else {
                // The provider opened a channel that this central has no record of. Its half is
                // live and would be pumped forever, so close it explicitly.
                send(.l2capClose(channel: identifier))
                target.deliver(.didOpenL2CAPChannel(channel: nil, error: Self.unknownChannelError))
                return
            }
            target.deliver(.didOpenL2CAPChannel(channel: entry.channel, error: nil))

        case .l2capData(let identifier, let data):
            // A throw here drops the session. The frame was larger than the chunk size that both
            // ends agreed on, and no honest provider sends such a frame.
            try _channels[identifier]?.channel.receive(data)

        case .l2capCredit(let identifier, let bytes):
            _channels[identifier]?.channel.addCredit(bytes: bytes)

        case .l2capClosed(let identifier, let error):
            guard let entry = _channels.removeValue(forKey: identifier) else { return }
            entry.channel.remoteClosed(error: error?.nsError)
        }
    }

    /// The error that an open reports when it looks successful but this central has no channel
    /// filed under the id that the provider named. This is a protocol violation that a caller
    /// cannot act on.
    private static let unknownChannelError = NSError(
        domain: LinkError.domain,
        code: 101,
        userInfo: [NSLocalizedDescriptionKey: "The provider reported an L2CAP channel this central never opened"]
    )

    /// The error with which the code tears down open channels when their peripheral disconnects
    /// without an error of its own.
    private static let disconnectedError = NSError(
        domain: LinkError.domain,
        code: 102,
        userInfo: [NSLocalizedDescriptionKey: "The peripheral disconnected, closing its L2CAP channels"]
    )

    /// Delivers `event` to ``eventHandler`` asynchronously on ``queue``, as the seam's
    /// never-inline delivery contract requires.
    private func deliver(_ event: CentralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            _eventHandler?(event)
        }
    }
}
