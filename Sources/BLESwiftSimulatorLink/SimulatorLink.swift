//
//  SimulatorLink.swift
//  BLESwiftSimulatorLink
//

import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation
import BLESwiftCompat17

/// The app-facing entry point that routes the BLESwift backends over the link.
///
/// One call is enough. The app makes the call before it creates its first `Central()` or
/// `PeripheralHost()`. The call routes every default-initialized instance through a host-side
/// provider and not through `CoreBluetooth`. This is the usual adoption in an iOS Simulator
/// target:
///
/// ```swift
/// import BLESwiftSimulatorLink
///
/// #if targetEnvironment(simulator)
/// SimulatorLink.install()
/// #endif
/// ```
///
/// Call this before the app's first `Central()` or `PeripheralHost()`. Those default
/// initializers consult `BackendRegistry` once, when they construct the instance. An install
/// after the app built an instance has no effect on that instance.
///
/// `install()` works through `BackendRegistry`. Nothing in `BLESwiftCore`, `BLESwift`,
/// `BLESwiftLink`, or `BLESwiftProvider` knows that this module exists.
public enum SimulatorLink {

    /// All mutable state. One lock guards it.
    private struct State {
        var endpoint: LinkEndpoint?
    }

    private static let state = Mutex(State())

    /// Routes every `Central()` and `PeripheralHost()` that the app constructs after this call
    /// through a provider at `endpoint`.
    ///
    /// - Parameters:
    ///   - endpoint: The host and port of the provider. If `nil`, the function uses
    ///     `LinkEndpoint.fromEnvironment(_:)` (the `BLESWIFT_LINK` environment variable), and if
    ///     that is unavailable, `LinkEndpoint.default`.
    ///   - clientName: A name that people can read, sent in the handshake for provider-side logs.
    ///     The default is the name of the current process.
    ///   - codec: The codec that encodes link messages. The default is
    ///     `LinkCodec.binaryPropertyList`.
    ///
    /// A repeated call, with the same or different parameters, replaces the registered factories
    /// and the resolved ``endpoint``.
    ///
    /// The registry and ``endpoint`` change together. Both factories go in through
    /// `BackendRegistry.setFactories(central:peripheralManager:)`, which takes one lock from
    /// inside this type's state lock. Thus another thread cannot see an inconsistent state
    /// through `Central()`, `PeripheralHost()`, or ``isInstalled``. It cannot see either of
    /// these:
    ///
    /// - A link-backed central next to the previous peripheral factory.
    /// - A registry that already routes over the link while ``endpoint`` still says `nil`.
    ///
    /// The lock order is this type's state, then the registry's lock. The registry never takes
    /// this type's lock.
    public static func install(
        endpoint: LinkEndpoint? = nil,
        clientName: String = ProcessInfo.processInfo.processName,
        codec: LinkCodec = .binaryPropertyList
    ) {
        let resolvedEndpoint = endpoint ?? LinkEndpoint.fromEnvironment() ?? .default
        state.withLock { state in
            BackendRegistry.setFactories(
                central: { queue in
                    LinkCentral(endpoint: resolvedEndpoint, queue: queue, clientName: clientName, codec: codec)
                },
                peripheralManager: { queue in
                    LinkPeripheralManager(endpoint: resolvedEndpoint, queue: queue, clientName: clientName, codec: codec)
                }
            )
            state.endpoint = resolvedEndpoint
        }
    }

    /// Reverts `Central()` and `PeripheralHost()` to their default `CoreBluetooth` backend.
    ///
    /// Clears both `BackendRegistry` factories and ``endpoint``, under the same lock as
    /// ``install(endpoint:clientName:codec:)``. Repeated calls are safe, including when nothing
    /// is installed.
    public static func uninstall() {
        state.withLock { state in
            BackendRegistry.setFactories(central: nil, peripheralManager: nil)
            state.endpoint = nil
        }
    }

    /// Whether ``install(endpoint:clientName:codec:)`` registered the link backends.
    public static var isInstalled: Bool {
        state.withLock { $0.endpoint != nil }
    }

    /// The endpoint that ``install(endpoint:clientName:codec:)`` resolved and now routes
    /// through. The value is `nil` if the link is not installed.
    public static var endpoint: LinkEndpoint? {
        state.withLock { $0.endpoint }
    }

    /// Dials `endpoint`, completes the link handshake, and then disconnects. It is a light check
    /// for whether a provider listens and accepts clients. It does not leave a session running.
    ///
    /// - Parameters:
    ///   - endpoint: The host and port of the provider. If `nil`, it resolves as in
    ///     ``install(endpoint:clientName:codec:)``.
    ///   - timeout: How long to keep trying before the function gives up. The function retries a
    ///     dial that fails without an answer until this budget ends, because such a failure says
    ///     nothing about whether a provider listens. Two examples are a local stack that refuses
    ///     to open a socket (for example `EADDRINUSE` on a busy machine) and a dial that lost a
    ///     race with the provider's startup.
    /// - Returns: `true` if a provider accepted the handshake within `timeout`. `false` if a
    ///   provider answered and refused, or if the budget ran out. The function never throws.
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
                // A provider answered and said no. A retry cannot change that answer.
                return false
            case .unanswered:
                let left = deadline - ContinuousClock.now
                guard left > .zero else { return false }
                try? await Task.sleep(for: min(.milliseconds(50), left))
            }
        }
        return false
    }

    /// The result of one dial of ``isProviderReachable(_:timeout:)``.
    private enum HandshakeOutcome: Sendable {
        /// A provider answered and accepted the hello.
        case accepted
        /// A provider answered and refused, or it answered with something that is not a hello.
        case refused
        /// Nobody answered within the attempt's budget. The dial failed, the connection was
        /// cancelled, or the host accepted the socket and stayed silent.
        case unanswered
    }

    /// Dials `endpoint` once and completes the link handshake. It gives up after `budget`.
    private static func attemptHandshake(
        with endpoint: LinkEndpoint,
        within budget: Duration
    ) async -> HandshakeOutcome {
        let queue = DispatchQueue(label: "bleswift.simulatorlink.probe")
        let connection = LinkConnection.connect(to: endpoint, codec: .binaryPropertyList, queue: queue)
        defer { connection.cancel() }

        return await withTaskGroup(of: HandshakeOutcome.self) { group in
            group.addTask {
                // Cancellation comes from `group.cancelAll()` below, when the sleep task wins the
                // race. It only sets a flag on this task and does nothing to the in-flight
                // `NWConnection`, so `onCancel` must cancel `connection` explicitly. Otherwise a
                // host that accepts the TCP connection and goes silent, or black-holes the SYN,
                // keeps this continuation suspended until the OS lets the connect or the read
                // fail. That can take tens of seconds, much more than `timeout`. Cancelling
                // `connection` here makes it publish a terminal `.cancelled` state, which
                // `onStateChange` below turns into a `resumeOnce(false)`.
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
                        // If the task was already cancelled when it reached
                        // `withTaskCancellationHandler`, `onCancel` ran *before* the code
                        // installed `onStateChange`. The connection published its terminal
                        // `.cancelled` state and nothing listened, and `start()` then returned
                        // without any action, because it refuses to start a terminal connection.
                        // Nothing would ever resume the continuation. Thus the code checks the
                        // state again now that a handler exists. The one-shot `resumeOnce` makes
                        // an overlap with the handler harmless.
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
