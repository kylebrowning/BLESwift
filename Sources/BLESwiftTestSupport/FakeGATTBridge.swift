//
//  FakeGATTBridge.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation
import Synchronization

/// Interconnects ``FakeCentral``/``FakePeripheral`` (central-side) and
/// ``FakePeripheralManager`` (peripheral-side) — which don't otherwise interconnect — so a
/// `PeripheralHost` and a `Central` can hold a full GATT conversation in one process, over
/// fakes only, with no CoreBluetooth or hardware. Wires each side's bridge hooks
/// (``FakePeripheral/onReadRequest``, ``FakePeripheral/onWriteRequest``,
/// ``FakePeripheral/onSubscriptionChange``, ``FakePeripheralManager/onAddService``,
/// ``FakePeripheralManager/onRespond``, ``FakePeripheralManager/onUpdateValue``) to route
/// discovery, reads, writes, subscriptions, and notifications between the two roles.
///
/// ## Concurrency
/// The two sides live on distinct `DispatchSerialQueue`s. Each bridge hook runs on the queue
/// of the fake that fired it and forwards to the other side only via that side's
/// off-queue-safe `simulate…` methods, preserving each fake's queue-confinement. The
/// request-correlation table (``RequestToken`` → pending central operation) is the only
/// state shared across queues, so it's `Mutex`-protected.
///
/// ## Construction & lifetime
/// Create via the `async` factory ``make(central:peripheral:manager:subscriber:)``, which
/// awaits onto each fake's queue to install hooks. The bridge captures the fakes weakly (no
/// retain cycle); keep a strong reference to the bridge for as long as the interaction runs —
/// once released, hooks become no-ops.
public final class FakeGATTBridge: Sendable {

    /// The central-side fake central; connect is scripted directly on it, not by the bridge.
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
        case read(CharacteristicIdentifier)
        case write(CharacteristicIdentifier)
    }

    /// The request-correlation table. Written on the central's queue (when a request is routed)
    /// and read on the host's queue (when the host responds), so it is `Mutex`-protected.
    private let pending = Mutex<[RequestToken: PendingRequest]>([:])

    /// Creates a bridge, installing the hooks that route GATT traffic between an existing
    /// central-side fake pair and a peripheral-side fake manager.
    ///
    /// Each fake's hook setters are queue-confined, so installing them means an `async` hop
    /// onto each fake's queue — hence this factory rather than `init`.
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

    /// Stores the fakes; hook installation is deferred to
    /// ``make(central:peripheral:manager:subscriber:)`` since it must `await`.
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
            // Route a central read to the host; remember the token to match the response back.
            peripheral.onReadRequest = { [weak self] characteristic in
                guard let self else { return }
                let token = self.manager.simulateReadRequest(central: self.subscriber, characteristic: characteristic)
                self.pending.withLock { $0[token] = .read(characteristic) }
            }

            // Route a central write to the host; only `.withResponse` writes await an ack.
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
            // Mirror every published service into the central's discovery state.
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

    /// Mirrors one hosted service into the central-side peripheral's discovery state. Runs on
    /// the host's queue (distinct from the central's), so it defers to the off-queue-safe
    /// ``FakePeripheral/simulateMirroredService(_:)`` rather than ``FakePeripheral/onQueue(_:)``,
    /// which would require an `await` unavailable from this synchronous hook.
    private func mirror(_ service: GATTService) {
        peripheral.simulateMirroredService(service)
    }

    /// Represents an ``ATTError`` as an `NSError` in `CBATTErrorDomain`, matching what a real
    /// `CBPeripheral` reports, without importing CoreBluetooth.
    private static func nsError(from attError: ATTError) -> NSError {
        NSError(domain: "CBATTErrorDomain", code: attError.rawValue)
    }
}
