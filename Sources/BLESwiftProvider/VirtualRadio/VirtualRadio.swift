//
//  VirtualRadio.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Foundation
import Logging
import Synchronization

/// An in-process BLE radio hosting ``VirtualDevice``s and serving them to any number of
/// ``VirtualCentralBackend``s — fixture devices and simulator-to-simulator BLE with no
/// hardware involved.
///
/// The radio owns every piece of shared state: the registered devices, each backend's
/// scanner, its connections, and its notification subscriptions. Backends are queue-confined
/// classes that call in with `await` and deliver results back on their own queue, so no
/// CoreBluetooth-shaped delivery contract is ever violated.
///
/// ```swift
/// let radio = VirtualRadio()
/// let (device, handler) = VirtualDevice.fixture(fixtureDevice)
/// let handle = await radio.register(device)
/// await handler.attach(handle)
/// let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
/// ```
public actor VirtualRadio {

    /// The RSSI every sighting and `PeripheralRemote.readRSSI()` reports.
    /// Virtual devices have no radio distance, so a single plausible value stands in.
    public static let rssi = -50

    /// The MTU-derived length reported for notifications and writes. 512 is the maximum
    /// ATT attribute length, the natural ceiling for a link with no real MTU negotiation.
    public static let maximumValueLength = 512

    /// How long a GATT request parked for a hosted `PeripheralHost` waits for that host's
    /// answer before it is refused with `ATTError.unlikelyError`.
    ///
    /// A host that never responds — one wedged in its own request handler, or a link client
    /// that stopped answering — would otherwise leave the central's read or write suspended
    /// forever, and with it every later operation queued behind it on that remote. Thirty
    /// seconds is the ATT transaction timeout Bluetooth Core specifies, so a virtual radio
    /// gives up on the same schedule real hardware does.
    public static let attTimeout = Duration.seconds(30)

    /// The error a connection attempt to an unregistered device fails with.
    public static var unknownDeviceError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No virtual device is registered with that identifier."]
        )
    }

    /// The error a connected central is disconnected with when its device is removed.
    public static var deviceRemovedError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The virtual device was removed from the radio."]
        )
    }

    /// How often a duplicate-allowing scanner re-reports every matching device.
    private static let duplicateInterval = Duration.seconds(1)

    /// Where the radio reports a mutation refused because its handle is stale. Nothing else
    /// in the radio logs: this is the one event that is silently *not* what its caller asked
    /// for, and a session teardown that quietly did nothing is worth a line.
    private static let logger = Logger(label: "BLESwiftProvider.VirtualRadio")

    /// One registered device: its description, whether it is currently advertising, and which
    /// registration of its identifier it belongs to.
    private struct DeviceState {
        var descriptor: VirtualDeviceDescriptor
        let handler: any VirtualDeviceHandler
        var isAdvertising: Bool
        /// The generation ``register(_:advertising:)`` stamped this registration with. A
        /// handle from an earlier registration of the same identifier carries an older one
        /// and is refused. See ``VirtualDeviceHandle/generation``.
        let generation: UInt64
    }

    /// One backend's active scan.
    private struct Scanner {
        var services: [ServiceIdentifier]?
        var repeater: Task<Void, Never>?
    }

    /// Everything the radio holds on behalf of one attached backend.
    private struct Session {
        let centralSink: @Sendable (CentralEvent) -> Void
        var peripheralSinks: [UUID: @Sendable (PeripheralEvent) -> Void] = [:]
        var scanner: Scanner?
        var connections: Set<UUID> = []
    }

    private var devices: [UUID: DeviceState] = [:]
    private var sessions: [UUID: Session] = [:]

    /// Stamps every registration, so a handle can be told from one the same identifier was
    /// re-registered under since. Monotonic across the radio — nothing reads it as a count,
    /// only as an identity — and never reused.
    private var lastGeneration: UInt64 = 0

    /// The identifiers this radio currently has devices registered for, readable without
    /// awaiting the actor.
    ///
    /// A backend has to answer `retrievePeripherals(withIdentifiers:)` **synchronously**, on
    /// its own queue, so it cannot ask the radio. Pushing a snapshot to it instead was the
    /// obvious alternative and the wrong one: the push costs an actor hop plus a queue hop, so
    /// a client that registers a device and connects to it in the same synchronous flow — the
    /// provider's own sessions do exactly that — could look the identifier up before the
    /// snapshot arrived and be told no such device exists. This is the same set, written
    /// inside ``register(_:advertising:)`` and the removal path before either returns, so a
    /// registration is visible to every backend the instant it has happened.
    public nonisolated let knownDeviceIDs = Mutex<Set<UUID>>([])

    /// Notification subscriptions, keyed by device, then characteristic, to the set of
    /// session identifiers currently subscribed.
    private var subscriptions: [UUID: [CharacteristicIdentifier: Set<UUID>]] = [:]

    /// Creates an empty radio.
    public init() {}

    // MARK: - Devices

    /// Registers `device`, making it visible to every backend this radio serves.
    ///
    /// - Parameters:
    ///   - device: The device to host.
    ///   - advertising: Whether it starts out advertising. Defaults to `true`.
    /// - Returns: A ``VirtualDeviceHandle`` for pushing notifications and mutating the
    ///   device after registration.
    @discardableResult
    public func register(_ device: VirtualDevice, advertising: Bool = true) -> VirtualDeviceHandle {
        let identifier = device.descriptor.identifier
        lastGeneration += 1
        let generation = lastGeneration
        devices[identifier] = DeviceState(
            descriptor: device.descriptor,
            handler: device.handler,
            isAdvertising: advertising,
            generation: generation
        )
        knownDeviceIDs.withLock { (known: inout Set<UUID>) -> Void in
            known.insert(identifier)
        }
        if advertising {
            reportSightings(of: identifier)
        }
        return VirtualDeviceHandle(identifier: identifier, generation: generation, radio: self)
    }

    /// Whether the device registered under `device` is the one `generation` was handed out
    /// for. Must be checked by every mutation a ``VirtualDeviceHandle`` performs.
    ///
    /// A registration replaces any earlier one for the same identifier — which is exactly what
    /// a link client redialing under a stable `hostIdentifier` produces — and the session it
    /// replaced tears itself down asynchronously afterwards. Keyed by identifier alone, that
    /// teardown's `remove`, `stopAdvertising`, and `removeAllHostedServices` would land on the
    /// *new* session's device: the reconnect would come up registered, then be unregistered,
    /// unadvertised, or emptied a moment later by a session that no longer exists. The
    /// generation is what tells the two apart.
    private func isCurrent(_ device: UUID, generation: UInt64, operation: String) -> Bool {
        guard let state = devices[device] else { return false }
        guard state.generation == generation else {
            Self.logger.debug(
                """
                Ignoring \(operation) from a stale handle for device \(device): \
                generation \(generation), current \(state.generation)
                """
            )
            return false
        }
        return true
    }

    /// The generation currently registered under `device`, or `nil` if nothing is.
    ///
    /// Not API: it exists so a test can act on a device through the radio when the
    /// ``VirtualDeviceHandle`` for it belongs to the backend that registered it.
    package func generation(of device: UUID) -> UInt64? {
        devices[device]?.generation
    }

    /// The name of a registered device, or `nil` if it is unknown or unnamed.
    ///
    /// - Parameter device: The device's identifier.
    /// - Returns: The device's name.
    public func name(of device: UUID) -> String? {
        devices[device]?.descriptor.name
    }

    /// Starts or stops advertising for a registered device. See
    /// ``VirtualDeviceHandle/setAdvertising(_:)``.
    func setAdvertising(_ advertising: Bool, device: UUID, generation: UInt64) {
        guard isCurrent(device, generation: generation, operation: "setAdvertising") else { return }
        guard devices[device]?.isAdvertising != advertising else { return }
        devices[device]?.isAdvertising = advertising
        if advertising {
            reportSightings(of: device)
        }
    }

    /// Replaces a registered device's advertisement. See
    /// ``VirtualDeviceHandle/setAdvertisement(_:)``.
    ///
    /// A non-`nil` ``BLESwiftCore/AdvertisementData/localName`` also becomes the device's
    /// ``VirtualDeviceDescriptor/name``, which is CoreBluetooth's behavior: a `CBPeripheral`
    /// discovered from an advertisement carrying a local name reports that name, so a
    /// `PeripheralHost` that advertises under a local name is seen under it. An advertisement
    /// without a local name leaves the existing name alone.
    func setAdvertisement(_ advertisement: AdvertisementData, device: UUID, generation: UInt64) {
        guard isCurrent(device, generation: generation, operation: "setAdvertisement") else { return }
        devices[device]?.descriptor.advertisement = advertisement
        if let localName = advertisement.localName {
            devices[device]?.descriptor.name = localName
        }
    }

    /// Replaces a registered device's GATT database. See
    /// ``VirtualDeviceHandle/setServices(_:)``.
    ///
    /// A service the new database drops is reported to every connected session as
    /// `PeripheralEvent.didModifyServices`, carrying the invalidated services —
    /// CoreBluetooth's `peripheral(_:didModifyServices:)`, which is how a central learns that
    /// handles it discovered are gone and must be discovered again. Nothing is reported for a
    /// database that only gained services: CoreBluetooth's callback names what was
    /// *invalidated*, and a purely additive change invalidates nothing.
    ///
    /// **A subscription under an invalidated service goes with it**, and is reported to the
    /// device's handler as an unsubscribe, exactly as ``disconnect(session:device:)`` and
    /// ``remove(device:generation:)`` report theirs — CoreBluetooth delivers
    /// `didUnsubscribeFrom` when a published service is removed. Left standing, the entry was
    /// a subscriber a link-hosted `PeripheralHost` could never lose, and it also poisoned
    /// re-subscription: re-adding the service and subscribing again found the session already
    /// in the set, so no transition was reported and the host — which starts notifying on
    /// `didSubscribe` — was never told, while the central sat waiting on a stream that reported
    /// itself armed.
    func setServices(_ services: [GATTService], device: UUID, generation: UInt64) async {
        guard isCurrent(device, generation: generation, operation: "setServices") else { return }
        let before = Set(devices[device]?.descriptor.services.map(\.identifier) ?? [])
        devices[device]?.descriptor.services = services
        let invalidated = before.subtracting(services.map(\.identifier))
        guard !invalidated.isEmpty else { return }
        var dropped: [(session: UUID, characteristics: [CharacteristicIdentifier])] = []
        for (sessionID, session) in sessions where session.connections.contains(device) {
            session.peripheralSinks[device]?(.didModifyServices(Array(invalidated)))
            dropped.append((sessionID, dropSubscriptions(session: sessionID, device: device, under: invalidated)))
        }
        // Every table is settled before the first `await`, as in ``detach(session:)``, so a
        // handler that calls back into the radio cannot observe a half-applied database.
        for entry in dropped {
            await reportUnsubscribed(entry.characteristics, device: device, session: entry.session)
        }
    }

    /// Removes a registered device, disconnecting every central attached to it. See
    /// ``VirtualDeviceHandle/remove()``.
    ///
    /// Every subscription the device still had is reported to its handler as an
    /// unsubscribe before the device goes, so a hosted `PeripheralHost` is left holding no
    /// subscriber it can never notify again — CoreBluetooth reports `didUnsubscribe` when a
    /// subscribed central goes away, and so does this radio.
    func remove(device: UUID, generation: UInt64) async {
        guard isCurrent(device, generation: generation, operation: "remove") else { return }
        guard let state = devices.removeValue(forKey: device) else { return }
        let departing = subscriptions.removeValue(forKey: device) ?? [:]
        knownDeviceIDs.withLock { (known: inout Set<UUID>) -> Void in
            known.remove(device)
        }
        let identifier = PeripheralIdentifier(uuid: device, name: state.descriptor.name)
        for sessionID in Array(sessions.keys) {
            // Dropped for every session, connected or not: the sink routes events *from* this
            // device, and there is no longer a device to route them from. A live entry would
            // outlive the device and keep its backend's remote alive with it.
            sessions[sessionID]?.peripheralSinks.removeValue(forKey: device)
            guard sessions[sessionID]?.connections.contains(device) == true else { continue }
            sessions[sessionID]?.connections.remove(device)
            sessions[sessionID]?.centralSink(.didDisconnect(identifier, error: Self.deviceRemovedError))
        }
        for (characteristic, subscribers) in departing {
            for sessionID in subscribers {
                await state.handler.subscriptionChanged(characteristic, central: subscriber(sessionID), isSubscribed: false)
            }
        }
    }

    /// Pushes a notification to every subscribed, connected central. See
    /// ``VirtualDeviceHandle/notify(_:for:to:)``.
    func notify(
        device: UUID,
        characteristic: CharacteristicIdentifier,
        value: Data,
        to centrals: [Subscriber]?,
        generation: UInt64
    ) {
        guard isCurrent(device, generation: generation, operation: "notify") else { return }
        let allowed = centrals.map { Set($0.map(\.id)) }
        let subscribers = subscriptions[device]?[characteristic] ?? []
        for sessionID in subscribers {
            if let allowed, !allowed.contains(sessionID) { continue }
            guard let session = sessions[sessionID], session.connections.contains(device) else { continue }
            session.peripheralSinks[device]?(.didUpdateValue(characteristic: characteristic, value: value, error: nil))
        }
    }

    // MARK: - Backend attachment

    /// Attaches a backend under `session`, routing radio-initiated ``BLESwiftCore/CentralEvent``s
    /// to `centralSink`, which is responsible for hopping onto the backend's queue.
    ///
    /// Which identifiers a backend may vend a remote for is *not* pushed here: it reads
    /// ``knownDeviceIDs`` live, so a device registered a moment ago is retrievable without
    /// waiting on this actor. See ``knownDeviceIDs``.
    func attach(
        session: UUID,
        centralSink: @escaping @Sendable (CentralEvent) -> Void
    ) {
        sessions[session] = Session(centralSink: centralSink)
    }

    /// Detaches a backend, cancelling its scan and dropping its connections, its per-device
    /// sinks — the whole session record goes — and its subscriptions. Each dropped
    /// subscription is reported to its device's handler as an unsubscribe.
    func detach(session: UUID) async {
        guard let removed = sessions.removeValue(forKey: session) else { return }
        removed.scanner?.repeater?.cancel()
        var dropped: [(device: UUID, characteristics: [CharacteristicIdentifier])] = []
        for device in removed.connections {
            dropped.append((device, dropSubscriptions(session: session, device: device)))
        }
        // Every table is settled before the first `await`, so a handler that calls back into
        // the radio cannot observe a half-detached session.
        for entry in dropped {
            await reportUnsubscribed(entry.characteristics, device: entry.device, session: session)
        }
    }

    // MARK: - Scanning

    /// Starts a scan for `session`, reporting one sighting per matching advertising device
    /// immediately and, when `allowDuplicates` is set, once per second thereafter.
    func startScan(session: UUID, services: [ServiceIdentifier]?, allowDuplicates: Bool) {
        guard sessions[session] != nil else { return }
        sessions[session]?.scanner?.repeater?.cancel()
        sessions[session]?.scanner = Scanner(services: services, repeater: nil)
        emitSightings(for: session)
        guard allowDuplicates else { return }
        let repeater = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.duplicateInterval)
                guard !Task.isCancelled else { return }
                await self?.emitSightings(for: session)
            }
        }
        sessions[session]?.scanner?.repeater = repeater
    }

    /// Whether `session` currently has a scanner installed.
    ///
    /// Not API: it exists so a test can assert that a scan and the `stopScan` right behind it
    /// left nothing running.
    package func hasScanner(session: UUID) -> Bool {
        sessions[session]?.scanner != nil
    }

    /// How many sessions are subscribed to `characteristic` on `device`.
    ///
    /// Not API: it exists so a test can assert that a refused ``setNotify(_:device:characteristic:session:)``
    /// left no entry behind, and that a ``detach(session:)`` cleared the ones there were.
    package func subscriberCount(device: UUID, characteristic: CharacteristicIdentifier) -> Int {
        subscriptions[device]?[characteristic]?.count ?? 0
    }

    /// Whether `characteristic` currently has a subscriber — `session` when one is named, any
    /// session otherwise, on any device this radio hosts.
    ///
    /// Not API: it is the "notifications are armed" signal a test waits on. A `Central`
    /// publishes no such signal of its own, so tests stood a fixed delay in for one and a
    /// starved runner could pass the delay with nothing yet subscribed — the notifications
    /// that followed then had no subscriber to reach. This is the state the push itself
    /// consults, so a wait on it cannot be early.
    package func isSubscribed(session: UUID? = nil, characteristic: CharacteristicIdentifier) -> Bool {
        for perCharacteristic in subscriptions.values {
            guard let subscribers = perCharacteristic[characteristic] else { continue }
            guard let session else {
                if !subscribers.isEmpty { return true }
                continue
            }
            if subscribers.contains(session) { return true }
        }
        return false
    }

    /// Stops `session`'s scan, if any.
    func stopScan(session: UUID) {
        sessions[session]?.scanner?.repeater?.cancel()
        sessions[session]?.scanner = nil
    }

    /// Reports every advertising device matching `session`'s scan filter, once.
    func emitSightings(for session: UUID) {
        guard let state = sessions[session], let scanner = state.scanner else { return }
        for device in devices.values where device.isAdvertising && matches(scanner.services, device) {
            state.centralSink(sighting(of: device))
        }
    }

    /// Reports one device to every active scanner whose filter it matches — used when a
    /// device starts advertising after a scan is already running.
    private func reportSightings(of device: UUID) {
        guard let state = devices[device] else { return }
        for session in sessions.values {
            guard let scanner = session.scanner, matches(scanner.services, state) else { continue }
            session.centralSink(sighting(of: state))
        }
    }

    /// The discovery event for one device.
    private func sighting(of device: DeviceState) -> CentralEvent {
        .didDiscover(
            peripheral: PeripheralIdentifier(uuid: device.descriptor.identifier, name: device.descriptor.name),
            advertisement: device.descriptor.advertisement,
            rssi: Self.rssi
        )
    }

    /// Whether a device's advertisement satisfies a scan's service filter. A `nil` or empty
    /// filter matches every device, mirroring CoreBluetooth.
    private func matches(_ services: [ServiceIdentifier]?, _ device: DeviceState) -> Bool {
        guard let services, !services.isEmpty else { return true }
        let advertised = Set(device.descriptor.advertisement.serviceUUIDs ?? [])
        return !advertised.isDisjoint(with: services)
    }

    // MARK: - Connections

    /// Connects `session` to `device`, routing that device's radio-initiated
    /// ``BLESwiftCore/PeripheralEvent``s to `sink` (which is responsible for hopping onto
    /// the backend's queue). Registering the sink as part of the connection is what keeps a
    /// notification from ever outrunning its own delivery path.
    ///
    /// The device's name is answered here rather than left to a second
    /// ``name(of:)`` hop: the device could be removed between the two, and the connection that
    /// just succeeded would then be named `nil`.
    ///
    /// - Returns: The error to fail the attempt with, or the connected device's name on
    ///   success — both `nil` when the connection succeeded to an unnamed device.
    func connect(
        session: UUID,
        device: UUID,
        sink: @escaping @Sendable (PeripheralEvent) -> Void
    ) -> (error: NSError?, name: String?) {
        guard sessions[session] != nil else { return (Self.unknownDeviceError, nil) }
        guard let state = devices[device] else { return (Self.unknownDeviceError, nil) }
        sessions[session]?.peripheralSinks[device] = sink
        sessions[session]?.connections.insert(device)
        return (nil, state.descriptor.name)
    }

    /// Disconnects `session` from `device`, dropping its subscriptions and reporting each of
    /// them to the device's handler as an unsubscribe. The backend delivers the resulting
    /// `didDisconnect` itself, mirroring CoreBluetooth's `cancelPeripheralConnection(_:)`.
    func disconnect(session: UUID, device: UUID) async {
        sessions[session]?.connections.remove(device)
        // Goes with the connection: the sink was registered by ``connect(session:device:sink:)``
        // and the backend delivers the `didDisconnect` itself, so nothing is left to route
        // through it.
        sessions[session]?.peripheralSinks.removeValue(forKey: device)
        let dropped = dropSubscriptions(session: session, device: device)
        await reportUnsubscribed(dropped, device: device, session: session)
    }

    /// Removes every subscription `session` holds on `device` — or, when `services` is given,
    /// only those under one of those services.
    ///
    /// - Returns: The characteristics `session` really was subscribed to, so exactly those —
    ///   and no others — are reported to the device's handler.
    private func dropSubscriptions(
        session: UUID,
        device: UUID,
        under services: Set<ServiceIdentifier>? = nil
    ) -> [CharacteristicIdentifier] {
        guard var perCharacteristic = subscriptions[device] else { return [] }
        var dropped: [CharacteristicIdentifier] = []
        for characteristic in Array(perCharacteristic.keys) {
            if let services, !services.contains(characteristic.service) { continue }
            guard perCharacteristic[characteristic]?.remove(session) != nil else { continue }
            dropped.append(characteristic)
            if perCharacteristic[characteristic]?.isEmpty == true {
                perCharacteristic.removeValue(forKey: characteristic)
            }
        }
        subscriptions[device] = perCharacteristic.isEmpty ? nil : perCharacteristic
        return dropped
    }

    /// Tells `device`'s handler that `session` is no longer subscribed to `characteristics`.
    ///
    /// This is what keeps a hosted `PeripheralHost` — fixture, code-defined, or link-hosted —
    /// from holding a ghost subscriber after the central behind it disconnected, cancelled,
    /// or had its backend detached. CoreBluetooth reports `didUnsubscribe` in exactly those
    /// cases.
    private func reportUnsubscribed(
        _ characteristics: [CharacteristicIdentifier],
        device: UUID,
        session: UUID
    ) async {
        guard !characteristics.isEmpty, let handler = devices[device]?.handler else { return }
        let central = subscriber(session)
        for characteristic in characteristics {
            await handler.subscriptionChanged(characteristic, central: central, isSubscribed: false)
        }
    }

    // MARK: - GATT

    /// The services of `device` matching `filter` (every service when `filter` is `nil`).
    func services(of device: UUID, matching filter: [ServiceIdentifier]?) -> [ServiceIdentifier] {
        guard let state = devices[device] else { return [] }
        let identifiers = state.descriptor.services.map(\.identifier)
        guard let filter else { return identifiers }
        let requested = Set(filter)
        return identifiers.filter { requested.contains($0) }
    }

    /// The characteristics of `service` on `device` matching `filter`, paired with the
    /// properties each advertises.
    func characteristics(
        of device: UUID,
        service: ServiceIdentifier,
        matching filter: [CharacteristicIdentifier]?
    ) -> [CharacteristicDiscovery] {
        guard let state = devices[device],
              let match = state.descriptor.services.first(where: { $0.identifier == service })
        else { return [] }
        let requested = filter.map(Set.init)
        return match.characteristics
            .filter { requested?.contains($0.identifier) ?? true }
            .map { CharacteristicDiscovery(identifier: $0.identifier, properties: $0.properties) }
    }

    /// Whether `session` currently holds a connection to `device`.
    ///
    /// The gate every GATT entry point applies, and the same test ``notify(device:characteristic:value:to:)``
    /// makes before routing a notification: a session that has disconnected — or was never
    /// connected at all — has no ATT bearer to carry a request over, so the radio must refuse
    /// rather than serve it. Without it a stale remote could still read, write, and plant a
    /// subscription that no ``disconnect(session:device:)`` or ``detach(session:)`` would ever
    /// clean up, because neither walks a device the session is not recorded as connected to.
    private func isConnected(session: UUID, to device: UUID) -> Bool {
        sessions[session]?.connections.contains(device) == true
    }

    /// Reads `characteristic` from `offset` on. A characteristic with a static value is
    /// answered from the database; every other read reaches the device's handler. A session
    /// that is not connected to `device` is refused with `ATTError.invalidHandle`, a
    /// characteristic declaring none of `read`, `notify`, or `indicate` with
    /// `ATTError.readNotPermitted`, and an `offset` past the end of a static value with
    /// `ATTError.invalidOffset`.
    ///
    /// **The permission check comes before the static short-circuit.** A characteristic the
    /// fixture gave a value is answered from the database rather than through its handler, so
    /// a check made only in the handler — which is where ``FixtureDeviceHandler`` makes it —
    /// would let exactly the write-only characteristics that declare a value be read by any
    /// connected central. Real hardware refuses that read at the ATT layer, and so does this
    /// radio, whatever the value behind the handle.
    func read(
        device: UUID,
        characteristic: CharacteristicIdentifier,
        offset: Int = 0,
        session: UUID
    ) async -> Result<Data, ATTError> {
        guard isConnected(session: session, to: device) else { return .failure(.invalidHandle) }
        guard let state = devices[device] else { return .failure(.invalidHandle) }
        guard let definition = definition(of: characteristic, in: state) else { return .failure(.attributeNotFound) }
        guard definition.properties.contains(.read) || definition.properties.isNotifiable else {
            return .failure(.readNotPermitted)
        }
        if let value = definition.value {
            guard offset >= 0, offset <= value.count else { return .failure(.invalidOffset) }
            return .success(Data(value.dropFirst(offset)))
        }
        return await state.handler.read(characteristic, offset: offset, from: subscriber(session))
    }

    /// Writes `value` to `characteristic` through the device's handler. A session that is not
    /// connected to `device` is refused with `ATTError.invalidHandle`, a characteristic
    /// declaring neither `write` nor `writeWithoutResponse` with `ATTError.writeNotPermitted`.
    ///
    /// **The permission check is the radio's, not the handler's.** It mirrors the one
    /// ``read(device:characteristic:offset:session:)`` makes, and for the same reason: a
    /// hosted device — a remote `PeripheralHost` at the far end of a link — has no
    /// ``FixtureDeviceHandler`` to refuse for it, so a write to a read-only characteristic
    /// reached its `didReceiveWrite` and was served. Real hardware refuses that write at the
    /// ATT layer, before any of it reaches the peripheral's application code, and so does this
    /// radio, whatever the device behind the handle is.
    func write(
        device: UUID,
        characteristic: CharacteristicIdentifier,
        value: Data,
        session: UUID
    ) async -> Result<Void, ATTError> {
        guard isConnected(session: session, to: device) else { return .failure(.invalidHandle) }
        guard let state = devices[device] else { return .failure(.invalidHandle) }
        guard let definition = definition(of: characteristic, in: state) else { return .failure(.attributeNotFound) }
        guard definition.properties.isWritable else { return .failure(.writeNotPermitted) }
        let central = subscriber(session)
        let entry = WriteRequest.Entry(central: central, characteristic: characteristic, offset: 0, value: value)
        return await state.handler.write([entry], from: central)
    }

    /// Subscribes or unsubscribes `session` to `characteristic` and reports the change to
    /// the device's handler.
    ///
    /// A session that is not connected to `device` changes nothing and tells the handler
    /// nothing: a subscription planted from a disconnected session would be a ghost subscriber
    /// its `PeripheralHost` could never lose, since neither ``disconnect(session:device:)`` nor
    /// ``detach(session:)`` walks a device the session has no connection to.
    ///
    /// **Only a real membership transition is reported.** A repeated `setNotifyValue(true)` —
    /// which CoreBluetooth permits, and which a `Central` re-arming a stream makes — would
    /// otherwise hand the host a second `didSubscribe` for a subscriber it already has, and a
    /// `setNotifyValue(false)` for a characteristic that was never subscribed would hand it a
    /// `didUnsubscribe` for a subscriber it never had. The set decides: the handler hears from
    /// this call only when the session really joined or really left.
    ///
    /// **The permission check is the radio's, not the handler's.** It mirrors the ones
    /// ``read(device:characteristic:offset:session:)`` and
    /// ``write(device:characteristic:value:session:)`` make, and for the same reason:
    /// subscribing is a write to the characteristic's Client Characteristic Configuration
    /// descriptor, and a characteristic declaring neither `notify` nor `indicate` has no such
    /// descriptor for real hardware to accept that write on. A hosted device — a remote
    /// `PeripheralHost` at the far end of a link — has no ``FixtureDeviceHandler`` to refuse
    /// for it, so a `setNotifyValue(true)` on a read/write-only characteristic recorded a
    /// subscription and handed the host a `didSubscribe` no hardware would ever have produced.
    /// A characteristic that is not in the database at all is refused the same way `read` and
    /// `write` refuse it, with `ATTError.attributeNotFound`.
    ///
    /// - Returns: Whether `session` is subscribed to `characteristic` now the call has been
    ///   applied — `enabled` for a connected session, and the unchanged current state for one
    ///   that is not or for a request the checks above refused — together with the `ATTError`
    ///   to fail the request with, or `nil` when it was applied.
    @discardableResult
    func setNotify(
        _ enabled: Bool,
        device: UUID,
        characteristic: CharacteristicIdentifier,
        session: UUID
    ) async -> (isNotifying: Bool, error: ATTError?) {
        let unchanged = subscriptions[device]?[characteristic]?.contains(session) == true
        guard let state = devices[device], isConnected(session: session, to: device) else {
            return (unchanged, nil)
        }
        guard let definition = definition(of: characteristic, in: state) else {
            return (unchanged, .attributeNotFound)
        }
        guard definition.properties.isNotifiable else {
            return (unchanged, .requestNotSupported)
        }
        let didChange: Bool
        if enabled {
            didChange = subscriptions[device, default: [:]][characteristic, default: []].insert(session).inserted
        } else {
            didChange = subscriptions[device]?[characteristic]?.remove(session) != nil
            if subscriptions[device]?[characteristic]?.isEmpty == true {
                subscriptions[device]?.removeValue(forKey: characteristic)
                if subscriptions[device]?.isEmpty == true {
                    subscriptions.removeValue(forKey: device)
                }
            }
        }
        guard didChange else { return (enabled, nil) }
        await state.handler.subscriptionChanged(characteristic, central: subscriber(session), isSubscribed: enabled)
        return (enabled, nil)
    }

    /// The characteristic definition for `characteristic` in `state`'s current database.
    private func definition(of characteristic: CharacteristicIdentifier, in state: DeviceState) -> GATTCharacteristic? {
        state.descriptor.services
            .first { $0.identifier == characteristic.service }?
            .characteristics
            .first { $0.identifier == characteristic }
    }

    /// The ``BLESwiftCore/Subscriber`` a backend session appears as to device handlers.
    private func subscriber(_ session: UUID) -> Subscriber {
        Subscriber(id: session, maximumUpdateValueLength: Self.maximumValueLength)
    }
}

/// One characteristic revealed by discovery: its identifier and the properties it
/// advertises.
struct CharacteristicDiscovery: Sendable {

    /// The characteristic's identifier.
    let identifier: CharacteristicIdentifier

    /// The operations the characteristic advertises support for.
    let properties: CharacteristicProperties
}
#endif
