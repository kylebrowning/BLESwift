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

/// A loopback port nothing is listening on, taken from *outside* the system's ephemeral
/// range so no other test can be handed it.
///
/// Tests that need a port with nothing on it — a client that must retry until a provider
/// appears, a link that must fill its window before it can ever connect — used to take one
/// with a listener on port 0 and cancel it. That port goes straight back into the ephemeral
/// pool, so a test running in parallel could be handed the very same number for its own
/// listener, and then the first test's client dials into it and registers a stray device on
/// a provider belonging to someone else.
///
/// Every other port in this bundle is a system-assigned `port: 0`, and the system assigns
/// only from the ephemeral range (49152 and up on Darwin). A number below that range
/// therefore cannot collide with another test by construction — no serialization needed —
/// and the bind probe below rules out an unrelated process already holding it. Holding the
/// port open instead was tried and rejected: a bound socket that never `listen(2)`s makes
/// the kernel *drop* the SYN rather than refuse it, so the port would read as silently
/// unreachable rather than closed, which is a different thing to test against.
///
/// - Parameter attempts: How many candidates to probe before giving up.
/// - Returns: A port in 20000..<30000 that was free at the moment it was probed.
func closedPort(attempts: Int = 20) throws -> UInt16 {
    struct NoFreePort: Error, CustomStringConvertible {
        var description: String { "no free non-ephemeral loopback port found" }
    }
    for _ in 0..<attempts {
        let candidate = UInt16.random(in: 20000..<30000)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { continue }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = candidate.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian  // 127.0.0.1
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(descriptor)   // released at once: the caller wants the port *closed*, not held
        if bound == 0 { return candidate }
    }
    throw NoFreePort()
}
