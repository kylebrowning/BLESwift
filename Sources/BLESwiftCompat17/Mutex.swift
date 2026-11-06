//
//  Mutex.swift
//  BLESwiftCompat17
//

import os

/// A replacement for `Synchronization.Mutex` (iOS 18 / macOS 15 / watchOS 11 / tvOS 18 / visionOS
/// 2) on the iOS 16+ floor. It uses `OSAllocatedUnfairLock`.
///
/// The API matches `Synchronization.Mutex`: `init(_:)`, `withLock`, and `withLockIfAvailable`. To
/// raise the floor to the 18 tier, change `import BLESwiftCompat17` to `import Synchronization`
/// in each file. As in the original, the type is `@unchecked Sendable` for any `Value`. The lock
/// guarantees exclusive access.
public struct Mutex<Value>: ~Copyable, @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    /// Creates a mutex that protects `initialValue`.
    public init(_ initialValue: Value) {
        lock = OSAllocatedUnfairLock(uncheckedState: initialValue)
    }

    /// Runs `body` with exclusive access to the value. It is not reentrant. If `body` calls
    /// `withLock` on the same `Mutex`, a deadlock occurs. `Synchronization.Mutex` does the same.
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLockUnchecked(body)
    }

    /// Runs `body` if the lock is free. Otherwise it returns `nil` and does not block.
    public func withLockIfAvailable<R>(_ body: (inout Value) throws -> R) rethrows -> R? {
        try lock.withLockIfAvailableUnchecked(body)
    }
}
