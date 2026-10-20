# ``BLESwiftCompat17``

The back-deployment tier that lets BLESwift run on iOS 17, macOS 14, watchOS 10, tvOS 17, and visionOS 1.

## Overview

The only standard-library facility BLESwift uses that is missing below the iOS 18 tier is `Synchronization.Mutex`. This module supplies a ``Mutex`` with the same shape, built on `OSAllocatedUnfairLock`. It is an implementation detail of BLESwift, not a product: nothing here is supported API for consumers.

The procedure for deleting this module when BLESwift's floor is raised to the iOS 18 tier is in the "Back-deployment" article of the BLESwift documentation. It is kept there alone, so that the steps cannot drift between two copies.

## Topics

- ``Mutex``
