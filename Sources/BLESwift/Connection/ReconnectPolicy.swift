//
//  ReconnectPolicy.swift
//  BLESwift
//

/// Declares whether, and how, ``Central`` should automatically retry connecting to a
/// peripheral after an unexpected disconnect (or a connection attempt that failed, timed
/// out, or was cancelled some way other than an explicit ``Central/disconnect(_:)``/
/// ``Central/disconnect(_:immediate:)``/``Central/disconnectAll()``/
/// ``Central/cancelAllOperations(error:)`` call).
///
/// Set per `connect(_:timeout:reconnect:warningOptions:)` call as a single declarative
/// value, independently for each peripheral — each `connect` call's policy governs only that
/// peripheral's own reconnect loop. Observe retry progress via ``Central/connectionEvents()``'s
/// ``ConnectionEvent/reconnecting(_:attempt:)`` case.
///
/// - Note: Reconnection never re-arms any previously-active notification streams — those
///   finish (with an error) at disconnect time, same as every other pending operation.
///   Consumers should re-subscribe via `Peripheral.notifications(for:)` in response to a
///   ``ConnectionEvent/connected(_:)`` event.
public struct ReconnectPolicy: Sendable {

    /// The concrete retry behavior this policy encodes. `internal` — callers only ever see
    /// this through the `Sendable` `ReconnectPolicy` value and its static factories.
    enum Kind: Sendable {
        case never
        case always(maxAttempts: Int?, backoff: Duration)
        case custom(@Sendable (_ attempt: Int, _ error: Error?) async -> Duration?)
    }

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// Never automatically reconnect. The default for every `connect(_:timeout:reconnect:warningOptions:)`
    /// call.
    public static let never = ReconnectPolicy(kind: .never)

    /// Automatically reconnect with a fixed delay between attempts.
    ///
    /// - Parameters:
    ///   - maxAttempts: The maximum number of reconnect attempts to make before giving up.
    ///     `nil` (the default) retries indefinitely.
    ///   - backoff: The fixed delay to wait before each reconnect attempt. Defaults to 2
    ///     seconds.
    public static func always(maxAttempts: Int? = nil, backoff: Duration = .seconds(2)) -> ReconnectPolicy {
        ReconnectPolicy(kind: .always(maxAttempts: maxAttempts, backoff: backoff))
    }

    /// Automatically reconnect using caller-defined logic to decide the delay (or whether to
    /// stop) before each attempt.
    ///
    /// - Parameter nextDelay: Called before every reconnect attempt with the 1-indexed
    ///   attempt number and the error from the most recent failure (`nil` before the first
    ///   attempt only in the unusual case there was no triggering error). Return the delay to
    ///   wait before that attempt, or `nil` to stop retrying.
    public static func custom(
        _ nextDelay: @escaping @Sendable (_ attempt: Int, _ error: Error?) async -> Duration?
    ) -> ReconnectPolicy {
        ReconnectPolicy(kind: .custom(nextDelay))
    }

    /// Whether this policy ever reconnects. `.never` is the only case that doesn't; used to
    /// decide ``ConnectionEvent/disconnected(_:error:willReconnect:)``'s `willReconnect`
    /// flag, and whether a reconnect loop should be started at all — a synchronous
    /// approximation, since `.custom` policies can only truly decide (asynchronously) once
    /// asked for their first delay.
    var isNever: Bool {
        if case .never = kind {
            return true
        }
        return false
    }

    /// Returns the delay to wait before reconnect `attempt` (1-indexed), or `nil` to stop
    /// retrying.
    func nextDelay(attempt: Int, error: Error?) async -> Duration? {
        switch kind {
        case .never:
            return nil
        case .always(let maxAttempts, let backoff):
            if let maxAttempts, attempt > maxAttempts {
                return nil
            }
            return backoff
        case .custom(let nextDelay):
            return await nextDelay(attempt, error)
        }
    }
}
