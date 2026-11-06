//
//  VirtualRadio.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import Foundation
import Logging
import BLESwiftCompat17

/// An in-process BLE radio. It hosts ``VirtualDevice``s and serves them to any number of
/// ``VirtualCentralBackend``s. It supports fixture devices and simulator-to-simulator BLE with no
/// hardware.
///
/// The radio owns all shared state: the registered devices, each backend's scanner, connections,
/// and notification subscriptions. Backends are queue-confined classes. They call in with `await`
/// and deliver results back on their own queue, so the radio never violates a CoreBluetooth
/// delivery contract.
///
/// The `NSError` domain of this radio's errors is `"BLESwiftProvider"`.
///
/// ```swift
/// let radio = VirtualRadio()
/// let (device, handler) = VirtualDevice.fixture(fixtureDevice)
/// let handle = await radio.register(device)
/// await handler.attach(handle)
/// let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
/// ```
public actor VirtualRadio {

    /// The RSSI that every sighting and `PeripheralRemote.readRSSI()` reports. Virtual devices have
    /// no radio distance, so one plausible value stands in.
    public static let rssi = -50

    /// The length ceiling for a `.withResponse` write, on every device. 512 is the maximum ATT
    /// attribute length. A `.withResponse` write really reaches this length on hardware, through
    /// ATT long writes.
    public static let maximumValueLength = 512

    /// The default length that a single ATT packet can carry: 182, the iOS ATT_MTU (185) less the
    /// three-byte ATT header. It is the ceiling for a `.withoutResponse` write and the
    /// `maximumUpdateValueLength` that a subscriber of a virtual device reports. A device sets its
    /// own length with ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``. A device that
    /// does not set one gets this value.
    ///
    /// **The two write types differ sharply on hardware.** A `.withResponse` write reaches 512
    /// bytes, because ATT splits it into long-write chunks. A `.withoutResponse` write is one ATT
    /// packet and cannot exceed ATT_MTU − 3. CoreBluetooth *silently drops* an oversize one. If the
    /// radio reported 512 for both, a 400-byte `.withoutResponse` write would pass here and vanish
    /// on a device. This is the most common MTU trap, and this harness exists to catch it.
    ///
    /// **A notification is one ATT packet too.** The radio holds it to this ceiling and not to
    /// ``maximumValueLength``, because a notification has no long-write equivalent. CoreBluetooth
    /// truncates a notification that is longer than the subscriber's `maximumUpdateValueLength`. A
    /// 400-byte update would arrive whole here and clipped to 182 on a device.
    public static let maximumWriteWithoutResponseLength = 182

    /// How long a GATT request that is parked for a hosted `PeripheralHost` waits for that host's
    /// answer. After this time, the radio refuses the request with `ATTError.unlikelyError`.
    ///
    /// Without it, a host that never responds (a host wedged in its request handler, or a link
    /// client that stopped answering) would leave the central's read or write suspended forever,
    /// with every later operation queued behind it. Thirty seconds is the ATT transaction timeout
    /// that Bluetooth Core specifies.
    public static let attTimeout = Duration.seconds(30)

    /// The error that a connection attempt to an unregistered device fails with (code 1).
    public static var unknownDeviceError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No virtual device is registered with that identifier."]
        )
    }

    /// The error that a connected central is disconnected with when its device is removed (code 2).
    public static var deviceRemovedError: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The virtual device was removed from the radio."]
        )
    }

    /// How often a scanner that allows duplicates reports every matching device again.
    private static let duplicateInterval = Duration.seconds(1)

    /// Where the radio reports a mutation that it refused because its handle is stale. Nothing else
    /// in the radio logs. This is the one event that silently is *not* what its caller asked for.
    private static let logger = Logger(label: "BLESwiftVirtualRadio.VirtualRadio")

    /// One registered device: its description, whether it is advertising, which registration of its
    /// identifier it belongs to, and the faults armed on it.
    ///
    /// Fault state lives here, with the registration, so it goes when the device goes. A `remove()`
    /// followed by a new registration of the identifier starts clean, and a stale handle cannot arm
    /// a fault on its successor.
    struct DeviceState {
        var descriptor: VirtualDeviceDescriptor
        let handler: any VirtualDeviceHandler
        var isAdvertising: Bool
        /// The generation that ``register(_:advertising:)`` stamped this registration with. The
        /// radio refuses a handle from an earlier registration, which carries an older generation.
        /// See ``VirtualDeviceHandle/generation``.
        let generation: UInt64
        /// The ATT answers injected for each characteristic. See
        /// ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
        var attErrors: [CharacteristicIdentifier: InjectedATTErrors] = [:]
        /// The error that the next connection attempts fail with, and how many of them (`nil` means
        /// every attempt until cleared). See ``VirtualDeviceHandle/failConnections(with:times:)``.
        var connectionFailure: (error: NSError, remaining: Int?)?
    }

    /// The ATT error injected for each operation on one characteristic. A `nil` slot means the
    /// radio serves the operation normally. The radio keeps no entry with all three slots `nil`.
    struct InjectedATTErrors {
        var read: ATTError?
        var write: ATTError?
        var subscribe: ATTError?

        /// Whether every slot is clear, so the radio can drop the entry.
        var isEmpty: Bool { read == nil && write == nil && subscribe == nil }
    }

    /// What ``connect(session:device:sink:)`` answers: the error that fails the attempt, or the
    /// connected device's name and negotiated one-packet length.
    ///
    /// The radio answers in one hop, because the device could be removed or registered again
    /// between follow-up calls. A connection that just succeeded would then get the name `nil`, or
    /// report a ceiling that belongs to a different registration.
    package struct ConnectOutcome: Sendable {
        /// The error that fails the attempt, or `nil` when the attempt succeeded.
        package let error: NSError?
        /// The connected device's name, or `nil` on failure or for an unnamed device.
        package let name: String?
        /// The connected device's ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``.
        package let maximumWriteWithoutResponseLength: Int

        /// A failed attempt.
        static func failure(_ error: NSError) -> ConnectOutcome {
            ConnectOutcome(error: error, name: nil, maximumWriteWithoutResponseLength: VirtualRadio.maximumWriteWithoutResponseLength)
        }
    }

    /// The active scan of one backend.
    struct Scanner {
        var services: [ServiceIdentifier]?
        var repeater: Task<Void, Never>?
    }

    /// Everything that the radio holds on behalf of one attached backend.
    struct Session {
        let centralSink: @Sendable (CentralEvent) -> Void
        var peripheralSinks: [UUID: @Sendable (PeripheralEvent) -> Void] = [:]
        var scanner: Scanner?
        var connections: Set<UUID> = []
    }

    var devices: [UUID: DeviceState] = [:]
    var sessions: [UUID: Session] = [:]

    /// Stamps every registration, so the radio can tell a handle from a handle of the same
    /// identifier that was registered again later. The value is monotonic across the radio and
    /// never reused. Read it as an identity, not a count.
    private var lastGeneration: UInt64 = 0

    /// The identifiers of the devices registered on this radio. Code can read it without an
    /// `await`.
    ///
    /// A backend must answer `retrievePeripherals(withIdentifiers:)` **synchronously**, on its own
    /// queue, so it cannot ask the radio. A pushed snapshot would cost an actor hop plus a queue
    /// hop. A client that registers a device and connects to it in one synchronous flow, as the
    /// provider's sessions do, could look up the identifier before the snapshot arrived and be told
    /// that no such device exists.
    ///
    /// The code writes this set inside ``register(_:advertising:)`` and the removal path, before
    /// either returns, so every backend sees a registration the instant it happens.
    package nonisolated let knownDeviceIDs = Mutex<Set<UUID>>([])

    /// The connect delay of each registered device. Code can read it without an `await`. Only
    /// devices with a non-zero ``VirtualLatency/connect`` have an entry.
    ///
    /// ``VirtualCentralBackend/connect(_:options:requiresANCS:)`` must decide **synchronously, on
    /// its own queue**, whether an attempt sleeps before it reaches the radio. A delayed attempt
    /// must not sit in the backend's serial chain, where a queued cancel would wait out the delay
    /// and then see a spurious `didConnect`. Like ``knownDeviceIDs``, the code writes this inside
    /// ``register(_:advertising:)``, ``setLatency(_:device:generation:)``, and the removal path,
    /// before any of them returns.
    package nonisolated let connectLatencies = Mutex<[UUID: Duration]>([:])

    /// The clock that every delay on this radio sleeps on: a device's ``VirtualLatency``, the
    /// repeater for duplicate sightings, and a hosted `PeripheralHost`'s ATT timeout. It is wall
    /// time unless the caller gave another clock to ``init(clock:)``.
    public nonisolated let clock: any Clock<Duration>

    /// The notification subscriptions: device, then characteristic, then the set of subscribed
    /// session identifiers.
    private var subscriptions: [UUID: [CharacteristicIdentifier: Set<UUID>]] = [:]

    /// The tail of each device's report chain: the task that delivers the last subscription report,
    /// or the last trailing `didDisconnect`, enqueued for that device. The next step waits on it. A
    /// step that finishes while it is still the tail removes the entry, so the table holds only
    /// devices with a report in flight.
    ///
    /// **Why a chain exists:** The radio changes its subscription table synchronously and then
    /// awaits `handler.subscriptionChanged`. The actor is reentrant across that await, so a later
    /// table change for the same device (from a disconnect, a removal, a re-registration,
    /// `setServices`, or a detach) could report `isSubscribed: false` while the earlier
    /// `isSubscribed: true` report was in flight. A handler that awaits inside its report then
    /// finished the two out of order.
    ///
    /// Every report is thus a step on its device's chain, enqueued in the same synchronous actor
    /// section as the table change that it reports. Chain order is table order, and a handler hears
    /// each device's changes one at a time, in the order they happened. See
    /// ``enqueueReport(device:_:)``.
    private var reportChains: [UUID: ReportChain] = [:]

    /// The report chain of one device: its tail, and the sequence number that a finishing step uses
    /// to check whether it is still the tail.
    private struct ReportChain {
        let tail: Task<Void, Never>
        let sequence: UInt64
    }

    /// Stamps every chain step, so a finishing step can check whether a later step was chained
    /// behind it. The value is monotonic across the radio and never reused.
    private var lastReportSequence: UInt64 = 0

    /// Whether the current task delivers a report from a device's chain. The value is `true` for
    /// the whole of every chain step: inside every handler `subscriptionChanged` and inside every
    /// task that the handler spawns from there. A `Task.detached` drops it.
    ///
    /// **A task that is spawned during a report keeps this value for its whole lifetime**, not only
    /// while the report is open. For example, a handler starts a notification loop on
    /// `didSubscribe`. The loop runs with the value set until it ends, so every radio call that the
    /// loop makes (such as `setServices` or a forced disconnect) returns before the radio delivers
    /// its reports, as a call from inside the report does. A handler that needs to wait for those
    /// reports starts the loop with `Task.detached`.
    ///
    /// Every entry point that enqueues reports awaits the tail of its chain before it returns, so
    /// the caller knows its reports were delivered. A call from inside a report would wait on the
    /// very step that it runs inside, a deadlock. An entry point that finds this value set thus
    /// enqueues its steps and returns without waiting. See ``settle(_:)``.
    @TaskLocal static var isReporting = false

    /// How many devices have a report chain now. This is a test hook, not API. A test uses it to
    /// assert that a burst of reports left no chain behind.
    package var reportChainCount: Int {
        reportChains.count
    }

    /// Creates an empty radio.
    ///
    /// - Parameter clock: The clock that every delay on this radio sleeps on. The default is
    ///   `ContinuousClock()`. A test gives the `ManualClock` of `BLESwiftTestSupport` and advances
    ///   it to drive a device's ``VirtualLatency`` to its deadline.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    // MARK: - Devices

    /// Registers `device` and makes it visible to every backend that this radio serves.
    ///
    /// If the identifier is already registered, the radio replaces it and retires the old
    /// registration as ``VirtualDeviceHandle/remove()`` does. A link client that redials with a
    /// stable `hostIdentifier` causes this case.
    ///
    /// 1. The radio reports each subscription of the old registration to the *old* handler as an
    ///    unsubscribe.
    /// 2. Every central that is connected to the old registration hears `didDisconnect` with
    ///    ``deviceRemovedError``.
    /// 3. The new handler hears nothing.
    ///
    /// The unsubscribes come first, so the window of <doc:InProcessMocking#Forced-disconnects>
    /// applies. If you call this method from inside a subscription report, it returns before the
    /// radio delivers the retirement's reports. See
    /// <doc:InProcessMocking#Report-order-and-reentrancy>.
    ///
    /// - Parameters:
    ///   - device: The device to host.
    ///   - advertising: Whether it starts out advertising. The default is `true`.
    /// - Returns: A ``VirtualDeviceHandle`` that pushes notifications and changes the device after
    ///   registration.
    @discardableResult
    public func register(_ device: VirtualDevice, advertising: Bool = true) async -> VirtualDeviceHandle {
        let identifier = device.descriptor.identifier
        let packetLength = device.descriptor.maximumWriteWithoutResponseLength
        precondition(
            (20...512).contains(packetLength),
            "maximumWriteWithoutResponseLength must be in 20...512 (ATT_MTU 23 − 3 up to the attribute maximum); got \(packetLength)"
        )
        // Retire the old registration before the new state goes in, so every table (connections,
        // sinks, subscriptions) belongs to one registration at a time. The retirement's reports
        // wait until the new state is in place, so nothing a handler does on hearing them finds a
        // gap.
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
            await settle(report(retired))
        }
        return VirtualDeviceHandle(identifier: identifier, generation: generation, radio: self)
    }

    /// Whether the device registered under `device` is the one for which the radio handed out
    /// `generation`. Every mutation that a ``VirtualDeviceHandle`` performs must check this.
    ///
    /// A registration replaces any earlier one for the same identifier, as when a link client
    /// redials with a stable `hostIdentifier`. The replaced session tears itself down
    /// asynchronously afterwards. If the radio keyed by identifier alone, that teardown's `remove`,
    /// `stopAdvertising`, and `removeAllHostedServices` would land on the *new* session's device
    /// and unregister, unadvertise, or empty it. The generation tells the two sessions apart.
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

    /// The generation registered under `device`, or `nil` if nothing is registered.
    ///
    /// This is a test hook, not API. A test uses it to act on a device through the radio when the
    /// ``VirtualDeviceHandle`` for it belongs to the backend that registered it.
    package func generation(of device: UUID) -> UInt64? {
        devices[device]?.generation
    }

    /// The name of a registered device, or `nil` if the device is unknown or unnamed.
    ///
    /// - Parameter device: The identifier of the device.
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

    /// Replaces the advertisement of a registered device. See
    /// ``VirtualDeviceHandle/setAdvertisement(_:)``.
    ///
    /// A non-`nil` ``BLESwiftCore/AdvertisementData/localName`` also becomes the device's
    /// ``VirtualDeviceDescriptor/name``, as in CoreBluetooth, where a `CBPeripheral` discovered
    /// from an advertisement with a local name reports that name. An advertisement without a local
    /// name leaves the existing name alone.
    func setAdvertisement(_ advertisement: AdvertisementData, device: UUID, generation: UInt64) {
        guard isCurrent(device, generation: generation, operation: "setAdvertisement") else { return }
        devices[device]?.descriptor.advertisement = advertisement
        if let localName = advertisement.localName {
            devices[device]?.descriptor.name = localName
        }
    }

    /// Replaces the latency of a registered device. See ``VirtualDeviceHandle/setLatency(_:)``.
    ///
    /// The radio mirrors the connect delay into ``connectLatencies`` before this method returns, so
    /// a backend that decides on its own queue sees the new value as soon as the handle's call has
    /// landed.
    func setLatency(_ latency: VirtualLatency, device: UUID, generation: UInt64) {
        guard isCurrent(device, generation: generation, operation: "setLatency") else { return }
        devices[device]?.descriptor.latency = latency
        recordConnectLatency(latency.connect, of: device)
    }

    /// Mirrors `delay` into ``connectLatencies``. A non-zero delay gets an entry and a zero delay
    /// gets none, so a device whose delay was cleared, or that was registered again without one,
    /// leaves no entry for a backend to sleep on.
    private nonisolated func recordConnectLatency(_ delay: Duration, of device: UUID) {
        connectLatencies.withLock { (latencies: inout [UUID: Duration]) -> Void in
            if delay > .zero {
                latencies[device] = delay
            } else {
                latencies.removeValue(forKey: device)
            }
        }
    }

    /// The delay that a device's ``VirtualLatency`` sets for one kind of request, as of now, or
    /// `nil` when there is no delay to wait out (the device is gone or the delay is zero).
    ///
    /// The code never sleeps for `.zero`. A `sleep(for: .zero)` would still suspend, and on a
    /// `ManualClock` it would register a sleeper for a test to wait on.
    private func latency(for operation: KeyPath<VirtualLatency, Duration>, on device: UUID) -> Duration? {
        guard let delay = devices[device]?.descriptor.latency[keyPath: operation], delay > .zero else { return nil }
        return delay
    }

    /// Replaces the GATT database of a registered device. See
    /// ``VirtualDeviceHandle/setServices(_:)``.
    ///
    /// If the new database drops a service, the radio reports `PeripheralEvent.didModifyServices`,
    /// with the invalidated services, to every connected session. This is CoreBluetooth's
    /// `peripheral(_:didModifyServices:)`: a central learns that handles it discovered are gone and
    /// must be discovered again. The radio reports nothing for a database that only gained
    /// services, because a purely additive change invalidates nothing.
    ///
    /// **A subscription under an invalidated service goes with it.** The radio reports it to the
    /// device's handler as an unsubscribe, as ``disconnect(session:device:)`` and
    /// ``remove(device:generation:)`` do. CoreBluetooth delivers `didUnsubscribeFrom` when code
    /// removes a published service. If the entry stayed:
    ///
    /// - It would be a subscriber that a link-hosted `PeripheralHost` could never lose.
    /// - It would poison re-subscription. After the service was added and subscribed again, the
    ///   radio would find the session already in the set and report no transition. The host starts
    ///   to notify on `didSubscribe`, so it would never be told, and the central would wait on a
    ///   stream that reported itself armed.
    ///
    /// The unsubscribes go on the device's report chain. This method returns after the radio
    /// delivers them, except for a call from inside a subscription report, which returns before.
    /// See ``isReporting``.
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
        // Settle every table before the first `await`, as ``detach(session:)`` does, so a handler
        // that calls back into the radio cannot observe a half-applied database. Take the handler
        // and the subscribers now, so a removal or a re-registration between the reports cannot
        // redirect them.
        var tail: Task<Void, Never>?
        for entry in dropped {
            tail = reportUnsubscribed(entry.characteristics, on: device, handler: handler, central: entry.central) ?? tail
        }
        await settle(tail)
    }

    /// Removes a registered device and disconnects every central that is attached to it. See
    /// ``VirtualDeviceHandle/remove()``.
    ///
    /// The radio reports every subscription that the device still had to its handler as an
    /// unsubscribe, so a hosted `PeripheralHost` does not keep a subscriber that it can never
    /// notify again. CoreBluetooth does the same when a subscribed central goes away. Each
    /// connected central hears `didDisconnect` with ``deviceRemovedError`` only after that. Every
    /// teardown on this radio uses this order. See ``report(_:)``. If you call this method from
    /// inside a subscription report, it returns before the radio delivers its own reports. See
    /// ``isReporting``.
    func remove(device: UUID, generation: UInt64) async {
        guard isCurrent(device, generation: generation, operation: "remove") else { return }
        guard let retired = retire(device) else { return }
        // Take the identifier off the synchronous mirrors here, not in `retire`. A re-registration
        // retires the old state and installs the new state in one actor turn, and the identifier
        // must stay resolvable throughout. Only a removal makes it unknown.
        knownDeviceIDs.withLock { (known: inout Set<UUID>) -> Void in
            known.remove(device)
        }
        recordConnectLatency(.zero, of: device)
        await settle(report(retired))
    }

    /// What the retirement of a registration leaves to deliver after every table is settled: each
    /// subscription that the registration still held, as the `Subscriber` that the handler saw
    /// arrive, and the `didDisconnect` that the radio owes to each connected session.
    ///
    /// The code builds it from the retired descriptor and does not look it up, because by the time
    /// the radio reports these the device is gone from the table (or, after a re-registration, a
    /// different device). The handler sees the same `Subscriber` leave as it saw arrive.
    private struct Retirement {
        let handler: any VirtualDeviceHandler
        let departing: [(characteristic: CharacteristicIdentifier, central: Subscriber)]
        let identifier: PeripheralIdentifier
        let disconnected: [@Sendable (CentralEvent) -> Void]
    }

    /// Takes the registration of `device` off every actor table: the device, its subscriptions, and
    /// each session's connection and sink for it. This is the shared body of
    /// ``remove(device:generation:)`` and a new ``register(_:advertising:)``.
    ///
    /// The method is synchronous, so a caller can settle the tables (and, for a re-registration,
    /// install the successor) before anything is reported. It delivers nothing. The unsubscribes
    /// and the `didDisconnect`s come back as a ``Retirement`` for ``report(_:)``, which sends them
    /// in the one order that every teardown uses. The method returns `nil` when nothing was
    /// registered under `device`.
    private func retire(_ device: UUID) -> Retirement? {
        guard let state = devices.removeValue(forKey: device) else { return nil }
        let subscriptions = self.subscriptions.removeValue(forKey: device) ?? [:]
        let identifier = PeripheralIdentifier(uuid: device, name: state.descriptor.name)
        var disconnected: [@Sendable (CentralEvent) -> Void] = []
        for sessionID in Array(sessions.keys) {
            // Drop the sink for every session, connected or not. It routes events *from* this
            // device, and a live entry would outlive the device and keep its backend's remote
            // alive.
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

    /// Enqueues, on the retired identifier's report chain, each subscription that the retired
    /// handler lost, and then the `didDisconnect` events.
    ///
    /// The `didDisconnect` events go out last, as in
    /// ``disconnect(centrals:error:device:generation:)``. A reconnect that an earlier
    /// `didDisconnect` caused could subscribe on the new registration before the shared handler
    /// heard the old unsubscribe. The handler would then take a live subscriber for one that had
    /// left. The chain also orders the events behind every other report in flight.
    ///
    /// With no unsubscribe and an empty chain, the events go out in this actor turn. See
    /// ``deliverDisconnects(_:device:after:_:)``.
    ///
    /// - Returns: The chain's tail, for ``settle(_:)``, or `nil` when nothing was put on the chain.
    private func report(_ retired: Retirement) -> Task<Void, Never>? {
        var tail: Task<Void, Never>?
        if !retired.departing.isEmpty {
            tail = enqueueReport(device: retired.identifier.uuid) {
                for entry in retired.departing {
                    await retired.handler.subscriptionChanged(entry.characteristic, central: entry.central, isSubscribed: false)
                }
            }
        }
        return deliverDisconnects(retired.disconnected, device: retired.identifier.uuid, after: tail) {
            .didDisconnect(retired.identifier, error: Self.deviceRemovedError)
        }
    }

    /// Delivers the `didDisconnect` events of a teardown to `sinks`:
    ///
    /// - If the teardown enqueued the step `unsubscribes`, the method delivers them as a chain step
    ///   behind it.
    /// - If the teardown enqueued none and the chain of `device` is empty, the method delivers them
    ///   synchronously, in the calling actor turn.
    ///
    /// The chain step keeps a `didDisconnect` behind every report in flight for the device,
    /// including this teardown's unsubscribes. See ``report(_:)`` and
    /// ``disconnect(centrals:error:device:generation:)``. The synchronous path is for a teardown
    /// with nothing in flight to stay behind. It delivers before the caller's next `await`, so a
    /// central that held no subscription hears the drop in the same turn in which the radio dropped
    /// it, with no window in between.
    ///
    /// - Returns: The chain's tail after everything is enqueued, for ``settle(_:)``: the step that
    ///   delivers the `didDisconnect` events, or `unsubscribes`. The value is `nil` when nothing
    ///   was put on the chain.
    func deliverDisconnects(
        _ sinks: [@Sendable (CentralEvent) -> Void],
        device: UUID,
        after unsubscribes: Task<Void, Never>?,
        _ event: @escaping @Sendable () -> CentralEvent
    ) -> Task<Void, Never>? {
        guard !sinks.isEmpty else { return unsubscribes }
        guard unsubscribes != nil || reportChains[device] != nil else {
            for sink in sinks {
                sink(event())
            }
            return nil
        }
        return enqueueReport(device: device) {
            for sink in sinks {
                sink(event())
            }
        }
    }

    /// Chains `step` behind every report already enqueued for `device`, and returns the task that
    /// delivers it.
    ///
    /// The method is synchronous. Call it in the same synchronous actor section as the table change
    /// that `step` reports. The chain's order is then the order in which the table changed, so a
    /// device's handler hears its changes in the order they happened, one at a time. The next step
    /// starts only after the previous step's `subscriptionChanged` has returned. The task inherits
    /// this actor's isolation. After `step` finishes, it removes its own entry if it is still the
    /// tail, and otherwise leaves the entry to its successor. Each step runs with ``isReporting``
    /// set, so an entry point that a handler calls from inside its report knows that it must not
    /// wait on the chain.
    ///
    /// The step runs in its own unstructured task, not in the caller's task. A cancel of the caller
    /// (a `Central` operation that times out, or a test task that ends) does not reach the handler,
    /// and does not cut short the caller's wait in ``settle(_:)``. The radio delivers the report in
    /// full, and the caller waits for it in full.
    func enqueueReport(device: UUID, _ step: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = reportChains[device]?.tail
        lastReportSequence += 1
        let sequence = lastReportSequence
        let task = Task { [self] in
            await previous?.value
            await Self.$isReporting.withValue(true) { await step() }
            if reportChains[device]?.sequence == sequence {
                reportChains.removeValue(forKey: device)
            }
        }
        reportChains[device] = ReportChain(tail: task, sequence: sequence)
        return task
    }

    /// Waits for `tail`, the last report that an entry point enqueued, to be delivered, so the
    /// entry point returns only after its reports have reached the handler. There is nothing to
    /// wait for when it enqueued none.
    ///
    /// **Do not call this from inside a report.** A handler's `subscriptionChanged` can call back
    /// into the radio (`setServices`, `disconnect`, `remove`, a new `register`). That call runs
    /// inside a chain step, and the reports that it enqueues are chained behind that same step.
    /// Waiting for them there is a deadlock:
    ///
    /// - The wait waits for the step to finish.
    /// - The step waits for the handler to return.
    /// - The handler waits for this wait.
    ///
    /// Inside a report (``isReporting`` set), this method thus returns at once. The entry point
    /// returns before the radio delivers its reports, and the radio still delivers them, in order,
    /// after the handler returns.
    func settle(_ tail: Task<Void, Never>?) async {
        guard let tail, !Self.isReporting else { return }
        await tail.value
    }

    /// Pushes a notification to every subscribed, connected central. See
    /// ``VirtualDeviceHandle/notify(_:for:to:)``.
    ///
    /// **The radio truncates the value to each subscriber's `maximumUpdateValueLength`.** This
    /// length is the device's ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``.
    /// CoreBluetooth truncates a notification that does not fit the subscriber's MTU. A payload
    /// passed whole would arrive intact here and clipped on a device.
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

    /// Attaches a backend under `session`. The radio routes radio-initiated
    /// ``BLESwiftCore/CentralEvent``s to `centralSink`, which must hop onto the backend's queue.
    ///
    /// The radio does *not* push which identifiers a backend may vend a remote for. The backend
    /// reads ``knownDeviceIDs`` live, so a device registered a moment ago is retrievable without
    /// waiting on this actor.
    func attach(
        session: UUID,
        centralSink: @escaping @Sendable (CentralEvent) -> Void
    ) {
        sessions[session] = Session(centralSink: centralSink)
    }

    /// Detaches a backend. The radio cancels its scan and drops its connections, per-device sinks,
    /// and subscriptions: the whole session record. The radio reports each dropped subscription to
    /// its device's handler as an unsubscribe, from that device's report chain. This method returns
    /// after the radio delivers every one of them, except for a call from inside a subscription
    /// report. See ``isReporting``.
    func detach(session: UUID) async {
        guard let removed = sessions.removeValue(forKey: session) else { return }
        removed.scanner?.repeater?.cancel()
        var dropped: [(device: UUID, handler: any VirtualDeviceHandler, central: Subscriber, characteristics: [CharacteristicIdentifier])] = []
        for device in removed.connections {
            guard let handler = devices[device]?.handler else { continue }
            dropped.append((device, handler, subscriber(session, device: device), dropSubscriptions(session: session, device: device)))
        }
        // Settle every table before the first `await`, so a handler that calls back into the radio
        // cannot observe a half-detached session. Take each handler and subscriber now, so a
        // removal or a re-registration between the reports cannot redirect them. Each device's
        // reports go on its own chain. Waiting for every chain's tail leaves no report undelivered
        // on return.
        var tails: [Task<Void, Never>] = []
        for entry in dropped {
            if let tail = reportUnsubscribed(entry.characteristics, on: entry.device, handler: entry.handler, central: entry.central) {
                tails.append(tail)
            }
        }
        for tail in tails {
            await settle(tail)
        }
    }

    // MARK: - Scanning

    /// Starts a scan for `session`. The radio reports one sighting for each matching advertising
    /// device immediately. When `allowDuplicates` is set, it reports again once each second after
    /// that.
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

    /// Whether `session` has a scanner installed now.
    ///
    /// This is a test hook, not API. A test uses it to assert that a scan and the `stopScan` right
    /// behind it left nothing running.
    package func hasScanner(session: UUID) -> Bool {
        sessions[session]?.scanner != nil
    }

    /// How many sessions are subscribed to `characteristic` on `device`.
    ///
    /// This is a test hook, not API. A test uses it to assert that a refused
    /// ``setNotify(_:device:characteristic:session:)`` left no entry behind, and that a
    /// ``detach(session:)`` cleared the entries that existed.
    package func subscriberCount(device: UUID, characteristic: CharacteristicIdentifier) -> Int {
        subscriptions[device]?[characteristic]?.count ?? 0
    }

    /// Whether `characteristic` has a subscriber now, on any device that this radio hosts. If the
    /// call names a `session`, the check is for that session. Otherwise it is for any session.
    ///
    /// This is a test hook, not API. It is the "notifications are armed" signal that a test waits
    /// on, because a `Central` publishes none. A fixed delay would let a starved runner pass with
    /// nothing yet subscribed. This is the state that the push itself consults, so a wait on it
    /// cannot be early.
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

    /// Whether `session` holds a connection to `device` now, as the radio sees it.
    ///
    /// This is a test hook, not API. A test uses it to assert that a backend's remote agrees with
    /// the radio about a connection after a race between a connect and a forced disconnect has
    /// settled.
    package func isConnected(session: UUID, device: UUID) -> Bool {
        isConnected(session: session, to: device)
    }

    /// Stops the scan of `session`, if any.
    func stopScan(session: UUID) {
        sessions[session]?.scanner?.repeater?.cancel()
        sessions[session]?.scanner = nil
    }

    /// Reports every advertising device that matches the scan filter of `session`, once.
    func emitSightings(for session: UUID) {
        guard let state = sessions[session], let scanner = state.scanner else { return }
        for device in devices.values where device.isAdvertising && matches(scanner.services, device) {
            state.centralSink(sighting(of: device))
        }
    }

    /// Reports one device to every active scanner whose filter it matches. The radio uses this when
    /// a device starts advertising after a scan has started.
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

    /// Whether a device's advertisement satisfies a scan's service filter. A `nil` or empty filter
    /// matches every device, as in CoreBluetooth.
    private func matches(_ services: [ServiceIdentifier]?, _ device: DeviceState) -> Bool {
        guard let services, !services.isEmpty else { return true }
        let advertised = Set(device.descriptor.advertisement.serviceUUIDs ?? [])
        return !advertised.isDisjoint(with: services)
    }

    // MARK: - Connections

    /// Connects `session` to `device`. The radio routes the device's radio-initiated events to
    /// `sink`, which must hop onto the backend's queue. The sink's registration is part of the
    /// connection, so a notification never outruns its delivery path.
    ///
    /// The radio answers the name and the one-packet length here, because the device could be
    /// removed between two hops.
    ///
    /// The radio consumes an armed connection failure here, behind the session and device guards.
    /// An unregistered device thus fails with ``unknownDeviceError``. A failed attempt records
    /// neither the connection nor the sink. A session that is already connected succeeds and does
    /// not consume the failure, because a failure would leave a connected remote that reports
    /// itself disconnected.
    ///
    /// - Returns: The error that fails the attempt, or the connected device's name and its
    ///   ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``.
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

    /// Disconnects `session` from `device`. The radio drops its subscriptions and reports each of
    /// them to the device's handler as an unsubscribe. The backend delivers the resulting
    /// `didDisconnect` itself, as CoreBluetooth's `cancelPeripheralConnection(_:)` does, and only
    /// when this call ended the connection.
    ///
    /// - Returns: Whether the radio removed a connection.
    ///   - The value is `false` when the session was not connected to the device: it never was, or
    ///     a forced disconnect, a removal, or a failed connect already settled it. The backend must
    ///     then deliver nothing, because the path that settled it already reported the outcome. A
    ///     second `didDisconnect` would report the peripheral gone twice and overwrite the state of
    ///     a reconnect that had started in between.
    ///   - The radio drops sinks and subscriptions in either case. These operations are idempotent.
    ///
    /// This method returns after the radio reports the unsubscribes, so the backend's
    /// `didDisconnect` follows them. A call from inside a subscription report returns before the
    /// radio delivers them. See ``isReporting``.
    @discardableResult
    func disconnect(session: UUID, device: UUID) async -> Bool {
        let removed = sessions[session]?.connections.remove(device) != nil
        // The sink goes with the connection. The backend delivers the `didDisconnect` itself, so
        // nothing is left to route through the sink.
        sessions[session]?.peripheralSinks.removeValue(forKey: device)
        let dropped = dropSubscriptions(session: session, device: device)
        if let handler = devices[device]?.handler {
            let central = subscriber(session, device: device)
            await settle(reportUnsubscribed(dropped, on: device, handler: handler, central: central))
        }
        return removed
    }

    /// Removes every subscription that `session` holds on `device`. When `services` is given, it
    /// removes only the subscriptions under one of those services.
    ///
    /// - Returns: The characteristics to which `session` really was subscribed, so the radio
    ///   reports exactly those, and no others, to the device's handler.
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
    /// This keeps a hosted `PeripheralHost` (fixture, code-defined, or link-hosted) from holding a
    /// ghost subscriber after the central behind it disconnected, cancelled, or had its backend
    /// detached. CoreBluetooth reports `didUnsubscribe` in exactly those cases.
    ///
    /// The method takes the handler and the subscriber and does not look them up. The radio
    /// delivers the reports later, from the device's chain, and a `remove()` or a new `register`
    /// could land before then and drop the reports or hand them to a handler that never saw these
    /// subscribers. Every caller captures both in the synchronous section that dropped the
    /// subscriptions, and enqueues from there, so the chain's order is the table's order.
    ///
    /// - Returns: The chain step that delivers the reports, for ``settle(_:)``, or `nil` when there
    ///   was nothing to report.
    @discardableResult
    func reportUnsubscribed(
        _ characteristics: [CharacteristicIdentifier],
        on device: UUID,
        handler: any VirtualDeviceHandler,
        central: Subscriber
    ) -> Task<Void, Never>? {
        guard !characteristics.isEmpty else { return nil }
        return enqueueReport(device: device) {
            for characteristic in characteristics {
                await handler.subscriptionChanged(characteristic, central: central, isSubscribed: false)
            }
        }
    }

    // MARK: - GATT

    /// The services of `device` that match `filter` (every service when `filter` is `nil`), after
    /// the device's ``VirtualLatency/discovery`` delay.
    ///
    /// **The delay comes before every guard**, here and in each GATT entry point below, so every
    /// check sees the device's state after the delay has run out. A device that was removed,
    /// registered again, or disconnected from during the delay answers as it would to a request
    /// that arrived then.
    ///
    /// The remote queues its GATT requests behind each other on one chain, so a delayed request
    /// holds up those behind it. ATT does the same on hardware, with one transaction at a time. One
    /// difference: a delay that has started continues after a disconnect. Hardware aborts the
    /// transaction when the link drops. Here the request sleeps out its full delay, and then the
    /// gate refuses it. It holds the chain for the remainder, and the first operation of a
    /// reconnect waits behind it. A `ManualClock` still counts that sleeper. See
    /// ``VirtualLatency``.
    func services(of device: UUID, matching filter: [ServiceIdentifier]?) async -> [ServiceIdentifier] {
        if let delay = latency(for: \.discovery, on: device) { try? await clock.sleep(for: delay) }
        guard let state = devices[device] else { return [] }
        let identifiers = state.descriptor.services.map(\.identifier)
        guard let filter else { return identifiers }
        let requested = Set(filter)
        return identifiers.filter { requested.contains($0) }
    }

    /// The characteristics of `service` on `device` that match `filter`, each paired with the
    /// properties that it advertises. The method applies the device's ``VirtualLatency/discovery``
    /// delay, as ``services(of:matching:)`` does.
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

    /// Whether `session` holds a connection to `device`.
    ///
    /// Every GATT entry point applies this gate. ``notify(device:characteristic:value:to:)`` makes
    /// the same test before it routes a notification. A session that has disconnected, or never
    /// connected, has no ATT bearer to carry a request, so the radio must refuse it. Without the
    /// gate, a stale remote could still read and write, and could plant a subscription that no
    /// ``disconnect(session:device:)`` or ``detach(session:)`` would clean up, because neither
    /// walks a device that the session is not recorded as connected to.
    private func isConnected(session: UUID, to device: UUID) -> Bool {
        sessions[session]?.connections.contains(device) == true
    }

    /// Reads `characteristic` from `offset` on. The radio answers a characteristic with a static
    /// value from the database. Every other read reaches the device's handler. The method refuses a
    /// request in these cases:
    ///
    /// - A session that is not connected to `device`: `ATTError.invalidHandle`.
    /// - A characteristic that declares none of `read`, `notify`, or `indicate`:
    ///   `ATTError.readNotPermitted`.
    /// - An `offset` after the end of a static value: `ATTError.invalidOffset`.
    ///
    /// **The permission check comes before the static short-circuit.** The radio answers a
    /// characteristic that has a fixture value from the database, not through its handler, so a
    /// check made only in the handler (as ``FixtureDeviceHandler`` makes) would be too late. Any
    /// connected central could then read exactly the write-only characteristics that declare a
    /// value. Real hardware refuses that read at the ATT layer, and so does this radio.
    ///
    /// **An injected ATT error comes right after the radio finds the handle**, before the
    /// permission check, the static short-circuit, and the handler. It simulates the peripheral's
    /// ATT answer for a valid handle, so a static-value characteristic fails under it too. See
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

    /// Writes `value` to `characteristic` through the device's handler. The radio refuses a write
    /// from a session that is not connected to `device` with `ATTError.invalidHandle`. It refuses a
    /// characteristic that declares neither `write` nor `writeWithoutResponse` with
    /// `ATTError.writeNotPermitted`.
    ///
    /// The radio enforces permissions and length here, not in the remote, so every route to a
    /// virtual device has the ATT layer's limits. A hosted device has no ``FixtureDeviceHandler``
    /// to refuse for it.
    ///
    /// - A `.withResponse` write longer than ``maximumValueLength`` fails with
    ///   `ATTError.invalidAttributeValueLength`.
    /// - A `.withoutResponse` write longer than
    ///   ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength`` is dropped. The handler
    ///   never sees it and the caller hears nothing.
    /// - An injected ATT error fails a `.withResponse` write only. See
    ///   ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
    /// - The ``VirtualLatency/write`` delay comes first, for a `.withResponse` write only.
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
            // Drop the write, do not refuse it: an unacknowledged write has no response to fail,
            // and CoreBluetooth also reports nothing for a write that does not fit in a packet. The
            // `.success` releases the caller's transmit slot. Nothing reached the device.
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

    /// Subscribes `session` to `characteristic` or unsubscribes it, and reports a real change to
    /// the device's handler.
    ///
    /// - A session that is not connected to `device` changes nothing and tells the handler nothing.
    ///   A subscription that such a session planted would be a ghost subscriber, because
    ///   ``disconnect(session:device:)`` and ``detach(session:)`` skip a device without a
    ///   connection.
    /// - The handler hears only a real membership transition. A repeated enable, or a disable for a
    ///   characteristic that was never subscribed, reports nothing.
    /// - The permission check is the radio's, as in
    ///   ``read(device:characteristic:offset:session:)``. A characteristic without `notify` or
    ///   `indicate` has no CCCD, so the radio refuses the request. A hosted device has no
    ///   ``FixtureDeviceHandler`` to refuse for it. A characteristic that is not in the database
    ///   fails with `ATTError.attributeNotFound`.
    /// - An injected ATT error refuses enabling and disabling alike, because both write the CCCD.
    ///   The set and the handler stay as they were. See
    ///   ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
    /// - The device's ``VirtualLatency/subscribe`` delay comes first.
    ///
    /// The transition goes on the device's report chain, behind every report in flight. The method
    /// returns after delivery, except for a call from inside a subscription report. See
    /// ``isReporting``. In both cases the answer comes from the table.
    ///
    /// - Returns: Whether `session` is subscribed to `characteristic` after the call is applied,
    ///   together with the `ATTError` that fails the request, or `nil` when the call was applied.
    ///   - For a connected session, the first value is `enabled`.
    ///   - For a session that is not connected, or for a refused request, it is the unchanged
    ///     current state.
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
        let handler = state.handler
        let central = subscriber(session, device: device)
        await settle(enqueueReport(device: device) {
            await handler.subscriptionChanged(characteristic, central: central, isSubscribed: enabled)
        })
        return (enabled, nil)
    }

    /// The definition of `characteristic` in `state`'s current database.
    private func definition(of characteristic: CharacteristicIdentifier, in state: DeviceState) -> GATTCharacteristic? {
        state.descriptor.services
            .first { $0.identifier == characteristic.service }?
            .characteristics
            .first { $0.identifier == characteristic }
    }

    /// The ``BLESwiftCore/Subscriber`` that a backend session appears as to `device`'s handler.
    ///
    /// Its `maximumUpdateValueLength` is the device's
    /// ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``, not ``maximumValueLength``,
    /// because a notification is a single ATT packet, as a `.withoutResponse` write is. See
    /// ``maximumWriteWithoutResponseLength``. The default stands in for an unregistered device,
    /// which no caller looks up. ``retire(_:)`` builds the departing subscribers of a retired
    /// registration from its own descriptor and does not use this method.
    func subscriber(_ session: UUID, device: UUID) -> Subscriber {
        Subscriber(
            id: session,
            maximumUpdateValueLength: devices[device]?.descriptor.maximumWriteWithoutResponseLength
                ?? Self.maximumWriteWithoutResponseLength
        )
    }
}

/// One characteristic that discovery revealed: its identifier and the properties that it
/// advertises.
struct CharacteristicDiscovery: Sendable {

    /// The characteristic's identifier.
    let identifier: CharacteristicIdentifier

    /// The operations that the characteristic advertises support for.
    let properties: CharacteristicProperties
}
