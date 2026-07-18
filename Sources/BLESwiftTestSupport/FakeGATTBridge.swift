//
//  FakeGATTBridge.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation
import Synchronization

/// Interconnects the two otherwise-separate fake families so a `PeripheralHost`'s peripheral
/// role and a `Central`'s central role can hold a full GATT conversation **in one process,
/// entirely over fakes, with no CoreBluetooth and no hardware**.
///
/// On their own, ``FakeCentral``/``FakePeripheral`` (the central-side shim) and
/// ``FakePeripheralManager`` (the peripheral-side shim) don't interconnect: each is scripted in
/// isolation. `FakeGATTBridge` wires a central-side ``FakePeripheral`` to a peripheral-side
/// ``FakePeripheralManager`` through the bridge hooks each fake exposes
/// (``FakePeripheral/onReadRequest``, ``FakePeripheral/onWriteRequest``,
/// ``FakePeripheral/onSubscriptionChange``; ``FakePeripheralManager/onAddService``,
/// ``FakePeripheralManager/onRespond``, ``FakePeripheralManager/onUpdateValue``), so that:
///
/// - **Hosted database → discovery.** Every ``GATTService`` the host publishes with
///   `PeripheralHost/add(_:)` is mirrored into the central-side ``FakePeripheral``'s discovery
///   state (``FakePeripheral/availableServices`` and ``FakePeripheral/scriptedProperties``), so
///   the central discovers exactly the services and characteristics — with the properties — the
///   host actually hosts.
/// - **Central read → host request → response → central result.** A central `read` reaches the
///   host's `PeripheralHost/readRequests()` stream as a ``ReadRequest``; the value the host
///   answers with (`PeripheralHost/respond(to:with:)`) flows back as the central's read result.
/// - **Central write → host request → acknowledgement → central result.** A `.withResponse`
///   `write` reaches `PeripheralHost/writeRequests()` as a ``WriteRequest``; the host's
///   acknowledgement (or ``ATTError`` rejection) flows back as the central's write result.
/// - **Central subscribe → host subscription.** Enabling notifications surfaces on the host's
///   `PeripheralHost/subscriptionEvents()` (and ``PeripheralHost/subscribers(for:)``).
/// - **Host notify → central notification.** A `PeripheralHost/updateValue(_:for:onSubscribed:)`
///   surfaces as a value on the central's `Peripheral/notifications(for:)` stream.
///
/// ## Concurrency
///
/// The central-side fakes and the peripheral-side fake live on **two distinct**
/// `DispatchSerialQueue`s — one per role's actor executor. Every bridge hook runs on the queue
/// of the fake that fired it, and forwards to the other side using only that side's
/// *off-queue-safe* `simulate…` methods (each hops onto its own queue with `queue.async`), so
/// each fake's queue-confinement invariant is preserved end to end. The only state shared across
/// the two queues — the request-correlation table mapping a ``RequestToken`` back to the pending
/// central operation — is held in a `Mutex`. No CoreBluetooth import, no unsafe blocking
/// primitives, and no unchecked `Sendable` conformances.
///
/// ## Construction & lifetime
///
/// Create a bridge with the `async` factory ``make(central:peripheral:manager:subscriber:)`` — it
/// must `await` onto each fake's queue to install the queue-confined hook closures. Those closures
/// capture the bridge **weakly**, so it forms no retain cycle with the fakes; keep a strong
/// reference to the bridge for as long as the interaction runs (a test holding it for the duration
/// of the test body is enough). Once released, the hooks become no-ops and the two fakes revert to
/// their standalone scripted behavior.
public final class FakeGATTBridge: Sendable {

    /// The central-side fake central. Held so the whole link is reachable from one handle;
    /// connection is scripted on it directly (`connectBehavior`, `retrievablePeripherals`) — the
    /// bridge itself only interconnects GATT traffic, not the connect handshake.
    public let central: FakeCentral

    /// The central-side fake peripheral (the remote the ``Central`` talks to). Its read/write/
    /// subscribe operations are routed to ``manager`` by this bridge.
    public let peripheral: FakePeripheral

    /// The peripheral-side fake manager (the backend the ``PeripheralHost`` drives). Its hosted
    /// database, responses, and notifications are surfaced to ``peripheral`` by this bridge.
    public let manager: FakePeripheralManager

    /// The identity the central presents to the host — the ``Subscriber`` that read/write
    /// requests are attributed to and that subscribes to notifications. A test can assert it
    /// appears in `PeripheralHost/subscribers(for:)`.
    public let subscriber: Subscriber

    /// One in-flight central operation awaiting the host's answer, keyed by the token the host
    /// echoes back in its `respond`.
    private enum PendingRequest: Sendable {
        /// A read of `characteristic`; the response `value` becomes the read result.
        case read(CharacteristicIdentifier)
        /// A `.withResponse` write to `characteristic`; the response `error` (or success)
        /// becomes the write result.
        case write(CharacteristicIdentifier)
    }

    /// The request-correlation table. Written on the central's queue (when a request is routed)
    /// and read on the host's queue (when the host responds), so it is `Mutex`-protected.
    private let pending = Mutex<[RequestToken: PendingRequest]>([:])

    /// Creates a bridge interconnecting an existing central-side fake pair and a peripheral-side
    /// fake manager, installing the hooks that route GATT traffic between them.
    ///
    /// Each fake's hook setters (``FakePeripheral/onReadRequest`` et al.) are queue-confined, so
    /// installing them means hopping onto each fake's queue — now an `async` hop (issue #13
    /// replaced the old thread-parking `queue.sync` with `queue.async` + a continuation). That
    /// makes construction asynchronous, so it lives here rather than in `init`.
    ///
    /// - Parameters:
    ///   - central: The central-side fake central (connection is scripted on it directly).
    ///   - peripheral: The central-side fake peripheral whose operations are routed to `manager`.
    ///   - manager: The peripheral-side fake manager whose database/responses/notifications are
    ///     surfaced to `peripheral`.
    ///   - subscriber: The identity the central presents to the host. Defaults to a fresh
    ///     ``Subscriber`` with `maximumUpdateValueLength` 512.
    public static func make(
        central: FakeCentral,
        peripheral: FakePeripheral,
        manager: FakePeripheralManager,
        subscriber: Subscriber = Subscriber(id: UUID(), maximumUpdateValueLength: 512)
    ) async -> FakeGATTBridge {
        let bridge = FakeGATTBridge(central: central, peripheral: peripheral, manager: manager, subscriber: subscriber)
        await bridge.installCentralSideHooks()
        await bridge.installPeripheralSideHooks()
        return bridge
    }

    /// Stores the fakes and correlation table. Hook installation is deferred to ``make(central:peripheral:manager:subscriber:)``
    /// because it must `await` onto each fake's queue.
    private init(
        central: FakeCentral,
        peripheral: FakePeripheral,
        manager: FakePeripheralManager,
        subscriber: Subscriber
    ) {
        self.central = central
        self.peripheral = peripheral
        self.manager = manager
        self.subscriber = subscriber
    }

    // MARK: - Central-side hooks (fire on the central fake's queue)

    private func installCentralSideHooks() async {
        await peripheral.onQueue { [self] in
            // Route a central read to the host as a ReadRequest; remember the token so the
            // host's response can be matched back to this read.
            peripheral.onReadRequest = { [weak self] characteristic in
                guard let self else { return }
                let token = self.manager.simulateReadRequest(central: self.subscriber, characteristic: characteristic)
                self.pending.withLock { $0[token] = .read(characteristic) }
            }

            // Route a central write to the host as a WriteRequest. Only a `.withResponse` write
            // awaits an acknowledgement, so only it registers a pending entry.
            peripheral.onWriteRequest = { [weak self] characteristic, data, type in
                guard let self else { return }
                let token = self.manager.simulateWriteRequest(central: self.subscriber, characteristic: characteristic, value: data)
                if type == .withResponse {
                    self.pending.withLock { $0[token] = .write(characteristic) }
                }
            }

            // Forward enable/disable of notifications to the host as subscribe/unsubscribe.
            peripheral.onSubscriptionChange = { [weak self] characteristic, enabled in
                guard let self else { return }
                if enabled {
                    self.manager.simulateSubscribe(central: self.subscriber, to: characteristic)
                } else {
                    self.manager.simulateUnsubscribe(central: self.subscriber, from: characteristic)
                }
            }
        }
    }

    // MARK: - Peripheral-side hooks (fire on the host fake's queue)

    private func installPeripheralSideHooks() async {
        await manager.onQueue { [self] in
            // Mirror every published service into the central's discovery state, so the central
            // discovers exactly what the host hosts, with matching properties.
            manager.onAddService = { [weak self] service in
                guard let self else { return }
                self.mirror(service)
            }

            // Route the host's answer back to the central as the matching operation's result.
            manager.onRespond = { [weak self] call in
                guard let self else { return }
                guard let request = self.pending.withLock({ $0.removeValue(forKey: call.token) }) else { return }
                let error = call.error.map(Self.nsError(from:))
                switch request {
                case .read(let characteristic):
                    self.peripheral.simulateNotification(for: characteristic, value: call.value, error: error)
                case .write(let characteristic):
                    self.peripheral.simulateWriteCompletion(for: characteristic, error: error)
                }
            }

            // Surface a host notification as a central-side notification, honoring targeting.
            manager.onUpdateValue = { [weak self] call in
                guard let self else { return }
                guard call.returned else { return }
                if let centrals = call.centrals, !centrals.contains(where: { $0.id == self.subscriber.id }) {
                    return
                }
                self.peripheral.simulateNotification(for: call.characteristic, value: call.value)
            }
        }
    }

    // MARK: - Helpers

    /// Mirrors one hosted service into the central-side peripheral's discovery state. Called from
    /// the host fake's queue (the two roles are on distinct serial queues), so it cannot touch the
    /// central-side ``FakePeripheral/availableServices``/``FakePeripheral/scriptedProperties``
    /// setters directly and cannot ``FakePeripheral/onQueue(_:)`` (that awaits, and this fires from
    /// a synchronous hook). Instead it defers to the peripheral's *off-queue-safe*
    /// ``FakePeripheral/simulateMirroredService(_:)``, which hops onto the central's queue itself
    /// (`queue.async`) and performs the read-modify-write there, atomically.
    private func mirror(_ service: GATTService) {
        peripheral.simulateMirroredService(service)
    }

    /// Represents an ``ATTError`` as an `NSError` in `CBATTErrorDomain` with its matching raw
    /// code — the same domain/code a real `CBPeripheral` reports a failed read/write with — so
    /// the central surfaces a host's ATT rejection as a genuine error, without importing
    /// CoreBluetooth here.
    private static func nsError(from attError: ATTError) -> NSError {
        NSError(domain: "CBATTErrorDomain", code: attError.rawValue)
    }
}
