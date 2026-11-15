//
//  ProviderStatusClient.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftLink
import Dispatch
import Foundation
import BLESwiftCompat17

/// The errors that ``ProviderStatusClient/fetch(endpoint:codec:timeout:)`` throws.
public enum ProviderStatusError: Error, Equatable, CustomStringConvertible {
    /// The connection failed before it became ready. The value describes the cause.
    case unreachable(String)
    /// The provider did not accept the hello, or it closed a ready connection without a hello.
    /// The value is the reason.
    case rejected(String)
    /// The provider did not send its status before the timeout.
    case timedOut
    /// The provider sent a message that a status request does not expect, or it closed the
    /// connection after its hello and before its status. The value describes what happened.
    case unexpectedMessage(String)

    public var description: String {
        switch self {
        case .unreachable(let cause):
            "the provider is unreachable: \(cause)"
        case .rejected(let reason):
            "the provider rejected the status request: \(reason)"
        case .timedOut:
            "the provider did not send its status in time"
        case .unexpectedMessage(let detail):
            "the provider sent an unexpected reply: \(detail)"
        }
    }
}

/// Gets a ``BLESwiftLink/ProviderStatus`` snapshot from a running provider.
///
/// ```swift
/// let status = try await ProviderStatusClient.fetch(endpoint: .default)
/// print(status.sessions.count)
/// ```
public enum ProviderStatusClient {

    /// Connects to the provider at `endpoint` as a ``BLESwiftLink/LinkRole/monitor`` client and
    /// returns the status that the provider sends.
    ///
    /// The function sends one `ClientHello`. It then waits for an accepted `ServerHello` and one
    /// `providerStatus` message. It closes the connection before it returns or throws.
    ///
    /// - Parameters:
    ///   - endpoint: Where the provider listens.
    ///   - codec: The codec for the outgoing hello. The default is
    ///     `LinkCodec.binaryPropertyList`.
    ///   - timeout: The maximum time to wait for the status. The default is three seconds.
    /// - Returns: The provider's status.
    /// - Throws: ``ProviderStatusError``.
    public static func fetch(
        endpoint: LinkEndpoint,
        codec: LinkCodec = .binaryPropertyList,
        timeout: Duration = .seconds(3)
    ) async throws -> ProviderStatus {
        let exchange = StatusExchange(
            connection: LinkConnection.connect(
                to: endpoint,
                codec: codec,
                queue: DispatchQueue(label: "bleswift-provider.status")
            )
        )
        return try await exchange.run(timeout: timeout)
    }
}

/// One status request. It resumes its continuation once, with the first outcome.
private final class StatusExchange: Sendable {

    /// The state of the exchange. One lock guards it.
    private struct State {
        var continuation: CheckedContinuation<ProviderStatus, any Error>?
        var didReceiveHello = false
        var didBecomeReady = false
        var isFinished = false
    }

    private let connection: LinkConnection
    private let state = Mutex(State())

    init(connection: LinkConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits for the first outcome.
    func run(timeout: Duration) async throws -> ProviderStatus {
        let deadline = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(ProviderStatusError.timedOut))
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            // The deadline can fire before this point. Then no continuation was stored, so
            // resume this one here.
            let isFinished = state.withLock { state -> Bool in
                guard !state.isFinished else { return true }
                state.continuation = continuation
                return false
            }
            guard !isFinished else {
                connection.cancel()
                continuation.resume(throwing: ProviderStatusError.timedOut)
                return
            }
            connection.onMessage = { [weak self] message in
                self?.receive(message)
            }
            connection.onStateChange = { [weak self] state in
                self?.change(to: state)
            }
            connection.start()
        }
    }

    private func change(to newState: LinkConnection.State) {
        switch newState {
        case .ready:
            state.withLock { $0.didBecomeReady = true }
            connection.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .monitor,
                clientName: "bleswift-provider status"
            )))
        case .failed(let error):
            finishClosed(cause: error.localizedDescription)
        case .cancelled:
            finishClosed(cause: "the connection closed")
        case .idle, .connecting:
            break
        }
    }

    /// Ends the exchange for a connection that closed before the status arrived.
    private func finishClosed(cause: String) {
        let progress = state.withLock { (ready: $0.didBecomeReady, hello: $0.didReceiveHello) }
        if progress.hello {
            finish(.failure(ProviderStatusError.unexpectedMessage(
                "the provider closed the connection before it sent a status"
            )))
        } else if progress.ready {
            // Something accepted the connection and then closed it without a hello. An older
            // provider does this, because it cannot decode the monitor role.
            finish(.failure(ProviderStatusError.rejected(
                "the provider closed the connection without a reply. It may be older than this tool."
            )))
        } else {
            finish(.failure(ProviderStatusError.unreachable(cause)))
        }
    }

    private func receive(_ message: LinkMessage) {
        let didReceiveHello = state.withLock { $0.didReceiveHello }
        switch message {
        case .serverHello(let hello) where !didReceiveHello:
            guard hello.accepted else {
                finish(.failure(ProviderStatusError.rejected(hello.reason ?? "no reason given")))
                return
            }
            state.withLock { $0.didReceiveHello = true }
        case .providerStatus(let status) where didReceiveHello:
            finish(.success(status))
        default:
            finish(.failure(ProviderStatusError.unexpectedMessage(message.trafficSummary)))
        }
    }

    /// Resumes the continuation with `result`, once, and closes the connection.
    private func finish(_ result: Result<ProviderStatus, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<ProviderStatus, any Error>? in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        guard let continuation else { return }
        connection.onMessage = nil
        connection.onStateChange = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
#endif
