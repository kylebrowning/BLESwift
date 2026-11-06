# Back-deployment

How BLESwift runs on iOS 16 and 17, and how to remove each compatibility tier when you raise the minimum OS.

## Overview

BLESwift's source uses `Synchronization.Mutex`, `DispatchSerialQueue` as a `SerialExecutor`, and `Actor.assumeIsolated`. Two internal modules provide these on older OS versions. Neither module is a product. Consumers never import them.

| Module | Serves | Provides |
|---|---|---|
| `BLESwiftCompat17` | iOS 17, macOS 14, watchOS 10, tvOS 17, visionOS 1 | `Mutex` on `OSAllocatedUnfairLock` |
| `BLESwiftCompat16` | iOS 16, macOS 13, watchOS 9, tvOS 16 | `SerialQueueExecutor`, `QueueExecutor`, `assumeIsolated(onQueue:_:)` |

`Central` and `PeripheralHost` bind to their serial `DispatchQueue` through `QueueExecutor`. On iOS 17 and later, `QueueExecutor` uses the executor of `DispatchSerialQueue`. On earlier versions it uses `SerialQueueExecutor`. Delegate callbacks enter actor-isolated code through `assumeIsolated(onQueue:)` on every OS. It runs a `dispatchPrecondition` on the queue and then the standard library's `assumeIsolated`.

### The serial-queue contract

Every API that takes a queue requires a serial queue. `DispatchQueue(label:)` and `DispatchSerialQueue(label:)` are serial. `DispatchQueue.main` is a `DispatchSerialQueue` at runtime, so BLESwift accepts it. On iOS 17 and later, a concurrent queue traps at `Central` or `PeripheralHost` initialization. On iOS 16, BLESwift cannot detect a concurrent queue.

### Testing

CI runs the full test suite in these lanes:

- The newest iOS simulator, with the default executor.
- The newest iOS simulator, with `BLESWIFT_FORCE_COMPAT16_EXECUTOR=1`. This makes `QueueExecutor` use `SerialQueueExecutor` on every OS.
- macOS under Thread Sanitizer, with the forced executor.
- An iOS 17 simulator, with the default executor. This is the only lane that runs on a Swift runtime older than iOS 18.

All lanes run on every commit. iOS 16 is build-verified only, because no iOS 16 simulator runtime runs on current macOS.

### Raising the minimum OS to iOS 17 (drop `BLESwiftCompat16`)

1. Delete `Sources/BLESwiftCompat16`, `Tests/BLESwiftCompat16Tests`, and their `Package.swift` entries. Remove both target declarations and every `"BLESwiftCompat16"` in a `dependencies:` list.
2. In `Central` and `PeripheralHost`, change `nonisolated let queue: DispatchQueue` to `nonisolated let queue: DispatchSerialQueue`.
3. In the same types, delete `nonisolated let executor: QueueExecutor`. Return `queue.asUnownedSerialExecutor()` from `unownedExecutor`.
4. In every initializer that takes a `DispatchQueue`, downcast once and store the result. This keeps the trap for concurrent queues that `QueueExecutor.init` performs today. Public signatures keep `DispatchQueue`.

   ```swift
   guard let serial = queue as? DispatchSerialQueue else {
       preconditionFailure("BLESwift requires a serial DispatchQueue; \(queue) is not one")
   }
   ```

5. The two `init(configuration:)` initializers take no queue. They create their own queue with `DispatchQueue(label:)`. Change these calls to `DispatchSerialQueue(label:)`. This needs no downcast.
6. Replace every `assumeIsolated(onQueue: self.queue)` and `assumeIsolated(onQueue: central.queue)` with the standard library's `assumeIsolated`. Remove `import BLESwiftCompat16`.
7. In `.github/workflows/ci.yml`, remove the "iOS 16 executor" simulator matrix cell. In the Thread Sanitizer step, remove `BLESWIFT_FORCE_COMPAT16_EXECUTOR=1` and "with the iOS 16 executor" from the step name.

### Raising the minimum OS to iOS 18 (drop `BLESwiftCompat17`)

1. Delete `Sources/BLESwiftCompat17`, `Tests/BLESwiftCompat17Tests`, and their `Package.swift` entries.
2. Replace `import BLESwiftCompat17` with `import Synchronization` everywhere.
3. Fix the call sites of `withLock`. The shim uses `rethrows`. The real `Synchronization.Mutex` uses typed throws and `sending`. Some call sites can need `sending` fixes.
