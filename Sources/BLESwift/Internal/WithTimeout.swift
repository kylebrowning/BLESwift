//
//  WithTimeout.swift
//  BLESwift
//

/// Races `operation` against a `duration`-long timer, task-group style (no stdlib timeout
/// API exists in Swift 6.2). `nil` duration disables the timeout entirely. If the timer
/// wins, `operation`'s task is cooperatively cancelled and `error()` is thrown.
///
/// Cancelling `operation`'s task does **not** by itself force it to return — Swift task
/// cancellation is cooperative. An `operation` built around a `CheckedContinuation` must
/// itself be wrapped in `withTaskCancellationHandler` to react to that; until it does, this
/// function will not return until `operation` genuinely completes, per structured
/// concurrency's guarantee that a task group waits for every child task.
///
/// Uses `group.addTask { }`, not a bare `Task { }` spawn (grep-forbidden elsewhere in
/// `Sources/`) — `addTask` is structured-concurrency, and its child task cannot outlive
/// `withThrowingTaskGroup`'s scope.
///
/// - Parameters:
///   - duration: How long to wait for `operation` before timing out. `nil` disables the
///     timeout entirely.
///   - error: Lazily evaluated; thrown if the timer wins the race.
///   - operation: The work to race against the timer.
/// - Returns: `operation`'s result, if it wins the race.
/// - Throws: `error()` if the timer wins the race; otherwise whatever `operation` throws.
func withTimeout<T: Sendable>(
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
            try await Task.sleep(for: duration)
            throw error()
        }

        defer { group.cancelAll() }

        guard let result = try await group.next() else {
            // Unreachable: two tasks were just added above, so at least one result exists.
            throw error()
        }
        return result
    }
}
