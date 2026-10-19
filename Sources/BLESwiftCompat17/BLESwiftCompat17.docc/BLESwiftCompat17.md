# ``BLESwiftCompat17``

The back-deployment tier that lets BLESwift run on iOS 17, macOS 14, watchOS 10, tvOS 17, and visionOS 1.

## Overview

The only standard-library facility BLESwift uses that is missing below the iOS 18 tier is `Synchronization.Mutex`. This module supplies a ``Mutex`` with the same shape, built on `OSAllocatedUnfairLock`. It is an implementation detail of BLESwift, not a product: nothing here is supported API for consumers.

To raise BLESwift's floor to the iOS 18 tier, delete this module and its test target and replace `import BLESwiftCompat17` with `import Synchronization` in every file that has it. That swap is not quite mechanical: the real `Synchronization.Mutex` uses typed throws and `sending` on `withLock`, where this shim uses `rethrows`, so a handful of call sites may need `sending`-related fixes once the import is reversed.

## Topics

- ``Mutex``
