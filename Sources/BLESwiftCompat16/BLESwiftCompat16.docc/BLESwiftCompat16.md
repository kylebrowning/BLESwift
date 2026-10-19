# ``BLESwiftCompat16``

The back-deployment tier that lets BLESwift run on iOS 16, macOS 13, watchOS 9, tvOS 16, and visionOS 1.

## Overview

Below the 17 tier (iOS 17, macOS 14, watchOS 10, tvOS 17, visionOS 1) there is no `DispatchSerialQueue`, no `asUnownedSerialExecutor()`, and no `Actor.assumeIsolated`. This module supplies ``SerialQueueExecutor`` (a `SerialExecutor` over a serial `DispatchQueue`), ``QueueExecutor`` (which picks the real `DispatchSerialQueue` executor on the 17 tier and later, and ``SerialQueueExecutor`` below it), and `assumeIsolated(onQueue:_:)`. ``ExecutorPolicy`` is a test-only knob that forces the 16-tier executor everywhere. It is an implementation detail of BLESwift, not a product.

The procedure for deleting this module when BLESwift's floor is raised to the 17 tier is in the "Back-deployment" article of the BLESwift documentation. It is kept there alone, so that the steps cannot drift between two copies.

## Topics

- ``SerialQueueExecutor``
- ``QueueExecutor``
- ``ExecutorPolicy``
