//
//  WithTimeout.swift
//  BLESwift
//

/// Races `operation` against a timer of `duration` on `clock`, with a task group. A `nil`
/// duration disables the timeout. If the timer wins, the function cancels `operation`'s task
/// and throws `error()`.
///
/// Cancellation is cooperative. An `operation` that wraps a `CheckedContinuation` must use
/// `withTaskCancellationHandler` to react to the cancel. Until `operation` returns, this
/// function does not return, because a task group waits for every child task.
///
/// It uses `group.addTask { }` and not a bare `Task { }`, which a grep check forbids elsewhere
/// in `Sources/`.
///
/// - Parameters:
///   - clock: The clock for the timer. It is `Configuration.clock`, so a test can drive it.
///   - duration: How long to wait for `operation`. `nil` disables the timeout.
///   - error: Evaluated lazily. The function throws it if the timer wins the race.
///   - operation: The work to race against the timer.
/// - Returns: The result of `operation`, if it wins the race.
/// - Throws: `error()` if the timer wins. Otherwise, the error that `operation` throws.
func withTimeout<T: Sendable>(
    clock: any Clock<Duration>,
    _ duration: Duration?,
    throwing error: @autoclosure @escaping @Sendable () -> Error,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    guard let duration else {
        return try await operation()
    }

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(for: duration)
            throw error()
        }

        defer { group.cancelAll() }

        guard let result = try await group.next() else {
            // Unreachable. The group has two tasks, so at least one result exists.
            throw error()
        }
        return result
    }
}
