//
//  VirtualRadio.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import Foundation
import Logging
import BLESwiftCompat17

/// An in-process BLE radio hosting ``VirtualDevice``s and serving them to any number of
/// ``VirtualCentralBackend``s — fixture devices and simulator-to-simulator BLE with no
/// hardware involved.
///
/// The radio owns every piece of shared state: the registered devices, each backend's
/// scanner, its connections, and its notification subscriptions. Backends are queue-confined
/// classes that call in with `await` and deliver results back on their own queue, so no
/// CoreBluetooth-shaped delivery contract is ever violated.
///
/// The `NSError` domain of this radio's errors is `"BLESwiftProvider"`, kept from before the
/// radio moved out of that module, so callers that already switch on it keep working.
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

    /// The length ceiling for a `.withResponse` write, on every device. 512 is the maximum
    /// ATT attribute length, the natural ceiling for a link with no real MTU negotiation —
    /// and the length a `.withResponse` write really does reach on hardware, through ATT long
    /// writes.
    public static let maximumValueLength = 512

    /// The default length a single ATT packet may carry: 182, iOS's ATT_MTU of 185 less the
    /// three bytes of ATT header. The ceiling for a `.withoutResponse` write, and the
    /// `maximumUpdateValueLength` a subscriber of a virtual device reports. A device sets its
    /// own with ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``; this is what
    /// one that does not gets.
    ///
    /// **The two write types differ sharply on hardware, and a harness that hides it is worse
    /// than useless.** A `.withResponse` write reaches 512 bytes because ATT splits it into
    /// long-write chunks; a `.withoutResponse` write is one ATT packet and cannot exceed
    /// ATT_MTU − 3, and CoreBluetooth *silently drops* an oversize one. Reporting 512 for both
    /// let a 400-byte `.withoutResponse` write pass here and vanish on device — the single
    /// most common MTU footgun this harness exists to catch.
    ///
    /// **A notification is one ATT packet too**, so it is held to this ceiling rather than to
    /// ``maximumValueLength``: there is no long-write equivalent for a notification, and
    /// CoreBluetooth truncates one past the subscriber's `maximumUpdateValueLength`. Reporting
    /// 512 to a device handler had it push a 400-byte update that arrived whole here and
    /// arrived clipped to 182 on device — the same divergence in the opposite direction.
    public static let maximumWriteWithoutResponseLength = 182

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
    private static let logger = Logger(label: "BLESwiftVirtualRadio.VirtualRadio")

    /// One registered device: its description, whether it is currently advertising, which
    /// registration of its identifier it belongs to, and the faults armed on it.
    ///
    /// Fault state lives here, with the registration, so it goes when the device does:
    /// `remove()` followed by registering the identifier again starts clean, and a stale
    /// handle can no more arm a fault on its successor than it can unadvertise it.
    struct DeviceState {
        var descriptor: VirtualDeviceDescriptor
        let handler: any VirtualDeviceHandler
        var isAdvertising: Bool
        /// The generation ``register(_:advertising:)`` stamped this registration with. A
        /// handle from an earlier registration of the same identifier carries an older one
        /// and is refused. See ``VirtualDeviceHandle/generation``.
        let generation: UInt64
        /// The ATT answers injected per characteristic. See
        /// ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
        var attErrors: [CharacteristicIdentifier: InjectedATTErrors] = [:]
        /// The error the next connection attempts fail with, and how many of them —
        /// `nil` for every attempt until cleared. See
        /// ``VirtualDeviceHandle/failConnections(with:times:)``.
        var connectionFailure: (error: NSError, remaining: Int?)?
    }

    /// The ATT error injected for each operation on one characteristic, `nil` where the
    /// operation is served normally. An entry with all three `nil` is not kept.
    struct InjectedATTErrors {
        var read: ATTError?
        var write: ATTError?
        var subscribe: ATTError?

        /// Whether every slot is clear, so the entry can be dropped.
        var isEmpty: Bool { read == nil && write == nil && subscribe == nil }
    }

    /// What ``connect(session:device:sink:)`` answers: the error to fail the attempt with,
    /// or the connected device's name and the one-packet length it negotiates.
    ///
    /// Answered in the one hop rather than left to follow-up calls: the device could be
    /// removed or re-registered between them, and a connection that just succeeded would then
    /// be named `nil` or report a ceiling that belongs to a different registration.
    package struct ConnectOutcome: Sendable {
        /// The error to fail the attempt with; `nil` when it succeeded.
        package let error: NSError?
        /// The connected device's name; `nil` on failure or for an unnamed device.
        package let name: String?
        /// The connected device's ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``.
        package let maximumWriteWithoutResponseLength: Int

        /// A failed attempt.
        static func failure(_ error: NSError) -> ConnectOutcome {
            ConnectOutcome(error: error, name: nil, maximumWriteWithoutResponseLength: VirtualRadio.maximumWriteWithoutResponseLength)
        }
    }

    /// One backend's active scan.
    struct Scanner {
        var services: [ServiceIdentifier]?
        var repeater: Task<Void, Never>?
    }

    /// Everything the radio holds on behalf of one attached backend.
    struct Session {
        let centralSink: @Sendable (CentralEvent) -> Void
        var peripheralSinks: [UUID: @Sendable (PeripheralEvent) -> Void] = [:]
        var scanner: Scanner?
        var connections: Set<UUID> = []
    }

    var devices: [UUID: DeviceState] = [:]
    var sessions: [UUID: Session] = [:]

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
    package nonisolated let knownDeviceIDs = Mutex<Set<UUID>>([])

    /// Each registered device's connect delay, readable without awaiting the actor — only
    /// devices with a non-zero ``VirtualLatency/connect`` have an entry.
    ///
    /// ``VirtualCentralBackend/connect(_:options:requiresANCS:)`` has to decide
    /// **synchronously, on its own queue**, whether an attempt sleeps before it reaches the
    /// radio: a delayed attempt must not sit in the backend's serial chain, where a cancel
    /// queued behind it would wait out the delay and then see a spurious `didConnect`. Like
    /// ``knownDeviceIDs``, this is written inside ``register(_:advertising:)``,
    /// ``setLatency(_:device:generation:)``, and the removal path before any of them returns.
    package nonisolated let connectLatencies = Mutex<[UUID: Duration]>([:])

    /// The clock every delay on this radio sleeps on: a device's ``VirtualLatency``, the
    /// duplicate-sighting repeater, and a hosted `PeripheralHost`'s ATT timeout. Wall time
    /// unless ``init(clock:)`` was given another.
    public nonisolated let clock: any Clock<Duration>

    /// Notification subscriptions, keyed by device, then characteristic, to the set of
    /// session identifiers currently subscribed.
    private var subscriptions: [UUID: [CharacteristicIdentifier: Set<UUID>]] = [:]

    /// Creates an empty radio.
    ///
    /// - Parameter clock: The clock every delay on this radio sleeps on. Defaults to
    ///   `ContinuousClock()`; a test hands in `BLESwiftTestSupport`'s `ManualClock` and
    ///   advances it to drive a device's ``VirtualLatency`` to its deadline.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    // MARK: - Devices

    /// Registers `device`, making it visible to every backend this radio serves.
    ///
    /// **An identifier already registered is replaced, and the old registration retired as
    /// ``VirtualDeviceHandle/remove()`` retires one** — what a link client redialing under a
    /// stable `hostIdentifier` produces. Each subscription the old registration held is
    /// reported to the *old* handler as an unsubscribe, and every central connected to it
    /// then hears `didDisconnect` with ``deviceRemovedError`` — unsubscribes first, as every
    /// teardown here orders them, since a `Central` that heard the disconnect first would
    /// reconnect to the new registration and re-subscribe while the old unsubscribe was
    /// still in flight. The new handler hears nothing, since it never saw those subscribers
    /// arrive. Left in place, the connections and subscriptions
    /// carried over to a registration whose handler had been told of neither: it inherited
    /// subscribers it never received `subscriptionChanged(isSubscribed: true)` for, the old
    /// handler never heard the matching unsubscribes, and the centrals stayed connected to a
    /// device that had changed under them without a word.
    ///
    /// The new device state is installed before the first `await`, and the identifier
    /// stays in `knownDeviceIDs` throughout, so a backend resolving the identifier while
    /// the old handler is still being told about its unsubscribes finds the device there —
    /// the identifier is never absent, which is the whole point of re-registering instead
    /// of removing and registering.
    ///
    /// - Parameters:
    ///   - device: The device to host.
    ///   - advertising: Whether it starts out advertising. Defaults to `true`.
    /// - Returns: A ``VirtualDeviceHandle`` for pushing notifications and mutating the
    ///   device after registration.
    @discardableResult
    public func register(_ device: VirtualDevice, advertising: Bool = true) async -> VirtualDeviceHandle {
        let identifier = device.descriptor.identifier
        let packetLength = device.descriptor.maximumWriteWithoutResponseLength
        precondition(
            (20...512).contains(packetLength),
            "maximumWriteWithoutResponseLength must be in 20...512 (ATT_MTU 23 − 3 up to the attribute maximum); got \(packetLength)"
        )
        // Retired before the new state goes in, so every table — connections, sinks,
        // subscriptions — belongs to one registration at a time; its reports wait until the
        // new state is in place, so nothing a handler does on hearing them finds a gap.
        let retired = retire(identifier)
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
        recordConnectLatency(device.descriptor.latency.connect, of: identifier)
        if advertising {
            reportSightings(of: identifier)
        }
        if let retired {
            await report(retired)
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
    func isCurrent(_ device: UUID, generation: UInt64, operation: String) -> Bool {
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

    /// Replaces a registered device's latency. See ``VirtualDeviceHandle/setLatency(_:)``.
    ///
    /// The connect delay is mirrored into ``connectLatencies`` before this returns, so a
    /// backend deciding on its own queue sees the new value the moment the handle's call has
    /// landed.
    func setLatency(_ latency: VirtualLatency, device: UUID, generation: UInt64) {
        guard isCurrent(device, generation: generation, operation: "setLatency") else { return }
        devices[device]?.descriptor.latency = latency
        recordConnectLatency(latency.connect, of: device)
    }

    /// Mirrors `delay` into ``connectLatencies`` — an entry for a non-zero delay, none for
    /// zero, so a device whose delay was cleared, or re-registered without one, leaves no
    /// entry behind for a backend to sleep on.
    private nonisolated func recordConnectLatency(_ delay: Duration, of device: UUID) {
        connectLatencies.withLock { (latencies: inout [UUID: Duration]) -> Void in
            if delay > .zero {
                latencies[device] = delay
            } else {
                latencies.removeValue(forKey: device)
            }
        }
    }

    /// The delay a device's ``VirtualLatency`` sets for one kind of request, as of now, or
    /// `nil` when there is none to wait out — the device is gone, or the delay is zero.
    ///
    /// The zero check is what keeps an undelayed operation on its old path exactly: a
    /// `sleep(for: .zero)` would still suspend and, on a `ManualClock`, register a sleeper
    /// for a test to wait on, so nothing is ever slept for `.zero`.
    private func latency(for operation: KeyPath<VirtualLatency, Duration>, on device: UUID) -> Duration? {
        guard let delay = devices[device]?.descriptor.latency[keyPath: operation], delay > .zero else { return nil }
        return delay
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
        guard let handler = devices[device]?.handler else { return }
        var dropped: [(central: Subscriber, characteristics: [CharacteristicIdentifier])] = []
        for (sessionID, session) in sessions where session.connections.contains(device) {
            session.peripheralSinks[device]?(.didModifyServices(Array(invalidated)))
            dropped.append((subscriber(sessionID, device: device), dropSubscriptions(session: sessionID, device: device, under: invalidated)))
        }
        // Every table is settled before the first `await`, as in ``detach(session:)``, so a
        // handler that calls back into the radio cannot observe a half-applied database —
        // and the handler and subscribers are taken now, so a removal or re-registration
        // landing between the reports cannot redirect them.
        for entry in dropped {
            await reportUnsubscribed(entry.characteristics, handler: handler, central: entry.central)
        }
    }

    /// Removes a registered device, disconnecting every central attached to it. See
    /// ``VirtualDeviceHandle/remove()``.
    ///
    /// Every subscription the device still had is reported to its handler as an
    /// unsubscribe, so a hosted `PeripheralHost` is left holding no subscriber it can never
    /// notify again — CoreBluetooth reports `didUnsubscribe` when a subscribed central goes
    /// away, and so does this radio — and each connected central hears `didDisconnect`
    /// with ``deviceRemovedError`` only after that, the order every teardown on this radio
    /// uses (see ``report(_:)``).
    func remove(device: UUID, generation: UInt64) async {
        guard isCurrent(device, generation: generation, operation: "remove") else { return }
        guard let retired = retire(device) else { return }
        // Taken off the synchronous mirrors here, not in `retire`: a re-registration retires
        // the old state and installs the new in the same actor turn, and the identifier must
        // stay resolvable throughout. Only a removal makes it unknown.
        knownDeviceIDs.withLock { (known: inout Set<UUID>) -> Void in
            known.remove(device)
        }
        recordConnectLatency(.zero, of: device)
        await report(retired)
    }

    /// What retiring a registration leaves to deliver once every table is settled: each
    /// subscription it still held, as the `Subscriber` the handler saw arrive, and the
    /// `didDisconnect` owed to each session that was connected.
    ///
    /// Built from the retired descriptor rather than looked up: by the time these are
    /// reported, the device is gone from the table — or, after a re-registration, is a
    /// different device — and the handler should see the same `Subscriber` leave as it saw
    /// arrive.
    private struct Retirement {
        let handler: any VirtualDeviceHandler
        let departing: [(characteristic: CharacteristicIdentifier, central: Subscriber)]
        let identifier: PeripheralIdentifier
        let disconnected: [@Sendable (CentralEvent) -> Void]
    }

    /// Takes `device`'s registration off every actor table — the device, its subscriptions,
    /// and each session's connection to it and sink for it. The shared body of
    /// ``remove(device:generation:)`` and a re-``register(_:advertising:)``.
    ///
    /// Synchronous, so a caller can settle the tables — and, for a re-registration, install
    /// the successor — before anything is reported. Nothing is delivered here: the
    /// unsubscribes and the `didDisconnect`s come back as a ``Retirement`` for
    /// ``report(_:)``, which sends them in the one order every teardown uses; `nil` when
    /// nothing was registered under `device`.
    private func retire(_ device: UUID) -> Retirement? {
        guard let state = devices.removeValue(forKey: device) else { return nil }
        let subscriptions = self.subscriptions.removeValue(forKey: device) ?? [:]
        let identifier = PeripheralIdentifier(uuid: device, name: state.descriptor.name)
        var disconnected: [@Sendable (CentralEvent) -> Void] = []
        for sessionID in Array(sessions.keys) {
            // Dropped for every session, connected or not: the sink routes events *from* this
            // device, and there is no longer a device to route them from. A live entry would
            // outlive the device and keep its backend's remote alive with it.
            sessions[sessionID]?.peripheralSinks.removeValue(forKey: device)
            guard let session = sessions[sessionID], session.connections.contains(device) else { continue }
            sessions[sessionID]?.connections.remove(device)
            disconnected.append(session.centralSink)
        }
        var departing: [(characteristic: CharacteristicIdentifier, central: Subscriber)] = []
        for (characteristic, subscribers) in subscriptions {
            for sessionID in subscribers {
                let central = Subscriber(
                    id: sessionID,
                    maximumUpdateValueLength: state.descriptor.maximumWriteWithoutResponseLength
                )
                departing.append((characteristic, central))
            }
        }
        return Retirement(handler: state.handler, departing: departing, identifier: identifier, disconnected: disconnected)
    }

    /// Tells a retired registration's handler about each subscription it lost, then delivers
    /// the `didDisconnect`s — the one `await` of a removal or re-registration, made only
    /// once every table is settled.
    ///
    /// **The `didDisconnect`s go out last**, the order ``disconnect(centrals:error:device:generation:)``
    /// keeps and for the same reason: the actor is reentrant across the unsubscribe awaits,
    /// and a `Central` with a reconnect policy that heard the disconnect first could
    /// reconnect and re-subscribe while the handler was still being told about the old
    /// subscription. A removal left nothing to reconnect to, but a re-registration leaves
    /// the identifier known throughout, so the reconnect lands on the new registration at
    /// once — and with the same handler behind both, the handler finished the unsubscribe
    /// *after* the re-subscribe and took a live subscriber for one that had left.
    private func report(_ retired: Retirement) async {
        for entry in retired.departing {
            await retired.handler.subscriptionChanged(entry.characteristic, central: entry.central, isSubscribed: false)
        }
        for sink in retired.disconnected {
            sink(.didDisconnect(retired.identifier, error: Self.deviceRemovedError))
        }
    }

    /// Pushes a notification to every subscribed, connected central. See
    /// ``VirtualDeviceHandle/notify(_:for:to:)``.
    ///
    /// **The value is truncated to each subscriber's `maximumUpdateValueLength`** — the
    /// device's own ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength`` — as
    /// CoreBluetooth truncates a notification that will not fit the subscriber's MTU. Passed
    /// whole, a payload larger than the maximum this radio reports arrived intact here and
    /// arrived clipped on device — the same divergence an unenforced write ceiling is.
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
            let delivered = Data(value.prefix(subscriber(sessionID, device: device).maximumUpdateValueLength))
            session.peripheralSinks[device]?(.didUpdateValue(characteristic: characteristic, value: delivered, error: nil))
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
        var dropped: [(handler: any VirtualDeviceHandler, central: Subscriber, characteristics: [CharacteristicIdentifier])] = []
        for device in removed.connections {
            guard let handler = devices[device]?.handler else { continue }
            dropped.append((handler, subscriber(session, device: device), dropSubscriptions(session: session, device: device)))
        }
        // Every table is settled before the first `await`, so a handler that calls back into
        // the radio cannot observe a half-detached session; each handler and subscriber is
        // taken now too, so a removal or re-registration landing between the reports cannot
        // redirect them.
        for entry in dropped {
            await reportUnsubscribed(entry.characteristics, handler: entry.handler, central: entry.central)
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
        let repeater = Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: Self.duplicateInterval)
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

    /// Whether `session` currently holds a connection to `device`, as the radio sees it.
    ///
    /// Not API: it exists so a test can assert that a backend's remote agrees with the radio
    /// about a connection once a race between a connect and a forced disconnect has settled.
    package func isConnected(session: UUID, device: UUID) -> Bool {
        isConnected(session: session, to: device)
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
    /// The device's name and one-packet length are answered here rather than left to a
    /// second ``name(of:)`` hop: the device could be removed between the two, and the
    /// connection that just succeeded would then be named `nil`.
    ///
    /// **An armed connection failure is consumed here**, behind the session and device
    /// guards — an unregistered device fails with ``unknownDeviceError`` as it always has,
    /// never with a fault armed on a registration that is gone. A failed attempt records
    /// neither the connection nor the sink, so the device never learns of it, exactly as a
    /// peripheral that refused the link never sees the central. See
    /// ``VirtualDeviceHandle/failConnections(with:times:)``. A direct caller of the radio
    /// connecting a session already connected to the device succeeds without consuming the
    /// armed failure — ``VirtualCentralBackend`` never sends such a call, since it answers a
    /// connect on a `.connected` remote itself — because failing it would leave a remote the
    /// radio still holds connected reporting itself disconnected.
    ///
    /// - Returns: The outcome: the error to fail the attempt with, or the connected device's
    ///   name and ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``.
    func connect(
        session: UUID,
        device: UUID,
        sink: @escaping @Sendable (PeripheralEvent) -> Void
    ) -> ConnectOutcome {
        guard sessions[session] != nil else { return .failure(Self.unknownDeviceError) }
        guard let state = devices[device] else { return .failure(Self.unknownDeviceError) }
        if sessions[session]?.connections.contains(device) != true, let failure = state.connectionFailure {
            switch failure.remaining {
            case .some(1):
                devices[device]?.connectionFailure = nil
            case .some(let remaining):
                devices[device]?.connectionFailure = (failure.error, remaining - 1)
            case .none:
                break
            }
            return .failure(failure.error)
        }
        sessions[session]?.peripheralSinks[device] = sink
        sessions[session]?.connections.insert(device)
        return ConnectOutcome(
            error: nil,
            name: state.descriptor.name,
            maximumWriteWithoutResponseLength: state.descriptor.maximumWriteWithoutResponseLength
        )
    }

    /// Disconnects `session` from `device`, dropping its subscriptions and reporting each of
    /// them to the device's handler as an unsubscribe. The backend delivers the resulting
    /// `didDisconnect` itself, mirroring CoreBluetooth's `cancelPeripheralConnection(_:)` —
    /// but only when this call is what ended the connection.
    ///
    /// - Returns: Whether a connection was removed. `false` when the session was not
    ///   connected to the device — never was, or a forced disconnect, a removal, or a failed
    ///   connect already settled it — in which case the backend must deliver nothing: the
    ///   path that did the settling has already reported the outcome, and a second
    ///   `didDisconnect` on top of it reported the peripheral gone twice and overwrote the
    ///   state of a reconnect that had started in between. Sinks and subscriptions are
    ///   dropped either way; they are idempotent.
    @discardableResult
    func disconnect(session: UUID, device: UUID) async -> Bool {
        let removed = sessions[session]?.connections.remove(device) != nil
        // Goes with the connection: the sink was registered by ``connect(session:device:sink:)``
        // and the backend delivers the `didDisconnect` itself, so nothing is left to route
        // through it.
        sessions[session]?.peripheralSinks.removeValue(forKey: device)
        let dropped = dropSubscriptions(session: session, device: device)
        if let handler = devices[device]?.handler {
            let central = subscriber(session, device: device)
            await reportUnsubscribed(dropped, handler: handler, central: central)
        }
        return removed
    }

    /// Removes every subscription `session` holds on `device` — or, when `services` is given,
    /// only those under one of those services.
    ///
    /// - Returns: The characteristics `session` really was subscribed to, so exactly those —
    ///   and no others — are reported to the device's handler.
    func dropSubscriptions(
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

    /// Tells `handler` that `central` is no longer subscribed to `characteristics`.
    ///
    /// This is what keeps a hosted `PeripheralHost` — fixture, code-defined, or link-hosted —
    /// from holding a ghost subscriber after the central behind it disconnected, cancelled,
    /// or had its backend detached. CoreBluetooth reports `didUnsubscribe` in exactly those
    /// cases.
    ///
    /// Takes the handler and the subscriber rather than looking them up: the caller is
    /// reporting across `await`s, and a `remove()` or re-`register` landing between two of
    /// them would otherwise drop the rest or hand them to a handler that never saw these
    /// subscribers. Every caller captures both before its first `await`.
    func reportUnsubscribed(
        _ characteristics: [CharacteristicIdentifier],
        handler: any VirtualDeviceHandler,
        central: Subscriber
    ) async {
        for characteristic in characteristics {
            await handler.subscriptionChanged(characteristic, central: central, isSubscribed: false)
        }
    }

    // MARK: - GATT

    /// The services of `device` matching `filter` (every service when `filter` is `nil`),
    /// after the device's ``VirtualLatency/discovery`` delay.
    ///
    /// **The delay comes before every guard**, here and in each GATT entry point below, so
    /// every check sees the state the device is in once the delay has run out: a device
    /// removed, re-registered, or disconnected from during the delay answers as it would
    /// to a request that arrived then. The remote queues its GATT requests behind each other
    /// on one chain, so a delayed one holds up those behind it, as ATT's one transaction at a
    /// time does on hardware — with one difference: a delay already started outlives a
    /// disconnect. Hardware aborts the transaction when the link drops; here the request
    /// sleeps out its full delay, is refused at the gate, and holds the chain — and a
    /// reconnect's first operation behind it — for the remainder. A `ManualClock` still
    /// counts that sleeper. See ``VirtualLatency``.
    func services(of device: UUID, matching filter: [ServiceIdentifier]?) async -> [ServiceIdentifier] {
        if let delay = latency(for: \.discovery, on: device) { try? await clock.sleep(for: delay) }
        guard let state = devices[device] else { return [] }
        let identifiers = state.descriptor.services.map(\.identifier)
        guard let filter else { return identifiers }
        let requested = Set(filter)
        return identifiers.filter { requested.contains($0) }
    }

    /// The characteristics of `service` on `device` matching `filter`, paired with the
    /// properties each advertises — after the device's ``VirtualLatency/discovery`` delay,
    /// as ``services(of:matching:)``.
    func characteristics(
        of device: UUID,
        service: ServiceIdentifier,
        matching filter: [CharacteristicIdentifier]?
    ) async -> [CharacteristicDiscovery] {
        if let delay = latency(for: \.discovery, on: device) { try? await clock.sleep(for: delay) }
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
    ///
    /// **An injected ATT error comes right after the handle is found**, before permission,
    /// the static short-circuit, and the handler: it simulates the peripheral's ATT answer for
    /// a valid handle, so a static-value characteristic fails under it too. See
    /// ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
    ///
    /// The device's ``VirtualLatency/read`` delay comes before all of it, as
    /// ``services(of:matching:)`` explains.
    func read(
        device: UUID,
        characteristic: CharacteristicIdentifier,
        offset: Int = 0,
        session: UUID
    ) async -> Result<Data, ATTError> {
        if let delay = latency(for: \.read, on: device) { try? await clock.sleep(for: delay) }
        guard isConnected(session: session, to: device) else { return .failure(.invalidHandle) }
        guard let state = devices[device] else { return .failure(.invalidHandle) }
        guard let definition = definition(of: characteristic, in: state) else { return .failure(.attributeNotFound) }
        if let injected = state.attErrors[characteristic]?.read { return .failure(injected) }
        guard definition.properties.contains(.read) || definition.properties.isNotifiable else {
            return .failure(.readNotPermitted)
        }
        if let value = definition.value {
            guard offset >= 0, offset <= value.count else { return .failure(.invalidOffset) }
            return .success(Data(value.dropFirst(offset)))
        }
        return await state.handler.read(characteristic, offset: offset, from: subscriber(session, device: device))
    }

    /// Writes `value` to `characteristic` through the device's handler. A session that is not
    /// connected to `device` is refused with `ATTError.invalidHandle`, a characteristic
    /// declaring neither `write` nor `writeWithoutResponse` with `ATTError.writeNotPermitted`.
    ///
    /// **Each write type carries its own length ceiling**, the one hardware imposes: a
    /// `.withResponse` write past ``maximumValueLength`` is refused with
    /// `ATTError.invalidAttributeValueLength`, and a `.withoutResponse` write past the
    /// device's ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength`` is *dropped* —
    /// it never reaches the device's handler, and the caller hears nothing, exactly as
    /// CoreBluetooth drops one too large for a single ATT packet. Enforced here rather than
    /// in the remote so that every route to a virtual device, hosted or fixture, is held to
    /// the same ceiling.
    ///
    /// **An injected ATT error fails a `.withResponse` write only.** A `.withoutResponse`
    /// write has no ATT response to carry an error back on, so it reaches the handler as if
    /// nothing were armed — which is what the peripheral's application code sees on hardware
    /// too. See ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
    ///
    /// **The permission check is the radio's, not the handler's.** It mirrors the one
    /// ``read(device:characteristic:offset:session:)`` makes, and for the same reason: a
    /// hosted device — a remote `PeripheralHost` at the far end of a link — has no
    /// ``FixtureDeviceHandler`` to refuse for it, so a write to a read-only characteristic
    /// reached its `didReceiveWrite` and was served. Real hardware refuses that write at the
    /// ATT layer, before any of it reaches the peripheral's application code, and so does this
    /// radio, whatever the device behind the handle is.
    ///
    /// The device's ``VirtualLatency/write`` delay comes before all of it for a
    /// `.withResponse` write, as ``services(of:matching:)`` explains; a `.withoutResponse`
    /// write has no answer to delay and is never slept for.
    func write(
        device: UUID,
        characteristic: CharacteristicIdentifier,
        value: Data,
        type: WriteType = .withResponse,
        session: UUID
    ) async -> Result<Void, ATTError> {
        if type == .withResponse, let delay = latency(for: \.write, on: device) { try? await clock.sleep(for: delay) }
        guard isConnected(session: session, to: device) else { return .failure(.invalidHandle) }
        guard let state = devices[device] else { return .failure(.invalidHandle) }
        guard let definition = definition(of: characteristic, in: state) else { return .failure(.attributeNotFound) }
        if type == .withResponse, let injected = state.attErrors[characteristic]?.write { return .failure(injected) }
        guard definition.properties.isWritable else { return .failure(.writeNotPermitted) }
        switch type {
        case .withResponse:
            guard value.count <= Self.maximumValueLength else {
                return .failure(.invalidAttributeValueLength)
            }
        case .withoutResponse:
            // Dropped, not refused: an unacknowledged write has no response to fail, and
            // CoreBluetooth reports nothing for one it could not fit in a packet either. The
            // `.success` releases the caller's transmit slot; nothing reached the device.
            let ceiling = state.descriptor.maximumWriteWithoutResponseLength
            guard value.count <= ceiling else {
                Self.logger.debug(
                    """
                    Dropping a \(value.count)-byte .withoutResponse write to \(characteristic) on device \(device): \
                    the ceiling is \(ceiling) bytes
                    """
                )
                return .success(())
            }
        }
        let central = subscriber(session, device: device)
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
    /// **An injected ATT error refuses enabling and disabling alike** — both are writes to
    /// the same CCCD, and hardware that rejects one rejects the other. The set is left as it
    /// was and the handler hears nothing, since no transition happened. See
    /// ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
    ///
    /// The device's ``VirtualLatency/subscribe`` delay comes before all of it, enabling and
    /// disabling alike, as ``services(of:matching:)`` explains.
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
        if let delay = latency(for: \.subscribe, on: device) { try? await clock.sleep(for: delay) }
        let unchanged = subscriptions[device]?[characteristic]?.contains(session) == true
        guard let state = devices[device], isConnected(session: session, to: device) else {
            return (unchanged, nil)
        }
        guard let definition = definition(of: characteristic, in: state) else {
            return (unchanged, .attributeNotFound)
        }
        if let injected = state.attErrors[characteristic]?.subscribe {
            return (unchanged, injected)
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
        await state.handler.subscriptionChanged(characteristic, central: subscriber(session, device: device), isSubscribed: enabled)
        return (enabled, nil)
    }

    /// The characteristic definition for `characteristic` in `state`'s current database.
    private func definition(of characteristic: CharacteristicIdentifier, in state: DeviceState) -> GATTCharacteristic? {
        state.descriptor.services
            .first { $0.identifier == characteristic.service }?
            .characteristics
            .first { $0.identifier == characteristic }
    }

    /// The ``BLESwiftCore/Subscriber`` a backend session appears as to `device`'s handler.
    ///
    /// Its `maximumUpdateValueLength` is the device's
    /// ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``, not
    /// ``maximumValueLength``: a notification is a single ATT packet, exactly as a
    /// `.withoutResponse` write is. See ``maximumWriteWithoutResponseLength``, which stands
    /// in for a device that is not registered. Every caller looks up a device that is;
    /// ``retire(_:)`` builds a retired registration's departing subscribers from its own
    /// descriptor rather than through here.
    func subscriber(_ session: UUID, device: UUID) -> Subscriber {
        Subscriber(
            id: session,
            maximumUpdateValueLength: devices[device]?.descriptor.maximumWriteWithoutResponseLength
                ?? Self.maximumWriteWithoutResponseLength
        )
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
