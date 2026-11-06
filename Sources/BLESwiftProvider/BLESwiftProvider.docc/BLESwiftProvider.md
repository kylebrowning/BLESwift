# ``BLESwiftProvider``

The host-side provider that serves BLE to simulator apps.

## Overview

`BLESwiftProvider` accepts link connections from simulator apps. It serves them from one or both of these sources:

- The real Bluetooth radio of the Mac (passthrough).
- An in-process virtual radio that hosts fixture devices or devices that you define in code.

The `bleswift-provider` executable is a thin command-line front end over ``Provider``. To host virtual devices that you write in Swift, depend on this library directly.

The virtual radio (`VirtualRadio`, `VirtualDevice`, `VirtualCentralBackend`, and the other types) is in the `BLESwiftVirtualRadio` module. That module builds for every platform. This module re-exports it, so `import BLESwiftProvider` still gives access to those types.

## Composite backends

``CompositeCentral`` and ``CompositePeripheralManager`` combine several child backends. For example, one composite can use an in-process ``VirtualRadio`` and the Mac's real CoreBluetooth at the same time. Follow these rules.

### Queue

- Every child must be confined to the same `queue` that you give to the composite.
- A child's events already arrive on `queue` asynchronously. The composite forwards them inline. A child on a different queue fails the composite's `dispatchPrecondition`.
- State is confined to `queue`. No lock protects it. Every member asserts this at entry.
- `init(backends:queue:log:)` installs the children's event handlers with `queue.sync`. Do not call it from `queue`. Code that already runs on `queue` must use `init(backends:onQueue:log:)`.
- Build and wire a real `CBCentralManager` on `queue` without a yield.

### Routing and powered-on children

- The composite keeps no map from a peripheral to a backend. `connect`, `cancelPeripheralConnection`, and `respond(to:value:error:)` go to every child. A child that does not know the peripheral or the token ignores the call.
- A child whose radio state is not `CentralState/poweredOn` takes no part. The composite logs each skipped child once.
- CoreBluetooth drops a scan that it receives while it is not powered on. So ``CompositeCentral`` remembers the current scan and the current registration for connection events. It issues both again to a child that changes to `poweredOn`. `stopScan()` and `unregisterForConnectionEvents()` forget what they undo.
- ``CompositePeripheralManager`` publishes its current services again and restarts the advertisement on a child that comes back. Thus `--passthrough` uses the Mac's radio as soon as the user turns it on.
- When a child leaves `poweredOn`, the composite settles what that child still owed and discards its FIFO.

### Completions

`add(_:)` and `startAdvertising(_:)` report once for each child. The composite waits for every powered-on child. Then it emits one `didAddService` or `didStartAdvertising` with the first non-`nil` error. A skipped child counts as complete at once. If no child is powered on, both calls complete with ``CompositePeripheralManager/noPoweredOnBackendError``. The composite forwards every other event unchanged, with two exceptions. It replaces `didUpdateState` with its computed state, and it drops `willRestoreState`.

### Notification pushes

- `updateValue(_:for:onSubscribed:)` keeps one FIFO for each powered-on child. A child that does not take a push gets it from its FIFO, in push order, when its `readyToUpdateSubscribers` arrives.
- Every value reaches every such child exactly once. Two pushes with identical bytes are two pushes.
- A child that is not powered on is skipped and is not queued.
- The method returns `false`, and the composite's window closes, in two cases. A powered-on child that has proved that it serves pushes is a full `queueLimit` behind. Or no child is powered on. In both cases the method pushes and queues nothing. Offer the value again after the next `readyToUpdateSubscribers`.
- A child that has never taken a push and never raised a readiness of its own cannot close the window. An example is a real `CBPeripheralManager` that refuses a push for a characteristic with no live handle. The composite caps that child's FIFO and removes the oldest entry first. A power-down and a power-up clear this state.

## Topics

### Hosting

- ``Provider``
- ``ProviderConfiguration``
- ``ProviderCommandLine``
- ``ProviderFixtureError``

### Backends

- ``CompositeCentral``
- ``CompositePeripheralManager``
- ``CoreBluetoothBackends``
