//
//  Mutex.swift
//  BLESwiftCompat17
//

import os

/// A drop-in stand-in for `Synchronization.Mutex` (iOS 18 / macOS 15 / watchOS 11 /
/// tvOS 18 / visionOS 2) on the iOS 16+ floor, backed by `OSAllocatedUnfairLock`.
///
/// Call sites are written against `Synchronization.Mutex`'s shape (`init(_:)`, `withLock`,
/// `withLockIfAvailable`) so that raising the floor to the 18 tier is a one-line change per
/// file: `import BLESwiftCompat17` → `import Synchronization`. Like the original, the value
/// is `@unchecked Sendable` regardless of `Value`: the lock guarantees exclusive access.
public struct Mutex<Value>: ~Copyable, @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ initialValue: Value) {
        lock = OSAllocatedUnfairLock(uncheckedState: initialValue)
    }

    /// Runs `body` with exclusive access to the value. Not reentrant: calling `withLock` on
    /// the same `Mutex` from inside `body` deadlocks, exactly as `Synchronization.Mutex` does.
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLockUnchecked(body)
    }

    /// Runs `body` if the lock is free, otherwise returns `nil` without blocking.
    public func withLockIfAvailable<R>(_ body: (inout Value) throws -> R) rethrows -> R? {
        try lock.withLockIfAvailableUnchecked(body)
    }
}
