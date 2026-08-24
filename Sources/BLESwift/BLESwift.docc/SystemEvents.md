# System Connection Events & ANCS

Learn when a peripheral connects to the *system* — via any app or the Bluetooth settings
pane — and connect with Apple Notification Center Service (ANCS) authorization.

## Overview

Two `CBCentralManager` features surface here: connection-event registration
(`registerForConnectionEvents(options:)`) and ANCS
(`CBConnectPeripheralOptionRequiresANCS`). Both are platform-fenced exactly as
CoreBluetooth fences them:

- **Connection events** — available on iOS, tvOS, watchOS, and visionOS; **not macOS**.
- **ANCS** — available on **iOS only**.

### Observing system connection events

`Central.connectionEventRegistration(services:peripherals:)` returns a multicast
`AsyncStream` of ``SystemConnectionEvent`` values — one whenever a matching peripheral
connects to or disconnects from the system, whichever app caused it:

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

`services` and `peripherals` are any-of match criteria. The underlying CoreBluetooth
registration is refcounted: it is issued when the first subscriber's stream is created —
with that call's match options — and cancelled when the last subscriber's stream
terminates. A later call while subscribers exist joins the multicast without
re-registering, so its match options apply only after the registration next restarts from
zero.

### Connecting with ANCS (iOS)

Pass `requiresANCS: true` to `Central.connect(_:...)` to request ANCS authorization for
the connection (`CBConnectPeripheralOptionRequiresANCS`). The flag is remembered for the
connection's lifetime — auto-reconnect attempts reuse it.

```swift
let peripheral = try await central.connect(id, requiresANCS: true)

// Snapshot:
let authorized = await peripheral.ancsAuthorized

// Changes, mirroring centralManager(_:didUpdateANCSAuthorizationFor:):
for await authorized in peripheral.ancsAuthorizationEvents() {
    print("ANCS authorized: \(authorized)")
}
```

`Peripheral.ancsAuthorized` is `false` whenever the peripheral is not currently connected.
`ancsAuthorizationEvents()` is keyed by identifier, like ``Peripheral/serviceChanges()`` —
the stream deliberately survives disconnect and reconnect, and has no replay.

### Testing

`FakeCentral` (BLESwiftTestSupport) scripts both features on every platform:
`simulateConnectionEvent(_:for:)` and `simulateANCSAuthorization(_:for:)` deliver the
corresponding events, and `connectionEventRegistrationCount`/
`connectionEventUnregistrationCount`/`lastConnectRequiresANCS` record what reached the
backend seam. `FakePeripheral.ancsAuthorized` scripts the snapshot value.

## See Also

- <doc:ConnectionsAndReconnection>
- ``SystemConnectionEvent``
