# ``BLESwiftVirtualRadio``

An in-process Bluetooth radio that serves virtual devices to a real `Central` or
`PeripheralHost`, on every platform.

## Overview

`BLESwiftVirtualRadio` hosts devices you describe in code (or load from a fixture document)
and serves them to any number of `Central`s and `PeripheralHost`s in the same process — no
hardware, no entitlement, and no provider process. It is the radio the `bleswift-provider`
runs underneath, available to your app directly: use it for unit tests, UI tests, previews,
and demo builds on iOS, macOS, watchOS, tvOS and visionOS.

Register a ``VirtualDevice`` on a ``VirtualRadio``, then point a `Central` at the radio —
either by installing it once at launch with ``VirtualRadio/install(_:)`` or by handing a
``VirtualCentralBackend`` to `Central(backend:queue:)`. See <doc:InProcessMocking> for both.

`BLESwiftProvider` re-exports this module, so code that already imports it keeps compiling.

## Topics

### Essentials

- <doc:InProcessMocking>
- ``VirtualRadio``
- ``VirtualRadio/install(_:)``
- ``VirtualRadio/uninstall()``
- ``VirtualRadio/installed``

### Describing devices

- ``VirtualDevice``
- ``VirtualDeviceDescriptor``
- ``VirtualDeviceHandler``
- ``VirtualDeviceHandle``
- ``FixtureDeviceHandler``

### Injecting faults

- ``VirtualDeviceHandle/failConnections(with:times:)``
- ``VirtualDeviceHandle/clearConnectionFailures()``
- ``VirtualDeviceHandle/disconnect(_:error:)``
- ``VirtualDeviceHandle/setATTError(_:for:operations:)``
- ``VirtualGATTOperations``
- ``VirtualRadio/peripheralDisconnectedError``

### Backends

- ``VirtualCentralBackend``
- ``VirtualPeripheralRemote``
- ``VirtualPeripheralManagerBackend``
