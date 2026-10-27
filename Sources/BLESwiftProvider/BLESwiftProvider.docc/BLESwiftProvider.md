# ``BLESwiftProvider``

The host-side provider that serves BLE to simulator apps.

## Overview

`BLESwiftProvider` accepts link connections and serves them from the Mac's real Bluetooth
radio (passthrough), from an in-process virtual radio hosting fixture or code-defined
devices, or both. The `bleswift-provider` executable is a thin command-line front end over
``Provider``; depend on this library directly to host virtual devices written in Swift.

The virtual radio itself (`VirtualRadio`, `VirtualDevice`, `VirtualCentralBackend`, and the
rest) lives in the `BLESwiftVirtualRadio` module, which this one re-exports so existing
`import BLESwiftProvider` code keeps compiling. That module is built for every platform and
documents mocking Bluetooth in-process.

## Topics

### Hosting

- ``Provider``
- ``ProviderConfiguration``
- ``ProviderCommandLine``

### Backends

- ``CompositeCentral``
- ``CompositePeripheralManager``
- ``CoreBluetoothBackends``
