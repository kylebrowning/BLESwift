//
//  Actor+AssumeIsolated.swift
//  BLESwiftCompat16
//

import Dispatch

extension Actor {
    /// `Actor.assumeIsolated` for actors whose executor is a serial `DispatchQueue`,
    /// usable on the 16 tier (the standard-library one is 17-tier) and from non-task
    /// contexts such as CoreBluetooth delegate callbacks on every OS.
    ///
    /// The check is `dispatchPrecondition(.onQueue(queue))`, which is exactly what the
    /// standard library does for a `DispatchSerialQueue` executor; the cast that follows is
    /// the standard library's own implementation. Traps when called off `queue`.
    ///
    /// To raise the floor to the 17 tier, replace `assumeIsolated(onQueue: queue)` with
    /// `assumeIsolated` and delete this file.
    ///
    /// - Important: `queue` must be the queue the actor's executor is bound to; passing any
    ///   other serial queue makes the check pass and the isolation unsound.
    public nonisolated func assumeIsolated<T>(
        onQueue queue: DispatchQueue,
        _ operation: (isolated Self) throws -> T
    ) rethrows -> T {
        dispatchPrecondition(condition: .onQueue(queue))
        typealias YesActor = (isolated Self) throws -> T
        typealias NoActor = (Self) throws -> T
        return try withoutActuallyEscaping(operation) { (fn: @escaping YesActor) throws -> T in
            try unsafeBitCast(fn, to: NoActor.self)(self)
        }
    }
}
