//
//  QueueExecutor.swift
//  BLESwiftCompat16
//

import Dispatch

/// The executor a BLESwift actor binds to its serial `DispatchQueue`, chosen once at init:
/// `DispatchSerialQueue`'s own executor on the 17 tier and later, ``SerialQueueExecutor``
/// below it (or anywhere, when `forceCompat16` is set).
///
/// To raise BLESwift's floor to the 17 tier, replace this type with `DispatchSerialQueue`
/// in `Central` and `PeripheralHost` and delete the module.
public struct QueueExecutor: Sendable {
    private enum Backing: Sendable {
        /// The executor of the `DispatchSerialQueue` in ``queue``, resolved once at init.
        /// The reference is unowned, but ``queue`` retains that same object for the whole
        /// life of this value, so the executor it names outlives every use of this case.
        case dispatchSerial(UnownedSerialExecutor)
        case compat16(SerialQueueExecutor)
    }

    public let queue: DispatchQueue
    private let backing: Backing

    /// Binds `queue` to the executor for the OS this process is running on: the real
    /// `DispatchSerialQueue` executor on the 17 tier and later, ``SerialQueueExecutor`` below
    /// it. `ExecutorPolicy.forceCompat16` (the `BLESWIFT_FORCE_COMPAT16_EXECUTOR` environment
    /// knob) is consulted and, when set, selects ``SerialQueueExecutor`` on every OS.
    ///
    /// - Parameter queue: Must be serial. On the 17 tier this is enforced
    ///   (`DispatchQueue(label:)` produces a `DispatchSerialQueue`; a concurrent queue traps).
    ///   On the 16 tier it is the caller's contract.
    public init(queue: DispatchQueue) {
        self.init(queue: queue, forceCompat16: ExecutorPolicy.forceCompat16)
    }

    /// Test-only. Selects the executor explicitly instead of consulting
    /// `ExecutorPolicy.forceCompat16`, so the suite can drive both code paths in one process.
    ///
    /// - Parameters:
    ///   - queue: See ``init(queue:)``.
    ///   - forceCompat16: Use ``SerialQueueExecutor`` even where `DispatchSerialQueue` is
    ///     available. When true, the 17-tier serial-queue check is skipped entirely, so a
    ///     concurrent `queue` is not detected on any OS.
    @_spi(Testing)
    public init(queue: DispatchQueue, forceCompat16: Bool) {
        self.queue = queue
        if #available(iOS 17, macOS 14, watchOS 10, tvOS 17, visionOS 1, *), !forceCompat16 {
            // Only DispatchSerialQueue conforms to SerialExecutor, so this one cast both
            // enforces the serial contract and resolves the executor. Reached through
            // `any SerialExecutor` because some toolchains hide the availability-gated
            // conformance from name lookup below the 17-tier deployment target.
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

    /// Runs on every executor switch, so it only reads what ``init(queue:forceCompat16:)``
    /// already resolved — no cast, no availability check.
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        switch backing {
        case .dispatchSerial(let executor):
            return executor
        case .compat16(let executor):
            return executor.asUnownedSerialExecutor()
        }
    }
}
