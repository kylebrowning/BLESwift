//
//  SerialQueueExecutor.swift
//  BLESwiftCompat16
//

import Dispatch

/// A `SerialExecutor` over a serial `DispatchQueue` for OS versions before
/// `DispatchSerialQueue` gained its own conformance (the 17 tier: iOS 17, macOS 14,
/// watchOS 10, tvOS 17, visionOS 1).
///
/// Jobs are run with `queue.async`, so an actor bound to this executor is isolated to the
/// queue exactly as it would be with `DispatchSerialQueue.asUnownedSerialExecutor()`.
///
/// On Swift 6.0+ runtimes (the 18 tier) the runtime consults ``checkIsolated()`` when a
/// standard-library isolation check — `assumeIsolated`, `preconditionIsolated` — runs
/// outside a task, and that is how those checks come to verify the queue. Older runtimes
/// cannot ask at all, which is why BLESwift itself uses `assumeIsolated(onQueue:_:)` (this
/// module) rather than the standard-library one on every OS.
public final class SerialQueueExecutor: SerialExecutor, @unchecked Sendable {
    public let queue: DispatchQueue

    /// - Parameter queue: Must be serial. Not verifiable on the 16 tier; the caller's contract.
    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// The conformance's only `enqueue` witness. `enqueue(_: consuming ExecutorJob)` is
    /// availability-gated to the 17 tier, so at this module's floor it can never be the
    /// statically chosen witness; declaring it would be dead code. On 17-tier and later
    /// runtimes the standard library's default `enqueue(ExecutorJob)` forwards here, so
    /// behaviour is identical on every OS.
    public func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// The runtime's out-of-task isolation check, consulted on Swift 6.0+ (18-tier) runtimes
    /// whenever `assumeIsolated` or `preconditionIsolated` runs outside a task.
    ///
    /// Declared with the class's own availability, deliberately. It must not be
    /// availability-narrowed below the protocol requirement: a narrower attribute stops this
    /// from witnessing the requirement, the standard library's own default takes its place,
    /// and the check then traps even while genuinely on the queue. (The Swift 6.3 standard
    /// library declares the requirement at the module floor, so an `@available(macOS 15, …)`
    /// attribute here was silently ignored there.) The body needs no availability of its own.
    public func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
