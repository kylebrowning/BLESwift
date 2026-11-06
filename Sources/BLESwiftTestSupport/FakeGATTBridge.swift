//
//  FakeGATTBridge.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Dispatch
import Foundation
import BLESwiftCompat17

/// Connects ``FakeCentral`` and ``FakePeripheral`` (central side) with ``FakePeripheralManager``
/// (peripheral side). Without the bridge, these fakes do not connect to each other. With it, a
/// `PeripheralHost` and a `Central` can have a full GATT conversation in one process, with only
/// fakes and no CoreBluetooth or hardware. The bridge installs these hooks to route discovery,
/// reads, writes, subscriptions, and notifications between the two roles:
/// - ``FakePeripheral/onReadRequest``
/// - ``FakePeripheral/onWriteRequest``
/// - ``FakePeripheral/onSubscriptionChange``
/// - ``FakePeripheralManager/onAddService``
/// - ``FakePeripheralManager/onRespond``
/// - ``FakePeripheralManager/onUpdateValue``
///
/// ## Concurrency
/// The two sides live on different `DispatchQueue` values. Each hook runs on the queue of the fake
/// that fired it, and forwards to the other side only with that side's off-queue-safe `simulate…`
/// methods. Each fake therefore stays queue-confined. The only state that the queues share is the
/// request-correlation table (``RequestToken`` to pending central operation). A `Mutex` protects
/// it.
///
/// ## Construction and lifetime
/// Create the bridge with the `async` factory ``make(central:peripheral:manager:subscriber:)``. The
/// factory hops onto each fake's queue to install the hooks. The hooks capture the bridge weakly,
/// so there is no retain cycle. Keep a strong reference to the bridge while the interaction runs.
/// After the bridge is released, the hooks do nothing.
public final class FakeGATTBridge: Sendable {

    /// The central-side fake central. The test scripts the connection on it directly.
    public let central: FakeCentral

    /// The central-side fake peripheral (the remote that the ``Central`` talks to). The bridge
    /// routes its read, write, and subscribe operations to ``manager``.
    public let peripheral: FakePeripheral

    /// The peripheral-side fake manager (the backend that the ``PeripheralHost`` drives). The
    /// bridge mirrors its hosted services, responses, and notifications to ``peripheral``.
    public let manager: FakePeripheralManager

    /// The identity that the central presents to the host. It is the ``Subscriber`` that the host
    /// attributes read and write requests to, and that subscribes to notifications. A test can
    /// assert that it appears in `PeripheralHost/subscribers(for:)`.
    public let subscriber: Subscriber

    /// One in-flight central operation that waits for the host's answer. The table key is the
    /// token that the host sends back in its `respond`.
    private enum PendingRequest: Sendable {
        case read(CharacteristicIdentifier)
        case write(CharacteristicIdentifier)
    }

    /// The request-correlation table. The central queue writes it when it routes a request. The
    /// host queue reads it when the host responds. A `Mutex` protects it.
    private let pending = Mutex<[RequestToken: PendingRequest]>([:])

    /// Creates a bridge. It installs the hooks that route GATT traffic between the central-side
    /// fakes and the peripheral-side fake manager.
    ///
    /// The hook setters are queue-confined, so installation needs an `async` hop onto each fake's
    /// queue. This is why there is a factory and not an `init`.
    ///
    /// - Parameters:
    ///   - central: The central-side fake central. The test scripts the connection on it directly.
    ///   - peripheral: The central-side fake peripheral. The bridge routes its operations to
    ///     `manager`.
    ///   - manager: The peripheral-side fake manager. The bridge mirrors its services, responses,
    ///     and notifications to `peripheral`.
    ///   - subscriber: The identity that the central presents to the host. The default is a new
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

    /// Stores the fakes. ``make(central:peripheral:manager:subscriber:)`` installs the hooks,
    /// because that needs `await`.
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
            // Route a central read to the host. Keep the token to match the response.
            peripheral.onReadRequest = { [weak self] characteristic in
                guard let self else { return }
                let token = self.manager.simulateReadRequest(central: self.subscriber, characteristic: characteristic)
                self.pending.withLock { $0[token] = .read(characteristic) }
            }

            // Route a central write to the host. Only `.withResponse` writes await an
            // acknowledgement.
            peripheral.onWriteRequest = { [weak self] characteristic, data, type in
                guard let self else { return }
                let token = self.manager.simulateWriteRequest(central: self.subscriber, characteristic: characteristic, value: data)
                if type == .withResponse {
                    self.pending.withLock { $0[token] = .write(characteristic) }
                }
            }

            // Forward a notification enable or disable to the host as subscribe or unsubscribe.
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

            // Deliver a host notification to the central side. Respect the targeted centrals.
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

    /// Mirrors one hosted service into the central-side peripheral's discovery state. It runs on
    /// the host's queue, not the central's queue. It therefore calls the off-queue-safe
    /// ``FakePeripheral/simulateMirroredService(_:)``, because ``FakePeripheral/onQueue(_:)`` needs
    /// an `await`, which this synchronous hook cannot use.
    private func mirror(_ service: GATTService) {
        peripheral.simulateMirroredService(service)
    }

    /// Represents an ``ATTError`` as an `NSError` in `CBATTErrorDomain`, as a real `CBPeripheral`
    /// reports it, without importing CoreBluetooth.
    private static func nsError(from attError: ATTError) -> NSError {
        NSError(domain: "CBATTErrorDomain", code: attError.rawValue)
    }
}
