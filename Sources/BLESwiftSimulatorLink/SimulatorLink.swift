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
    ///     `LinkEndpoint.fromEnvironment(_:)` (the `BLESWIFT_LINK` environment
    ///     variable), falling back to `LinkEndpoint.default`.
    ///   - clientName: A human-readable name sent in the handshake, for provider-side
    ///     logging. Defaults to the current process's name.
    ///   - codec: The codec used to encode link messages. Defaults to
    ///     `LinkCodec.binaryPropertyList`.
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
    ///   - timeout: How long to keep trying before giving up. A dial that fails without an
    ///     answer is retried until this budget is spent — the local stack refusing to open a
    ///     socket (an `EADDRINUSE` from a busy machine, say) says nothing about whether a
    ///     provider is listening, and neither does a dial that lost a race with the
    ///     provider's own startup.
    /// - Returns: `true` if a provider accepted the handshake within `timeout`; `false` if a
    ///   provider answered and refused, or if the budget ran out. Never throws.
    public static func isProviderReachable(
        _ endpoint: LinkEndpoint? = nil,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let resolvedEndpoint = endpoint ?? LinkEndpoint.fromEnvironment() ?? .default
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return false }
            switch await attemptHandshake(with: resolvedEndpoint, within: remaining) {
            case .accepted:
                return true
            case .refused:
                // A provider answered and said no. Retrying cannot change that answer.
                return false
            case .unanswered:
                let left = deadline - ContinuousClock.now
                guard left > .zero else { return false }
                try? await Task.sleep(for: min(.milliseconds(50), left))
            }
        }
        return false
    }

    /// What one dial of ``isProviderReachable(_:timeout:)`` established.
    private enum HandshakeOutcome: Sendable {
        /// A provider answered and accepted the hello.
        case accepted
        /// A provider answered and refused, or answered with something that is not a hello.
        case refused
        /// Nobody answered within the attempt's budget: the dial failed, the connection was
        /// cancelled, or the host accepted the socket and stayed silent.
        case unanswered
    }

    /// Dials `endpoint` once and completes the link handshake, giving up after `budget`.
    private static func attemptHandshake(
        with endpoint: LinkEndpoint,
        within budget: Duration
    ) async -> HandshakeOutcome {
        let queue = DispatchSerialQueue(label: "bleswift.simulatorlink.probe")
        let connection = LinkConnection.connect(to: endpoint, codec: .binaryPropertyList, queue: queue)
        defer { connection.cancel() }

        return await withTaskGroup(of: HandshakeOutcome.self) { group in
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
                    await withCheckedContinuation { (continuation: CheckedContinuation<HandshakeOutcome, Never>) in
                        let resumed = Mutex(false)
                        @Sendable func resumeOnce(_ value: HandshakeOutcome) {
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
                                resumeOnce(.unanswered)
                            case .idle, .connecting:
                                break
                            }
                        }
                        connection.onMessage = { message in
                            guard case .serverHello(let hello) = message else {
                                resumeOnce(.refused)
                                return
                            }
                            resumeOnce(hello.accepted ? .accepted : .refused)
                        }
                        connection.start()
                        // If this task was already cancelled when it reached
                        // `withTaskCancellationHandler`, `onCancel` ran *before*
                        // `onStateChange` was installed: the connection published its
                        // terminal `.cancelled` with nothing listening, and `start()` then
                        // returned without doing anything, because it refuses to start a
                        // connection that is already terminal. Nothing would ever resume the
                        // continuation. Re-check the state now that a handler exists; the
                        // one-shot `resumeOnce` makes an overlap with the handler harmless.
                        switch connection.state {
                        case .failed, .cancelled: resumeOnce(.unanswered)
                        case .idle, .connecting, .ready: break
                        }
                    }
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return .unanswered
            }
            let result = await group.next() ?? .unanswered
            group.cancelAll()
            return result
        }
    }
}
