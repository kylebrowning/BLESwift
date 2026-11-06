# ``BLESwiftCompat17``

The back-deployment tier that lets BLESwift run on iOS 17, macOS 14, watchOS 10, tvOS 17, and visionOS 1.

## Overview

BLESwiftCompat17 is an implementation detail of BLESwift. It is not a product. It has no supported API for consumers.

Below the iOS 18 tier, `Synchronization.Mutex` is the only standard-library type that BLESwift uses and the system does not have. This module supplies a ``Mutex`` with the same shape. It uses `OSAllocatedUnfairLock`.

The steps to delete this module when BLESwift raises its minimum platform to the iOS 18 tier are in the "Back-deployment" article of the BLESwift documentation. That article is the only copy of the steps.

## Topics

- ``Mutex``
