//
//  SimulatorLink.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import Synchronization

/// The app-facing entry point for routing BLESwift's backends over the link.
///
/// A single call, made before the app constructs its first `Central()` or `PeripheralHost()`,
/// is enough to route every default-initialized instance through a host-side provider instead
/// of `CoreBluetooth` — the usual adoption in an iOS Simulator target:
///
/// ```swift
/// import BLESwiftSimulatorLink
///
/// #if targetEnvironment(simulator)
/// SimulatorLink.install()
/// #endif
/// ```
///
/// This must run before the app's first `Central()` / `PeripheralHost()`: those default
/// initializers consult `BackendRegistry` once, at construction, so installing after one has
/// already been built has no effect on it.
///
/// `install()` works through `BackendRegistry` — nothing in `BLESwiftCore`, `BLESwift`,
/// `BLESwiftLink`, or `BLESwiftProvider` knows this module exists.
public enum SimulatorLink {

    /// Everything mutable, guarded by one lock.
    private struct State {
        var endpoint: LinkEndpoint?
    }

    private static let state = Mutex(State())

    /// Routes every subsequently-constructed `Central()` / `PeripheralHost()` through a
    /// provider at `endpoint`.
    ///
    /// - Parameters:
    ///   - endpoint: The provider's host and port. `nil` resolves to
    ///     ``BLESwiftLink/LinkEndpoint/fromEnvironment(_:)`` (the `BLESWIFT_LINK` environment
    ///     variable), falling back to ``BLESwiftLink/LinkEndpoint/default``.
    ///   - clientName: A human-readable name sent in the handshake, for provider-side
    ///     logging. Defaults to the current process's name.
    ///   - codec: The codec used to encode link messages. Defaults to
    ///     ``BLESwiftLink/LinkCodec/binaryPropertyList``.
    ///
    /// Idempotent: calling this again — with the same or different parameters — simply
    /// replaces the registered factories and the resolved ``endpoint``.
    public static func install(
        endpoint: LinkEndpoint? = nil,
        clientName: String = ProcessInfo.processInfo.processName,
        codec: LinkCodec = .binaryPropertyList
    ) {
        let resolvedEndpoint = endpoint ?? LinkEndpoint.fromEnvironment() ?? .default
        BackendRegistry.centralFactory = { queue in
            LinkCentral(endpoint: resolvedEndpoint, queue: queue, clientName: clientName, codec: codec)
        }
        BackendRegistry.peripheralManagerFactory = { queue in
            LinkPeripheralManager(endpoint: resolvedEndpoint, queue: queue, clientName: clientName, codec: codec)
        }
        state.withLock { $0.endpoint = resolvedEndpoint }
    }

    /// Reverts `Central()` / `PeripheralHost()` to their default `CoreBluetooth` backend.
    ///
    /// Clears both `BackendRegistry` factories and ``endpoint``. Idempotent; safe to call
    /// even when nothing is installed.
    public static func uninstall() {
        BackendRegistry.centralFactory = nil
        BackendRegistry.peripheralManagerFactory = nil
        state.withLock { $0.endpoint = nil }
    }

    /// Whether ``install(endpoint:clientName:codec:)`` has registered the link backends.
    public static var isInstalled: Bool {
        state.withLock { $0.endpoint != nil }
    }

    /// The endpoint ``install(endpoint:clientName:codec:)`` resolved and is currently routing
    /// through, or `nil` when not installed.
    public static var endpoint: LinkEndpoint? {
        state.withLock { $0.endpoint }
    }

    /// Dials `endpoint` and completes the link handshake, then disconnects — a lightweight
    /// check for "is a provider listening and willing to accept clients", without leaving a
    /// session running.
    ///
    /// - Parameters:
    ///   - endpoint: The provider's host and port. `nil` resolves the same way
    ///     ``install(endpoint:clientName:codec:)`` does.
    ///   - timeout: How long to wait for the provider to accept the handshake before giving up.
    /// - Returns: `true` if a provider accepted the handshake within `timeout`; `false` on any
    ///   failure or timeout. Never throws.
    public static func isProviderReachable(
        _ endpoint: LinkEndpoint? = nil,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let resolvedEndpoint = endpoint ?? LinkEndpoint.fromEnvironment() ?? .default
        let queue = DispatchSerialQueue(label: "bleswift.simulatorlink.probe")
        let connection = LinkConnection.connect(to: resolvedEndpoint, codec: .binaryPropertyList, queue: queue)
        defer { connection.cancel() }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // Cancellation (from `group.cancelAll()` below, once the sleep task wins the
                // race) only flags this task — it does nothing to the in-flight `NWConnection`
                // by itself. Without `onCancel` cancelling `connection` explicitly, a host that
                // accepts the TCP connection and then goes silent (or one that black-holes the
                // SYN outright) leaves this continuation suspended for as long as the OS gives
                // the connect/read a chance to fail, which can be tens of seconds — far past
                // `timeout`. Cancelling `connection` here publishes a terminal `.cancelled`
                // state, which `onStateChange` below turns into a `resumeOnce(false)`.
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        let resumed = Mutex(false)
                        @Sendable func resumeOnce(_ value: Bool) {
                            let shouldResume = resumed.withLock { flag -> Bool in
                                guard !flag else { return false }
                                flag = true
                                return true
                            }
                            guard shouldResume else { return }
                            continuation.resume(returning: value)
                        }
                        connection.onStateChange = { state in
                            switch state {
                            case .ready:
                                connection.send(
                                    .clientHello(
                                        ClientHello(protocolVersion: LinkProtocol.version, role: .central, clientName: "probe")
                                    )
                                )
                            case .failed, .cancelled:
                                resumeOnce(false)
                            case .idle, .connecting:
                                break
                            }
                        }
                        connection.onMessage = { message in
                            guard case .serverHello(let hello) = message else {
                                resumeOnce(false)
                                return
                            }
                            resumeOnce(hello.accepted)
                        }
                        connection.start()
                    }
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
