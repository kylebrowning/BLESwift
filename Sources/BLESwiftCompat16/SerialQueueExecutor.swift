//
//  SerialQueueExecutor.swift
//  BLESwiftCompat16
//

import Dispatch

/// A `SerialExecutor` over a serial `DispatchQueue`, for OS versions where `DispatchSerialQueue`
/// does not conform to `SerialExecutor`. These versions are earlier than the 17 tier: iOS 17,
/// macOS 14, watchOS 10, tvOS 17, and visionOS 1.
///
/// The executor runs jobs with `queue.async`, so an actor bound to it is isolated to the queue in
/// the same way as with `DispatchSerialQueue.asUnownedSerialExecutor()`.
///
/// On Swift 6.0+ runtimes (the 18 tier), `assumeIsolated` and `preconditionIsolated` call
/// ``checkIsolated()`` when they run outside a task. Older runtimes cannot ask. BLESwift therefore
/// uses `assumeIsolated(onQueue:_:)` (in this module) on every OS.
public final class SerialQueueExecutor: SerialExecutor, @unchecked Sendable {
    /// The serial queue that runs the jobs.
    public let queue: DispatchQueue

    /// - Parameter queue: Must be serial. The code cannot verify this on the 16 tier, so the caller
    ///   must make sure that the queue is serial.
    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// The only `enqueue` witness of the conformance. `enqueue(_: consuming ExecutorJob)` is
    /// availability-gated to the 17 tier, so at this module's floor it cannot be the witness. On
    /// 17-tier and later runtimes, the standard library's default `enqueue(ExecutorJob)` forwards
    /// to this function, so the behavior is the same on every OS.
    public func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    /// An unowned reference to this executor.
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// The runtime's out-of-task isolation check. The runtime calls it on Swift 6.0+ (18-tier)
    /// runtimes when `assumeIsolated` or `preconditionIsolated` runs outside a task.
    ///
    /// This function has the class's availability on purpose. Do not narrow it. A narrower
    /// attribute stops this function from witnessing the requirement. The standard library's
    /// default then takes its place, and the check traps even when the code is on the queue.
    public func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
