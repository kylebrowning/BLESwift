# ``BLESwiftCompat16``

The back-deployment tier that lets BLESwift run on iOS 16, macOS 13, watchOS 9, tvOS 16, and visionOS 1.

## Overview

BLESwiftCompat16 is an implementation detail of BLESwift. It is not a product. Do not import it in your app.

Below the 17 tier (iOS 17, macOS 14, watchOS 10, tvOS 17, visionOS 1), the system has no `DispatchSerialQueue`, no `asUnownedSerialExecutor()`, and no `Actor.assumeIsolated`. This module supplies these replacements:

- ``SerialQueueExecutor`` is a `SerialExecutor` over a serial `DispatchQueue`.
- ``QueueExecutor`` uses the `DispatchSerialQueue` executor on the 17 tier and later. Below the 17 tier, it uses ``SerialQueueExecutor``.
- `assumeIsolated(onQueue:_:)` replaces `Actor.assumeIsolated`.

``ExecutorPolicy`` is for tests only. It forces the 16-tier executor on every platform.

The steps to delete this module when BLESwift raises its minimum platform to the 17 tier are in the "Back-deployment" article of the BLESwift documentation. That article is the only copy of the steps.

## Topics

- ``SerialQueueExecutor``
- ``QueueExecutor``
- ``ExecutorPolicy``
