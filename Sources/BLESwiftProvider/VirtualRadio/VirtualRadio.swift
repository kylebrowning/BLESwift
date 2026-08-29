//
//  VirtualRadio.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import Foundation
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

    /// One registered device: its description and whether it is currently advertising.
    private struct DeviceState {
        var descriptor: VirtualDeviceDescriptor
        let handler: any VirtualDeviceHandler
        var isAdvertising: Bool
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

    /// The identifiers ``devices`` currently holds, readable without awaiting the actor.
    ///
    /// A backend has to answer `retrievePeripherals(withIdentifiers:)` **synchronously**, on
    /// its own queue, so it cannot ask the radio. Pushing a snapshot to it instead was the
    /// obvious alternative and the wrong one: the push costs an actor hop plus a queue hop, so
    /// a client that registers a device and connects to it in the same synchronous flow — the
    /// provider's own sessions do exactly that — could look the identifier up before the
    /// snapshot arrived and be told no such device exists. This is the same set, written
    /// inside ``register(_:advertising:)`` and ``remove(device:)`` before either returns, so a
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
        devices[identifier] = DeviceState(
            descriptor: device.descriptor,
            handler: device.handler,
            isAdvertising: advertising
        )
        knownDeviceIDs.withLock { (known: inout Set<UUID>) -> Void in
            known.insert(identifier)
        }
        if advertising {
            reportSightings(of: identifier)
        }
        return VirtualDeviceHandle(identifier: identifier, radio: self)
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
    func setAdvertising(_ advertising: Bool, device: UUID) {
        guard devices[device] != nil, devices[device]?.isAdvertising != advertising else { return }
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
    func setAdvertisement(_ advertisement: AdvertisementData, device: UUID) {
        devices[device]?.descriptor.advertisement = advertisement
        if let localName = advertisement.localName {
            devices[device]?.descriptor.name = localName
        }
    }

    /// Replaces a registered device's GATT database. See
    /// ``VirtualDeviceHandle/setServices(_:)``.
    func setServices(_ services: [GATTService], device: UUID) {
        devices[device]?.descriptor.services = services
    }

    /// Removes a registered device, disconnecting every central attached to it. See
    /// ``VirtualDeviceHandle/remove()``.
    func remove(device: UUID) {
        guard let state = devices.removeValue(forKey: device) else { return }
        subscriptions.removeValue(forKey: device)
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
    }

    /// Pushes a notification to every subscribed, connected central. See
    /// ``VirtualDeviceHandle/notify(_:for:to:)``.
    func notify(device: UUID, characteristic: CharacteristicIdentifier, value: Data, to centrals: [Subscriber]?) {
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
    /// sinks — the whole session record goes — and its subscriptions.
    func detach(session: UUID) {
        guard let removed = sessions.removeValue(forKey: session) else { return }
        removed.scanner?.repeater?.cancel()
        for device in removed.connections {
            dropSubscriptions(session: session, device: device)
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

    /// Disconnects `session` from `device`, dropping its subscriptions. The backend
    /// delivers the resulting `didDisconnect` itself, mirroring CoreBluetooth's
    /// `cancelPeripheralConnection(_:)`.
    func disconnect(session: UUID, device: UUID) {
        sessions[session]?.connections.remove(device)
        // Goes with the connection: the sink was registered by ``connect(session:device:sink:)``
        // and the backend delivers the `didDisconnect` itself, so nothing is left to route
        // through it.
        sessions[session]?.peripheralSinks.removeValue(forKey: device)
        dropSubscriptions(session: session, device: device)
    }

    /// Removes every subscription `session` holds on `device`.
    private func dropSubscriptions(session: UUID, device: UUID) {
        guard var perCharacteristic = subscriptions[device] else { return }
        for characteristic in Array(perCharacteristic.keys) {
            perCharacteristic[characteristic]?.remove(session)
            if perCharacteristic[characteristic]?.isEmpty == true {
                perCharacteristic.removeValue(forKey: characteristic)
            }
        }
        subscriptions[device] = perCharacteristic.isEmpty ? nil : perCharacteristic
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

    /// Reads `characteristic`. A characteristic with a static value is answered from the
    /// database; every other read reaches the device's handler.
    func read(device: UUID, characteristic: CharacteristicIdentifier, session: UUID) async -> Result<Data, ATTError> {
        guard let state = devices[device] else { return .failure(.invalidHandle) }
        guard let definition = definition(of: characteristic, in: state) else { return .failure(.attributeNotFound) }
        if let value = definition.value { return .success(value) }
        return await state.handler.read(characteristic, offset: 0, from: subscriber(session))
    }

    /// Writes `value` to `characteristic` through the device's handler.
    func write(
        device: UUID,
        characteristic: CharacteristicIdentifier,
        value: Data,
        session: UUID
    ) async -> Result<Void, ATTError> {
        guard let state = devices[device] else { return .failure(.invalidHandle) }
        guard definition(of: characteristic, in: state) != nil else { return .failure(.attributeNotFound) }
        let central = subscriber(session)
        let entry = WriteRequest.Entry(central: central, characteristic: characteristic, offset: 0, value: value)
        return await state.handler.write([entry], from: central)
    }

    /// Subscribes or unsubscribes `session` to `characteristic` and reports the change to
    /// the device's handler.
    func setNotify(
        _ enabled: Bool,
        device: UUID,
        characteristic: CharacteristicIdentifier,
        session: UUID
    ) async {
        guard let state = devices[device] else { return }
        if enabled {
            subscriptions[device, default: [:]][characteristic, default: []].insert(session)
        } else {
            subscriptions[device]?[characteristic]?.remove(session)
            if subscriptions[device]?[characteristic]?.isEmpty == true {
                subscriptions[device]?.removeValue(forKey: characteristic)
            }
        }
        await state.handler.subscriptionChanged(characteristic, central: subscriber(session), isSubscribed: enabled)
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
