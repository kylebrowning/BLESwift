//
//  LinkCentral.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// A `CentralManaging` backed by a provider process rather than a local `CBCentralManager`:
/// every call is encoded as a ``CentralRequest`` and sent over one `LinkClientSession`,
/// and every ``CentralWireEvent`` the provider sends back is translated into a `CentralEvent`
/// or a ``LinkPeripheral``'s `PeripheralEvent`.
///
/// Hand one to `Central(backend:queue:)`, passing the *same* `DispatchSerialQueue`:
///
/// ```swift
/// let queue = DispatchSerialQueue(label: "ble")
/// let central = Central(backend: LinkCentral(endpoint: endpoint, queue: queue), queue: queue)
/// ```
///
/// **Radio state.** ``radioState`` starts `.unsupported` — a provider that has not answered
/// is indistinguishable from a machine without Bluetooth — and that first `.unsupported` is
/// delivered as soon as an ``eventHandler`` is attached, so a `Central` whose provider never
/// appears still reflects it. The provider's own `didUpdateState` replaces it; if the link
/// then drops, every peripheral that was not already disconnected is reported disconnected
/// with `LinkError.providerDisconnected` and the state falls back to `.unsupported` until
/// the provider reconnects and sends its real state.
///
/// **Concurrency — queue-confined, not lock-protected.** Every stored property is
/// `nonisolated(unsafe)`, safe only because every `CentralManaging` method and property
/// accessor asserts `dispatchPrecondition(condition: .onQueue(queue))` and touches state
/// inline; session callbacks already arrive on ``queue``, so the mirror caches are updated
/// there too. Event delivery is always `queue.async`, never inline, as the seam requires.
public final class LinkCentral: CentralManaging, Sendable {

    /// The queue every request, mirror update, and event delivery is confined to — the same
    /// queue the owning `Central` must be constructed with.
    public let queue: DispatchSerialQueue

    /// The client session this central owns; held strongly for its whole lifetime.
    private let session: LinkClientSession

    nonisolated(unsafe) private var _eventHandler: ((CentralEvent) -> Void)?
    nonisolated(unsafe) private var _radioState: CentralState = .unsupported
    nonisolated(unsafe) private var _didDeliverInitialState = false
    nonisolated(unsafe) private var _peripherals: [UUID: LinkPeripheral] = [:]
    nonisolated(unsafe) private var _nextChannelIdentifier: UInt32 = 1
    nonisolated(unsafe) private var _channels: [UInt32: ChannelEntry] = [:]

    /// One L2CAP channel this central is tunnelling, and the peripheral that owns it — so a
    /// disconnect can tear down exactly that peripheral's channels.
    private struct ChannelEntry {
        let channel: LinkL2CAPChannel
        let peripheral: UUID
    }

    /// Creates a central that drives the provider at `endpoint`, and starts dialing it
    /// immediately. Reconnection is automatic, at `retryInterval`.
    ///
    /// - Parameters:
    ///   - endpoint: The provider's host and port.
    ///   - queue: The serial queue this central is confined to — the same instance the
    ///     owning `Central` is constructed with.
    ///   - clientName: A human-readable name sent in the handshake, for provider-side
    ///     logging. Defaults to the current process's name.
    ///   - codec: The codec used to encode messages. Defaults to
    ///     ``LinkCodec/binaryPropertyList``.
    ///   - retryInterval: How long to wait before redialing after a failure. Defaults to two
    ///     seconds.
    public init(
        endpoint: LinkEndpoint,
        queue: DispatchSerialQueue,
        clientName: String = ProcessInfo.processInfo.processName,
        codec: LinkCodec = .binaryPropertyList,
        retryInterval: Duration = .seconds(2)
    ) {
        self.queue = queue
        self.session = LinkClientSession(
            endpoint: endpoint,
            role: .central,
            clientName: clientName,
            codec: codec,
            queue: queue,
            retryInterval: retryInterval
        )
        // Weak captures: the session is owned by this central, so a strong capture would be a
        // cycle and `deinit` — which stops the session — would never run.
        session.onDisconnected = { [weak self] _ in self?.handleLinkDropped() }
        session.onMessage = { [weak self] message in self?.handle(message) }
        session.start()
    }

    deinit {
        session.stop()
    }

    /// Whether the provider has accepted the handshake and the link is live.
    public var isProviderConnected: Bool {
        session.isConnected
    }

    /// Stops the session and detaches every event handler — this central's and each of its
    /// peripherals'. Idempotent, and safe to call from any thread. Nothing calls it in
    /// production; ``deinit`` stops the session on its own.
    public func shutdown() {
        session.stop()
        queue.async { [self] in
            _eventHandler = nil
            closeChannels(matching: { _ in true }, error: LinkError.providerDisconnected.nsError)
            for peripheral in _peripherals.values {
                peripheral.detachEventHandler()
            }
        }
    }

    // MARK: - CentralManaging

    /// The app's Bluetooth authorization status. Always `.allowedAlways`: authorization is
    /// the provider process's concern, and it would have refused the handshake otherwise.
    public static var bluetoothAuthorization: BluetoothAuthorization { .allowedAlways }

    /// The provider's last reported radio state, or `.unsupported` while no provider is
    /// connected.
    public var radioState: CentralState {
        dispatchPrecondition(condition: .onQueue(queue))
        return _radioState
    }

    /// Receives every `CentralEvent` translated from the provider's wire events.
    ///
    /// Attaching a handler schedules delivery of the current ``radioState`` — mirroring
    /// CoreBluetooth's `centralManagerDidUpdateState(_:)` after a delegate is set, and making
    /// the initial `.unsupported` observable even when the provider is never reachable.
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

    /// Asks the provider to start scanning.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.scan(services: services?.map(\.uuidString), allowDuplicates: options.allowDuplicates))
    }

    /// Asks the provider to stop scanning.
    public func stopScan() {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.stopScan)
    }

    /// Asks the provider to connect to `peripheral`. A peripheral from another shim family is
    /// ignored, as the seam specifies.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let target = peripheral as? LinkPeripheral, _peripherals[target.identifier] === target else { return }
        target.markConnecting()
        send(.connect(peripheral: target.identifier, options: options.map(WireConnectOptions.init), requiresANCS: requiresANCS))
    }

    /// Asks the provider to cancel `peripheral`'s connection or connection attempt. A
    /// peripheral from another shim family is ignored.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let target = peripheral as? LinkPeripheral, _peripherals[target.identifier] === target else { return }
        target.markDisconnecting()
        send(.cancelConnection(peripheral: target.identifier))
    }

    /// Returns this central's peripheral for each identifier, creating a placeholder for one
    /// it has not seen. The same instance is always returned for a given identifier, so a
    /// `Central` that attaches an event handler to a retrieved peripheral is attaching it to
    /// the object the wire events will be routed to.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        dispatchPrecondition(condition: .onQueue(queue))
        return identifiers.map { peripheral(for: $0) }
    }

    /// Every cached peripheral that is currently connected and exposes at least one of
    /// `services` in its mirror cache.
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

    /// Asks the provider to cancel a prior connection-event registration.
    public func unregisterForConnectionEvents() {
        dispatchPrecondition(condition: .onQueue(queue))
        send(.unregisterForConnectionEvents)
    }

    // MARK: - Sending

    /// Sends `request` over the link. The peripherals' one door to the session.
    func send(_ request: CentralRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        session.send(.centralRequest(request))
    }

    /// Allocates the next local L2CAP channel id. Monotonic from 1, so `0` is never a live
    /// channel and can stand in for "no channel" in a failed open.
    func allocateChannelIdentifier() -> UInt32 {
        dispatchPrecondition(condition: .onQueue(queue))
        let identifier = _nextChannelIdentifier
        _nextChannelIdentifier &+= 1
        return identifier
    }

    // MARK: - L2CAP channels

    /// Creates the client half of an L2CAP channel under `identifier` and files it against
    /// `peripheral`, ready for the provider's `didOpenL2CAPChannel` to hand to `Central`.
    /// Called by ``LinkPeripheral/openL2CAPChannel(_:)`` before it sends the open request.
    @discardableResult
    func registerChannel(_ identifier: UInt32, psm: L2CAPPSM, peripheral: UUID) -> LinkL2CAPChannel {
        dispatchPrecondition(condition: .onQueue(queue))
        // The send closure hops onto `queue` — a channel's own methods run wherever its
        // consumer happens to be — and doubles as the deregistration point for a
        // client-initiated close, which the provider answers with no event of its own.
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

    /// Tears down every channel `predicate` selects, reporting `error` on each inbound
    /// stream, and drops them from the table. Must be called on ``queue``.
    private func closeChannels(matching predicate: (ChannelEntry) -> Bool, error: Error?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let doomed = _channels.filter { predicate($0.value) }
        for identifier in doomed.keys { _channels.removeValue(forKey: identifier) }
        for entry in doomed.values { entry.channel.remoteClosed(error: error) }
    }

    // MARK: - Peripheral table

    /// The peripheral for `identifier`, created (and cached) if this central has not seen it.
    private func peripheral(for identifier: UUID, name: String? = nil) -> LinkPeripheral {
        dispatchPrecondition(condition: .onQueue(queue))
        if let existing = _peripherals[identifier] {
            existing.record(name: name)
            return existing
        }
        let created = LinkPeripheral(identifier: identifier, name: name, central: self, queue: queue)
        _peripherals[identifier] = created
        return created
    }

    // MARK: - Link lifecycle

    /// Handles the link dropping after having been established: everything that was connected
    /// is now unreachable, and the radio state is unknowable again.
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

    /// Routes an inbound message; anything that is not a `Central`-role event is not this
    /// client's business.
    private func handle(_ message: LinkMessage) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard case .centralEvent(let event) = message else { return }
        handle(event)
    }

    // MARK: - Wire events

    /// Translates one ``CentralWireEvent`` into mirror-cache updates (applied inline) and the
    /// `CentralEvent`/`PeripheralEvent` it stands for (delivered on the next queue tick).
    private func handle(_ event: CentralWireEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {

        case .didUpdateState(let state):
            // Deliberately does NOT set `_didDeliverInitialState`: a provider state that
            // lands before a handler is attached would otherwise suppress the setter's
            // once-only delivery, leaving `Central.state` stuck at `.unknown` against a
            // perfectly healthy provider. The attach always delivers `_radioState`, which
            // this assignment has already brought up to date.
            _radioState = state.state
            deliver(.didUpdateState(state.state))

        case .didDiscover(let uuid, let name, let advertisement, let rssi):
            let target = peripheral(for: uuid, name: name)
            deliver(.didDiscover(
                peripheral: target.peripheralIdentifier,
                advertisement: advertisement.advertisementData,
                rssi: rssi
            ))

        case .didConnect(let uuid, let name, let maximumWriteWithResponse, let maximumWriteWithoutResponse):
            let target = peripheral(for: uuid)
            target.markConnected(
                name: name,
                maximumWriteWithResponse: maximumWriteWithResponse,
                maximumWriteWithoutResponse: maximumWriteWithoutResponse
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
            let target = peripheral(for: uuid)
            target.replaceServices(services.map { ServiceIdentifier(uuid: $0) })
            target.deliver(.didDiscoverServices(error: error?.nsError))

        case .didDiscoverCharacteristics(let uuid, let service, let characteristics, let error):
            let target = peripheral(for: uuid)
            let serviceIdentifier = ServiceIdentifier(uuid: service)
            var discovered: [CharacteristicIdentifier: CharacteristicProperties] = [:]
            for characteristic in characteristics {
                let identifier = CharacteristicIdentifier(uuid: characteristic.uuid, service: serviceIdentifier)
                discovered[identifier] = CharacteristicProperties(rawValue: characteristic.properties)
            }
            target.replaceCharacteristics(discovered, for: serviceIdentifier)
            target.deliver(.didDiscoverCharacteristics(service: serviceIdentifier, error: error?.nsError))

        case .didDiscoverDescriptors(let uuid, let characteristic, let descriptors, let error):
            let target = peripheral(for: uuid)
            let characteristicIdentifier = characteristic.identifier
            target.replaceDescriptors(
                descriptors.map { DescriptorIdentifier(uuid: $0, characteristic: characteristicIdentifier) },
                for: characteristicIdentifier
            )
            target.deliver(.didDiscoverDescriptors(characteristic: characteristicIdentifier, error: error?.nsError))

        case .didWriteValue(let uuid, let characteristic, let error):
            peripheral(for: uuid).deliver(.didWriteValue(characteristic: characteristic.identifier, error: error?.nsError))

        case .writeWithoutResponseAccepted(let uuid, _):
            let target = peripheral(for: uuid)
            if target.acknowledgeWriteWithoutResponse() {
                target.deliver(.isReadyToSendWriteWithoutResponse)
            }

        case .didUpdateValue(let uuid, let characteristic, let value, let error):
            peripheral(for: uuid).deliver(.didUpdateValue(
                characteristic: characteristic.identifier,
                value: value,
                error: error?.nsError
            ))

        case .didUpdateNotificationState(let uuid, let characteristic, let isNotifying, let error):
            let target = peripheral(for: uuid)
            let identifier = characteristic.identifier
            target.setNotifying(isNotifying, for: identifier)
            target.deliver(.didUpdateNotificationState(characteristic: identifier, isNotifying: isNotifying, error: error?.nsError))

        case .didUpdateValueForDescriptor(let uuid, let descriptor, let value, let error):
            peripheral(for: uuid).deliver(.didUpdateValueForDescriptor(
                descriptor: descriptor.identifier,
                value: value,
                error: error?.nsError
            ))

        case .didWriteValueForDescriptor(let uuid, let descriptor, let error):
            peripheral(for: uuid).deliver(.didWriteValueForDescriptor(descriptor: descriptor.identifier, error: error?.nsError))

        case .didReadRSSI(let uuid, let rssi, let error):
            peripheral(for: uuid).deliver(.didReadRSSI(rssi, error: error?.nsError))

        case .didModifyServices(let uuid, let invalidated):
            let target = peripheral(for: uuid)
            let services = invalidated.map { ServiceIdentifier(uuid: $0) }
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
                // The provider opened a channel this central has no record of — its half is
                // live and would otherwise be pumped forever, so close it explicitly.
                send(.l2capClose(channel: identifier))
                target.deliver(.didOpenL2CAPChannel(channel: nil, error: Self.unknownChannelError))
                return
            }
            target.deliver(.didOpenL2CAPChannel(channel: entry.channel, error: nil))

        case .l2capData(let identifier, let data):
            _channels[identifier]?.channel.receive(data)

        case .l2capCredit(let identifier, let bytes):
            _channels[identifier]?.channel.addCredit(bytes: bytes)

        case .l2capClosed(let identifier, let error):
            guard let entry = _channels.removeValue(forKey: identifier) else { return }
            entry.channel.remoteClosed(error: error?.nsError)
        }
    }

    /// The error a successful-looking open reports when this central has no channel filed
    /// under the id the provider named — a protocol violation, not something a caller can
    /// act on.
    private static let unknownChannelError = NSError(
        domain: LinkError.domain,
        code: 101,
        userInfo: [NSLocalizedDescriptionKey: "The provider reported an L2CAP channel this central never opened"]
    )

    /// The error open channels are torn down with when their peripheral disconnects without
    /// one of its own.
    private static let disconnectedError = NSError(
        domain: LinkError.domain,
        code: 102,
        userInfo: [NSLocalizedDescriptionKey: "The peripheral disconnected, closing its L2CAP channels"]
    )

    /// Delivers `event` to ``eventHandler`` asynchronously on ``queue``, honoring the seam's
    /// never-inline delivery contract.
    private func deliver(_ event: CentralEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.async { [self] in
            _eventHandler?(event)
        }
    }
}
