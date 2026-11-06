# Connections & Reconnection

Connect to any number of peripherals, observe connection events, and set automatic reconnection for each peripheral with ``ReconnectPolicy``.

## Overview

``Central`` tracks any number of peripherals at the same time. There is no connection limit. Each connected peripheral has its own connection lifecycle, its own reconnect loop and ``ReconnectPolicy``, and its own GATT and notification state. A connect to peripheral B never conflicts with peripheral A.

``Central/connect(_:timeout:reconnect:warningOptions:compatibility:)`` throws ``BLESwiftError/duplicateConnect(_:)`` in one case only. This is when the same `PeripheralIdentifier` already has a tracked entry (connecting, connected, or disconnecting).

### Connecting with a timeout

```swift
let peripheral = try await central.connect(
    identifier,
    timeout: .seconds(10),
    reconnect: .never
)
```

`timeout` defaults to 15 seconds. Pass `nil` to wait without a limit. When the timeout elapses, `Central` cancels the CoreBluetooth connection attempt and waits for the confirmation. Then it throws ``BLESwiftError/connectionTimedOut``.

### Connecting to multiple peripherals

Every `connect` call is independent. To connect to several peripherals in parallel, call `connect` from a `TaskGroup`:

```swift
let identifiers: [PeripheralIdentifier] = [heartRateMonitor, cyclingSensor, tempProbe]

let peripherals = try await withThrowingTaskGroup(of: Peripheral.self) { group in
    for identifier in identifiers {
        group.addTask {
            try await central.connect(identifier, reconnect: .always())
        }
    }
    var connected: [Peripheral] = []
    for try await peripheral in group {
        connected.append(peripheral)
    }
    return connected
}
```

`await central.connectedPeripherals` returns a snapshot of every connected peripheral, sorted by identifier. ``Central/connectionState(of:)`` returns the state of one peripheral.

### Reconnect policies

A ``ReconnectPolicy`` is one value that you set in each `connect` call. Each peripheral has its own policy. If A uses `.always()` and B uses `.never`, only A reconnects after a drop.

```swift
// Never retry (the default).
try await central.connect(identifier, reconnect: .never)

// Retry with a fixed backoff, up to 5 attempts.
try await central.connect(identifier, reconnect: .always(maxAttempts: 5, backoff: .seconds(2)))

// Retry forever with a fixed backoff.
try await central.connect(identifier, reconnect: .always())

// Custom backoff / give-up logic.
try await central.connect(identifier, reconnect: .custom { attempt, error in
    guard attempt <= 10 else { return nil } // nil stops retrying
    return .seconds(min(30, attempt * 2))
})
```

A policy applies only when a connection is lost, fails, times out, or is cancelled by some other cause than an explicit call. These calls are always intentional and never cause a retry:

- ``Central/disconnect(_:)``
- ``Central/disconnectAll()``
- ``Central/cancelAllOperations(error:)``

A new `connect` call for an identifier cancels the reconnect loop that is in progress for that identifier. It then uses the new policy. The loops of other peripherals do not change.

### Connection events

``Central/connectionEvents()`` is a multicast stream of ``ConnectionEvent`` values for all peripherals. It does not replay. For a snapshot, use ``Central/connectionState(of:)`` or ``Central/connectedPeripherals``. Each event has the `PeripheralIdentifier` that it is about. To track one peripheral, filter by identifier.

```swift
Task {
    for await event in await central.connectionEvents() {
        switch event {
        case .connecting(let id):
            print("Connecting to \(id)...")
        case .connected(let id):
            print("Connected to \(id).")
        case .disconnected(let id, let error, let willReconnect):
            print("Disconnected from \(id): \(String(describing: error)); willReconnect: \(willReconnect)")
        case .reconnecting(let id, let attempt):
            print("Reconnect attempt \(attempt) for \(id)...")
        }
    }
}
```

### Notification streams end on disconnect

By default, a ``Peripheral/notifications(for:policy:survivesReconnect:)`` stream finishes by throwing when its connection ends. See <doc:ReadingWritingNotifications>. A reconnect does not restart the stream. To subscribe again, respond to ``ConnectionEvent/connected(_:)``. Use the identifier in the event to find the peripheral:

```swift
for await event in await central.connectionEvents() {
    if case .connected(let id) = event,
       case .connected(let peripheral) = await central.connectionState(of: id) {
        let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
            peripheral.notifications(for: heartRateMeasurement)
        // start consuming `readings` again here
    }
}
```

### Notification streams across reconnects

To keep a stream through the disconnects that a ``ReconnectPolicy`` will retry, subscribe with `survivesReconnect: true`:

```swift
let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: heartRateMeasurement, survivesReconnect: true)
```

After an unexpected disconnect, the stream emits no values. It keeps the values that it buffered before the disconnect, as its ``BufferingPolicy`` allows. When the reconnect succeeds, BLESwift does these steps:

1. It discovers the services and characteristics again for each surviving characteristic.
2. It enables notifications again with one CCCD write for each characteristic.
3. It continues to deliver values on the **same** stream.

BLESwift then sends one ``ConnectionEvent/notificationsRestored(_:restored:failed:)`` event. `restored` lists the characteristics that notify again. `failed` maps each characteristic that BLESwift could not re-arm to the error that finished its streams.

A surviving stream finishes with an error in these cases:

- **The reconnect policy ends** or the loop is cancelled. The stream throws the original disconnect error, usually ``BLESwiftError/unexpectedDisconnect``.
- **Explicit teardown.** This is ``Central/disconnect(_:)`` (also during a backoff), ``Central/disconnectAll()``, a new ``Central/connect(_:timeout:reconnect:warningOptions:compatibility:)`` that replaces the loop, ``Central/cancelAllOperations(error:)``, or ``Central/stopAndExtractState()``. The stream throws ``BLESwiftError/explicitDisconnect``, or the error of the cancel call.
- **Re-arm failure.** The characteristic is no longer in the GATT table, or the enable call failed. Only the streams of that characteristic finish, for example with ``BLESwiftError/missingCharacteristic(_:)``. Other streams continue. The `failed` value of the event names the characteristic.

The composite helpers never survive a reconnect. These are ``Peripheral/writeAndAwaitNotification(write:to:awaitOn:timeout:)``, ``Peripheral/writeAndAssemble(write:to:assembleFrom:expectedLength:timeout:)``, and ``Peripheral/flush(_:quietPeriod:)``. A helper in progress fails at the disconnect, whatever the reconnect policy is.

### Disconnecting

Each disconnect call affects one peripheral, except ``Central/disconnectAll()``:

- ``Peripheral/disconnect()`` disconnects the peripheral of the handle. Use it when you have a `Peripheral`.
- ``Central/disconnect(_:)`` disconnects one peripheral by identifier. It fails pending operations with ``BLESwiftError/explicitDisconnect``.
- ``Central/disconnectAll()`` cancels every reconnect loop and disconnects every tracked peripheral. It never throws. Read the results on ``Central/connectionEvents()``. It does nothing if no peripheral is tracked.

No disconnect call causes a ``ReconnectPolicy`` retry.

### Disconnecting during a backoff

A reconnect loop sleeps between attempts. During this backoff, ``Central/connectionState(of:)`` returns ``ConnectionState/disconnected`` although a reconnect is pending. In this state, ``Central/disconnect(_:)`` cancels the pending reconnect and returns normally. ``Central/cancelAllOperations(error:)`` does the same for all peripherals. A `disconnect` call for a peripheral with no connection, no attempt, and no pending reconnect throws ``BLESwiftError/notConnected``.

## See Also

- <doc:GettingStarted>
- <doc:ReadingWritingNotifications>
