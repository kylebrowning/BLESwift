//
//  Actor+AssumeIsolated.swift
//  BLESwiftCompat16
//

import Dispatch

extension Actor {
    /// `Actor.assumeIsolated` for actors whose executor is a serial `DispatchQueue`.
    /// It works on the 16 tier, where the standard-library version is not available, and from
    /// non-task contexts on every OS, such as a CoreBluetooth delegate callback.
    ///
    /// The check is `dispatchPrecondition(.onQueue(queue))`. The function traps when it runs off
    /// `queue`.
    ///
    /// To raise the floor to the 17 tier, replace `assumeIsolated(onQueue: queue)` with
    /// `assumeIsolated` and delete this file.
    ///
    /// - Important: `queue` must be the queue that the actor's executor uses. If you pass a
    ///   different serial queue, the check passes and the isolation is not sound.
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
