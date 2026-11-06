# System Connection Events & ANCS

Observe when a peripheral connects to the *system*, and connect with Apple Notification Center Service (ANCS) authorization.

## Overview

This article covers two `CBCentralManager` features: connection-event registration (`registerForConnectionEvents(options:)`) and ANCS (`CBConnectPeripheralOptionRequiresANCS`). The platform limits are the same as in CoreBluetooth:

- **Connection events** are available on iOS, tvOS, watchOS, and visionOS. They are **not** available on macOS.
- **ANCS** is available on **iOS only**.

### Observing system connection events

`Central.connectionEventRegistration(services:peripherals:)` returns a multicast `AsyncStream` of ``SystemConnectionEvent`` values. Each value reports that a matching peripheral connected to or disconnected from the system. Any app can cause the event.

```swift
let events = await central.connectionEventRegistration(
    services: [ServiceIdentifier(uuid: "180D")]
)
for await event in events {
    switch event.kind {
    case .peerConnected:
        print("\(event.peripheral) connected to the system")
    case .peerDisconnected:
        print("\(event.peripheral) disconnected from the system")
    }
}
```

`services` and `peripherals` are any-of match criteria. The CoreBluetooth registration is reference-counted. The first subscriber's stream creates it, with the match options of that call. The last subscriber's end cancels it. A call while subscribers exist joins the same stream and does not register again. Its match options apply only after the registration restarts from zero.

### Connecting with ANCS (iOS)

To request ANCS authorization for a connection, pass `requiresANCS: true` to `Central.connect(_:...)`. This sets `CBConnectPeripheralOptionRequiresANCS`. Automatic reconnect attempts use the same value.

```swift
let peripheral = try await central.connect(id, requiresANCS: true)

// Snapshot:
let authorized = await peripheral.ancsAuthorized

// Changes, mirroring centralManager(_:didUpdateANCSAuthorizationFor:):
for await authorized in peripheral.ancsAuthorizationEvents() {
    print("ANCS authorized: \(authorized)")
}
```

`Peripheral.ancsAuthorized` is `false` when the peripheral is not connected. `ancsAuthorizationEvents()` is keyed by identifier, like ``Peripheral/serviceChanges()``. Its stream continues through a disconnect and a reconnect. It does not replay.

### Testing

`FakeCentral` in `BLESwiftTestSupport` scripts both features on every platform:

- `simulateConnectionEvent(_:for:)` and `simulateANCSAuthorization(_:for:)` deliver the events.
- `connectionEventRegistrationCount`, `connectionEventUnregistrationCount`, and `lastConnectRequiresANCS` record what reached the backend.
- `FakePeripheral.ancsAuthorized` sets the snapshot value.

## See Also

- <doc:ConnectionsAndReconnection>
- ``SystemConnectionEvent``
