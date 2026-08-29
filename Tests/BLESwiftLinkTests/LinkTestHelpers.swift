//
//  LinkTestHelpers.swift
//  BLESwiftLinkTests
//

import Foundation

/// Polls `condition` every 5 ms until it is `true` or `timeout` elapses. Never throws —
/// callers assert on the observable state afterwards, so a timeout surfaces as a normal
/// `#expect` failure with the real values in it.
func waitFor(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// The error ``bounded(_:seconds:_:)`` throws when its body did not settle in time.
///
/// It names the call site, so a suite that would otherwise hang forever fails with the test
/// that hung in the message.
struct TimedOut: Error, CustomStringConvertible {
    /// The label the bound was given — by default the calling test's `#function`.
    let label: String

    /// The bound that elapsed, in seconds.
    let seconds: Double

    var description: String { "\(label) did not complete within \(seconds) s" }
}

/// Where a bounded body parks its result, so the waiter never has to `await` a task it
/// cannot cancel.
///
/// The result is a `Result`, not a value-and-error pair: a body whose own return type is
/// optional may legitimately settle on `nil`, which a pair could not tell from "still
/// running".
private final class Outcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?

    /// The settled result, or `nil` while the body is still running.
    var settled: Result<T, any Error>? { lock.withLock { result } }

    func settle(_ result: Result<T, any Error>) { lock.withLock { self.result = result } }
}

/// Runs `body` and throws ``TimedOut`` after `seconds` instead of hanging the suite.
///
/// Use it for every await a test depends on for completion — most of all `await task.value`,
/// which is *not* cancellable: a message the link dropped would otherwise park the test
/// forever, taking the whole bundle with it. The result is parked in an ``Outcome`` and
/// polled rather than awaited, precisely because racing an uncancellable await against a
/// sleep would hang on exactly the failure this bound exists to catch.
///
/// - Parameters:
///   - label: What is being waited on, in the failure message. Defaults to the caller.
///   - seconds: How long to wait before giving up.
///   - body: The work to bound. Its own errors are rethrown unchanged.
func bounded<T: Sendable>(
    _ label: String = #function,
    seconds: Double = 10,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = Outcome<T>()
    let work = Task {
        do { outcome.settle(.success(try await body())) } catch { outcome.settle(.failure(error)) }
    }
    await waitFor(timeout: .seconds(seconds)) { outcome.settled != nil }
    work.cancel()
    guard let settled = outcome.settled else { throw TimedOut(label: label, seconds: seconds) }
    return try settled.get()
}
