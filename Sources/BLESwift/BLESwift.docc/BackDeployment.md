# Back-deployment

How BLESwift runs on iOS 16 and 17 while being written for the iOS 18-era standard library, and how to remove each tier.

## Overview

BLESwift's source assumes `Synchronization.Mutex`, `DispatchSerialQueue` as a `SerialExecutor`, and `Actor.assumeIsolated`. Two internal modules provide those below the OS versions that ship them. Neither module is a product; consumers never import them.

| Module | Serves | Provides |
|---|---|---|
| `BLESwiftCompat17` | iOS 17, macOS 14, watchOS 10, tvOS 17, visionOS 1 | `Mutex` on `OSAllocatedUnfairLock` |
| `BLESwiftCompat16` | iOS 16, macOS 13, watchOS 9, tvOS 16 | `SerialQueueExecutor`, `QueueExecutor`, `assumeIsolated(onQueue:_:)` |

`Central` and `PeripheralHost` bind to their serial `DispatchQueue` through `QueueExecutor`, which picks `DispatchSerialQueue`'s own executor on iOS 17 and later and `SerialQueueExecutor` below. Delegate callbacks enter actor-isolated code through `assumeIsolated(onQueue:)` on every OS: it is the standard library's implementation preceded by a `dispatchPrecondition` on the queue, which is the one check that works from a non-task context on every runtime.

### The serial-queue contract

Every API that takes a queue requires a serial one. `DispatchQueue(label:)` and `DispatchSerialQueue(label:)` both qualify. `DispatchQueue.main` is a `DispatchSerialQueue` at runtime and is accepted. On iOS 17 and later a concurrent queue traps at `Central`/`PeripheralHost` init; on iOS 16 it cannot be detected.

### Testing

CI runs the full suite on the newest iOS simulator with the default executor and with `BLESWIFT_FORCE_COMPAT16_EXECUTOR=1` (which makes `QueueExecutor` pick `SerialQueueExecutor` everywhere), and on macOS under Thread Sanitizer with the forced executor; both run on every commit. The CI lane for an iOS 17 simulator is in place and pending the runtime install on the CI runner; it is required to be green before 3.0.0 is tagged. iOS 16 is build-verified only, because no iOS 16 simulator runtime runs on current macOS.

### Raising the floor to iOS 17 (drop `BLESwiftCompat16`)

1. Delete `Sources/BLESwiftCompat16`, `Tests/BLESwiftCompat16Tests`, and their `Package.swift` entries — both target declarations and every `dependencies:` mention of `"BLESwiftCompat16"`.
2. In `Central` and `PeripheralHost`, change `nonisolated let queue: DispatchQueue` to `nonisolated let queue: DispatchSerialQueue`, delete `nonisolated let executor: QueueExecutor`, and return `queue.asUnownedSerialExecutor()` from `unownedExecutor`.
3. In every initializer that accepts a `DispatchQueue` parameter, downcast once and store the result:

   ```swift
   guard let serial = queue as? DispatchSerialQueue else {
       preconditionFailure("BLESwift requires a serial DispatchQueue; \(queue) is not one")
   }
   ```

   This preserves the trap for concurrent queues that `QueueExecutor.init` performs today. Public signatures keep `DispatchQueue`, so there is no second API break.
4. Replace every `assumeIsolated(onQueue: self.queue)` and `assumeIsolated(onQueue: central.queue)` with the standard library's `assumeIsolated`, and remove `import BLESwiftCompat16`.
5. Remove the "iOS 16 executor" simulator matrix cell and the Thread Sanitizer step's environment variable from `.github/workflows/ci.yml`.

### Raising the floor to iOS 18 (drop `BLESwiftCompat17`)

1. Delete `Sources/BLESwiftCompat17`, `Tests/BLESwiftCompat17Tests`, and their `Package.swift` entries.
2. Replace `import BLESwiftCompat17` with `import Synchronization` everywhere.
