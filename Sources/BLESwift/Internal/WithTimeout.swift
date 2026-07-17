//
//  WithTimeout.swift
//  BLESwift
//

/// Races `operation` against a `duration`-long timer, task-group style (Phase 0 finding: no
/// stdlib timeout API exists in Swift 6.2).
///
/// If `duration` is `nil`, `operation` runs with no timeout at all — `withTimeout` becomes a
/// transparent passthrough. Otherwise, whichever of `operation` or the timer finishes first
/// determines the result: if the timer wins, `operation`'s task is cooperatively cancelled
/// (via `group.cancelAll()`) and `error()` is thrown.
///
/// Cancelling `operation`'s task does **not** by itself force it to return — Swift task
/// cancellation is cooperative. For an `operation` built around a `CheckedContinuation` (as
/// ``Central``'s connect flow is), the operation must itself be wrapped in
/// `withTaskCancellationHandler` to observe that cancellation and react (see
/// `Central.awaitConnect(id:policy:timeout:warningOptions:)`); until it does, and per
/// structured concurrency's guarantee that a task group does not return until every child
/// task has actually finished, this function will not return until `operation` genuinely
/// completes (either normally, or by reacting to its own cancellation) — so a timeout here
/// does not necessarily mean `operation` stops running immediately, only that its task has
/// been asked to.
///
/// Uses `withThrowingTaskGroup`'s structured `group.addTask { }` — **not** a bare,
/// unstructured `Task { }` spawn (the pattern grep-forbidden in `Sources/` outside its one
/// ledgered site, ``Central/reconnectTask``). `addTask` is a fundamentally different,
/// *structured*-concurrency API — the child task it creates cannot outlive
/// `withThrowingTaskGroup`'s scope — even though the substring "Task {" is unavoidably
/// present in `addTask { `'s spelling; a literal text search for that guard should
/// disregard `group.addTask` call sites for that reason.
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
