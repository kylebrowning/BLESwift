# Connections & Reconnection

Connect with a timeout, react to connection lifecycle events, and configure automatic
reconnection with ``ReconnectPolicy``.

## Overview

BLESwift enforces single-peripheral connection discipline: at most one
connection attempt or established connection is tracked at a time.
``Central/connect(_:timeout:reconnect:warningOptions:)`` throws
``BLESwiftError/multipleConnectNotSupported`` if you call it again while already connecting or
connected.

### Connecting with a timeout

```swift
let peripheral = try await central.connect(
    identifier,
    timeout: .seconds(10),
    reconnect: .never
)
```

`timeout` defaults to 15 seconds; pass `nil` to wait indefinitely. On timeout, `Central` cancels
the pending CoreBluetooth connection attempt and waits for confirmation before throwing
``BLESwiftError/connectionTimedOut`` — the underlying attempt is genuinely torn down, not just
abandoned client-side.

### Reconnect policies

``ReconnectPolicy`` declares reconnection behavior up front as a single value set per
`connect` call, rather than a mutable flag toggled at runtime:

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

A ``ReconnectPolicy`` only ever triggers after a connection is lost (or fails, times out, or is
cancelled) some way *other than* an explicit ``Central/disconnect()``/
``Central/disconnect(immediate:)``/``Central/cancelAllOperations(error:)`` call — those are
always treated as intentional and never trigger a retry, regardless of the policy in effect.

### Connection lifecycle events

``Central/connectionEvents()`` is a multicast stream of every ``ConnectionEvent`` — no replay,
since (unlike Bluetooth state) there's no single "current value" that makes sense to replay to a
late subscriber; use ``Central/connectionState`` for a synchronous snapshot instead.

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

### Notification streams end on disconnect — resubscribe on `.connected`

Every ``Peripheral/notifications(for:policy:)`` stream (see <doc:ReadingWritingNotifications>)
finishes — by throwing — the moment its connection ends, for any reason. Reconnection, whether
manual or via a ``ReconnectPolicy``, **does not** re-arm any previously active notification
stream: BLESwift deliberately does not try to remember and silently re-establish subscriptions
behind your back.

Instead, resubscribe explicitly in response to ``ConnectionEvent/connected(_:)``:

```swift
for await event in await central.connectionEvents() {
    if case .connected = event, case .connected(let peripheral) = await central.connectionState {
        let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
            peripheral.notifications(for: heartRateMeasurement)
        // start consuming `readings` again here
    }
}
```

### Disconnecting mid-backoff

An auto-reconnect loop spends most of its time asleep between attempts — during that backoff
window, ``Central/connectionState`` reports ``ConnectionState/disconnected``, even though a
reconnect attempt is still pending. Calling ``Central/disconnect()``/
``Central/disconnect(immediate:)`` during that window is honored as "stop trying to reconnect":
it cancels the pending reconnect attempt and returns normally, rather than throwing
``BLESwiftError/notConnected`` as it would if there were truly nothing in flight.
``Central/cancelAllOperations(error:)`` does the same. A `disconnect()` call with no connection,
connection attempt, *or* pending reconnect loop still throws ``BLESwiftError/notConnected``.

## See Also

- <doc:GettingStarted>
- <doc:ReadingWritingNotifications>
