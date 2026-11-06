# ``BLESwiftSimulatorLink``

Run BLESwift against real or virtual Bluetooth hardware from the iOS Simulator.

## Overview

CoreBluetooth does not work in the iOS Simulator. This module has backends that forward the traffic of `Central` and `PeripheralHost` to a `bleswift-provider` process on the host Mac.

To use the backends, call ``SimulatorLink/install(endpoint:clientName:codec:)`` once at launch. Call it before the app constructs the first `Central()` or `PeripheralHost()`. Then every `Central()` and `PeripheralHost()` uses the link.

```swift
#if targetEnvironment(simulator)
SimulatorLink.install()
#endif
```

The endpoint of the provider comes from the `endpoint` parameter, then from the `BLESWIFT_LINK` environment variable, then from `LinkEndpoint.default`.

Use ``SimulatorLink/isProviderReachable(_:timeout:)`` to check that a provider listens. Use ``SimulatorLink/uninstall()`` to go back to CoreBluetooth.

> Note: `SimulatorLink` and `VirtualRadio` share one registry slot. The last call to `install` replaces the first.

## Backend rules

The backends follow the rules in this section. The ``LinkCentral``, ``LinkPeripheral``, and ``LinkPeripheralManager`` types link here. For the deliberate differences from CoreBluetooth, read the "Where the link differs from CoreBluetooth" list in the BLESwift article "Running in the iOS Simulator".

### Queue confinement

Each backend confines its state to one `DispatchQueue`. A lock does not protect the state.

- Give the same queue to the backend and to the `Central` or `PeripheralHost` that owns it.
- Call each backend method and read each property on that queue. Each one asserts this with `dispatchPrecondition`.
- The backend updates its mirror caches inline on the queue. It delivers each event with `queue.async` and never inline.
- A cache is current when the matching event arrives.
- The one exception is ``LinkPeripheral/name``. Callers can read it off the queue, so a lock protects it.

```swift
let queue = DispatchQueue(label: "ble")
let central = Central(backend: LinkCentral(endpoint: endpoint, queue: queue), queue: queue)
let host = PeripheralHost(
    backend: LinkPeripheralManager(endpoint: endpoint, queue: queue), queue: queue)
```

### Radio state and dropped links

A backend starts with the radio state `.unsupported`. A provider that did not answer looks the same as a machine without Bluetooth. The backend delivers this state when an app attaches an event handler. The provider's `didUpdateState` replaces it.

If an established link drops, these actions occur:

- The radio state returns to `.unsupported` and stays so until the provider reconnects and sends its state.
- A `LinkCentral` reports every peripheral that was not disconnected as disconnected, with `LinkError.providerDisconnected`.
- A `LinkPeripheralManager` sets `isAdvertising` to `false`. It reports each subscriber as gone with a synthesized `didUnsubscribe`.

The subscribers belonged to the session that ended. A reconnect creates new `Subscriber` ids.

### Notification back-pressure

`LinkPeripheralManager.updateValue(_:for:onSubscribed:)` returns `false` when `LinkFlowControl.updateValueWindow` pushes are in flight and not acknowledged. This is the same as a full CoreBluetooth transmit queue.

- The provider acknowledges a push when its backend accepts it.
- The acknowledgement that reopens the window is reported as `readyToUpdateSubscribers`.
- A dropped link empties the window, because the acknowledgements ended with the session. Pushes that a host makes while the link is down are dropped and not sent. The call returns `true`.
- The drop releases a host that waits on the window. The host gets `bluetoothUnavailable`. If the state changes to `.unsupported`, `PeripheralHost` fails every parked readiness waiter in any state but `.poweredOn`.
- If the radio is already `.unsupported`, a drop delivers no state change. The single `readyToUpdateSubscribers` at the reconnect releases a waiter that parked in that state.

### Peripherals that the link did not see

`LinkCentral.retrievePeripherals(withIdentifiers:)` is synchronous, so it cannot ask the provider. It returns a placeholder ``LinkPeripheral`` for any identifier.

- A placeholder has no name and no services. Its state is `.disconnected` until the provider reports a change.
- An unknown identifier fails at the connect, not at the retrieval. The failure is `didFailToConnect` with the `BLESwiftProvider` domain and code `1`.
- `LinkCentral` owns the table of peripherals. It gives the same instance for an identifier every time.
- Each peripheral keeps a mirror of its discovery results, because `isDiscovered`, `properties(of:)`, and `discoveredServices` must answer synchronously.

### L2CAP flow control

A tunneled L2CAP channel moves its bytes as `l2capData` frames under credit-based flow control.

- **Client to provider.** The channel starts with `LinkFlowControl.l2capInitialCredit` bytes of credit. A write splits into chunks of at most a quarter of that credit and uses credit for each chunk. When not enough credit remains, the writer suspends. The provider returns credit only after its own write to the real transport returns, so a slow peer suspends the writer. Waiting writers resume in arrival order.
- **Provider to client.** The channel credits the provider when the bytes arrive, whether or not a consumer is reading. This window limits only the data in flight on the wire. It is not back-pressure. A consumer that does not read does not slow the provider, and the channel's buffer grows.

### Dial retries

A client session dials the provider again after each failure.

- The first `fastRetryAttempts` dials after `start()` are fast. The first dials after each drop of an established link are fast too. They are `min(retryInterval, 100 ms)` apart.
- Every dial after that waits `retryInterval`.
- A successful handshake resets the counter.

The fast dials help when a provider is slow to accept, or when an app starts before its provider. The app then connects about 0.1 seconds after the provider appears.

## Topics

### Installing the link

- ``SimulatorLink``

### Backends

- ``LinkCentral``
- ``LinkPeripheral``
- ``LinkPeripheralManager``
