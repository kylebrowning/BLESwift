# ``BLESwiftVirtualRadio``

An in-process Bluetooth radio that serves virtual devices to a real `Central` or
`PeripheralHost`, on every platform.

## Overview

`BLESwiftVirtualRadio` hosts devices that you describe in code or load from a fixture document. It serves them to any number of `Central` and `PeripheralHost` instances in the same process. It needs no hardware, no entitlement, and no provider process.

The `bleswift-provider` uses this radio. Your app can use it directly for unit tests, UI tests, previews, and demo builds. It works on iOS, macOS, watchOS, tvOS, and visionOS.

To use the radio, register a ``VirtualDevice`` on a ``VirtualRadio``. Then point a `Central` at the radio in one of two ways:

- Call ``VirtualRadio/install(_:)`` once at launch.
- Pass a ``VirtualCentralBackend`` to `Central(backend:queue:)`.

See <doc:InProcessMocking> for both. `BLESwiftProvider` re-exports this module.

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

### Delays on a clock

- ``VirtualRadio/init(clock:)``
- ``VirtualRadio/clock``
- ``VirtualLatency``
- ``VirtualDeviceDescriptor/latency``
- ``VirtualDeviceHandle/setLatency(_:)``

### Limits and MTU

- ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``
- ``VirtualRadio/maximumWriteWithoutResponseLength``
- ``VirtualRadio/maximumValueLength``
- ``VirtualRadio/rssi``

### Backends

- ``VirtualCentralBackend``
- ``VirtualPeripheralRemote``
- ``VirtualPeripheralManagerBackend``
