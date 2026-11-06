//
//  QueueExecutor.swift
//  BLESwiftCompat16
//

import Dispatch

/// The executor that a BLESwift actor binds to its serial `DispatchQueue`. The initializer chooses
/// it once. On the 17 tier and later, it is the `DispatchSerialQueue` executor. Below the 17 tier,
/// or when `forceCompat16` is set, it is ``SerialQueueExecutor``.
///
/// To raise the BLESwift floor to the 17 tier, replace this type with `DispatchSerialQueue` in
/// `Central` and `PeripheralHost`. Then delete the module.
public struct QueueExecutor: Sendable {
    private enum Backing: Sendable {
        /// The executor of the `DispatchSerialQueue` in ``queue``, resolved once by the
        /// initializer. The reference is unowned, but ``queue`` retains that object for the life
        /// of this value, so the executor outlives every use of this case.
        case dispatchSerial(UnownedSerialExecutor)
        case compat16(SerialQueueExecutor)
    }

    /// The serial queue that the executor runs jobs on.
    public let queue: DispatchQueue
    private let backing: Backing

    /// Binds `queue` to the executor for the OS that this process runs on.
    /// - On the 17 tier and later, the executor is the `DispatchSerialQueue` executor.
    /// - Below the 17 tier, the executor is ``SerialQueueExecutor``.
    ///
    /// If `ExecutorPolicy.forceCompat16` is set (`BLESWIFT_FORCE_COMPAT16_EXECUTOR=1`), the
    /// initializer selects ``SerialQueueExecutor`` on every OS.
    ///
    /// - Parameter queue: Must be serial. On the 17 tier, a concurrent queue traps. On the 16 tier,
    ///   the caller must make sure that the queue is serial.
    public init(queue: DispatchQueue) {
        self.init(queue: queue, forceCompat16: ExecutorPolicy.forceCompat16)
    }

    /// For tests only. Selects the executor explicitly and does not read
    /// `ExecutorPolicy.forceCompat16`, so the suite can run both code paths in one process.
    ///
    /// - Parameters:
    ///   - queue: See ``init(queue:)``.
    ///   - forceCompat16: Use ``SerialQueueExecutor`` also where `DispatchSerialQueue` is
    ///     available. This skips the 17-tier serial-queue check, so no OS detects a concurrent
    ///     `queue`.
    @_spi(Testing)
    public init(queue: DispatchQueue, forceCompat16: Bool) {
        self.queue = queue
        if #available(iOS 17, macOS 14, watchOS 10, tvOS 17, visionOS 1, *), !forceCompat16 {
            // Only DispatchSerialQueue conforms to SerialExecutor, so this one cast enforces the
            // serial contract and resolves the executor. The cast goes through `any SerialExecutor`
            // because some toolchains hide the conformance from name lookup below the 17-tier
            // deployment target.
            guard let serial = queue as? any SerialExecutor else {
                preconditionFailure("BLESwift requires a serial DispatchQueue; \(queue) is not one")
            }
            backing = .dispatchSerial(serial.asUnownedSerialExecutor())
        } else {
            backing = .compat16(SerialQueueExecutor(queue: queue))
        }
    }

    /// `true` when ``SerialQueueExecutor`` is in use (16 tier, or forced).
    public var usesCompat16Executor: Bool {
        if case .compat16 = backing { return true }
        return false
    }

    /// The actor runtime calls this on every executor switch. It only reads what
    /// ``init(queue:forceCompat16:)`` already resolved, with no cast and no availability check.
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        switch backing {
        case .dispatchSerial(let executor):
            return executor
        case .compat16(let executor):
            return executor.asUnownedSerialExecutor()
        }
    }
}
