//
//  ReconnectPolicy.swift
//  BLESwift
//

/// Declares whether and how ``Central`` tries again to connect to a peripheral after an
/// unexpected disconnect, or after a failed, timed-out, or cancelled attempt.
///
/// You set it for each call to `connect(_:timeout:reconnect:warningOptions:compatibility:)`.
/// To observe the retries, use ``ConnectionEvent/reconnecting(_:attempt:)``.
///
/// - Note: A reconnect does not enable again the notification streams that were active. They
///   finish with an error at the disconnect. To subscribe again, respond to
///   ``ConnectionEvent/connected(_:)``. The exception is a stream whose subscriber selected
///   `survivesReconnect: true` in ``Peripheral/notifications(for:policy:survivesReconnect:)``.
///   It waits during the gap and continues after the reconnect succeeds (see
///   ``ConnectionEvent/notificationsRestored(_:restored:failed:)``).
public struct ReconnectPolicy: Sendable {

    /// The retry behavior that this policy encodes. Callers see it only through the static
    /// factories.
    enum Kind: Sendable {
        case never
        case always(maxAttempts: Int?, backoff: Duration)
        case custom(@Sendable (_ attempt: Int, _ error: Error?) async -> Duration?)
    }

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// Never reconnect automatically. This is the default for
    /// `connect(_:timeout:reconnect:warningOptions:compatibility:)`.
    public static let never = ReconnectPolicy(kind: .never)

    /// Reconnects automatically with a fixed delay between attempts.
    ///
    /// - Parameters:
    ///   - maxAttempts: The maximum number of reconnect attempts before the policy gives up.
    ///     The default `nil` retries without a limit.
    ///   - backoff: The fixed delay to wait before each reconnect attempt. The default is 2
    ///     seconds.
    public static func always(maxAttempts: Int? = nil, backoff: Duration = .seconds(2)) -> ReconnectPolicy {
        ReconnectPolicy(kind: .always(maxAttempts: maxAttempts, backoff: backoff))
    }

    /// Reconnects automatically. Your closure decides the delay before each attempt, or decides
    /// to stop.
    ///
    /// - Parameter nextDelay: BLESwift calls it before each reconnect attempt. It receives the
    ///   attempt number (from 1) and the error from the most recent failure. The error is
    ///   `nil` if no error triggered the reconnect. Return the delay to wait before that
    ///   attempt, or `nil` to stop the retries.
    public static func custom(
        _ nextDelay: @escaping @Sendable (_ attempt: Int, _ error: Error?) async -> Duration?
    ) -> ReconnectPolicy {
        ReconnectPolicy(kind: .custom(nextDelay))
    }

    /// Whether this policy never reconnects. `Central` uses it for `willReconnect` and to
    /// decide whether to start a reconnect loop. It is a synchronous approximation, because a
    /// `.custom` policy decides only when `Central` asks for its first delay.
    var isNever: Bool {
        if case .never = kind {
            return true
        }
        return false
    }

    /// Returns the delay before reconnect `attempt` (from 1), or `nil` to stop the retries.
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
