# Connections & Reconnection

Connect to any number of peripherals at once, react to per-peripheral connection lifecycle
events, and configure automatic reconnection independently for each one with
``ReconnectPolicy``.

## Overview

``Central`` tracks any number of peripherals concurrently — there is no connection cap and no
"only one at a time" restriction. Each peripheral you connect gets its own independent entry:
its own connection/disconnection lifecycle, its own auto-reconnect loop and
``ReconnectPolicy``, and its own GATT/notification state. Connecting to peripheral B while
peripheral A is connecting (or connected, or disconnecting) never conflicts.

``Central/connect(_:timeout:reconnect:warningOptions:)`` only ever throws
``BLESwiftError/duplicateConnect(_:)`` when the *same* `PeripheralIdentifier` is targeted while
it already has a tracked entry (connecting, connected, or disconnecting) — connecting to a
different peripheral concurrently is always fine.

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

### Connecting to multiple peripherals at once

Every `connect` call is independent, so connecting to several peripherals concurrently is just
calling `connect` more than once — typically from a `TaskGroup` if you want them to proceed in
parallel rather than one after another:

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

At any point, `await central.connectedPeripherals` gives you a snapshot of every
currently-connected peripheral's handle (sorted by identifier for determinism), and
``Central/connectionState(of:)`` reports one specific peripheral's state.

### Reconnect policies

``ReconnectPolicy`` declares reconnection behavior up front as a single value set per
`connect` call, rather than a mutable flag toggled at runtime. Each peripheral's policy is
independent — connecting to A with `.always()` and B with `.never` means only A auto-reconnects
if it drops:

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
cancelled) some way *other than* an explicit ``Central/disconnect(_:)``/
``Central/disconnect(_:immediate:)``/``Central/disconnectAll()``/
``Central/cancelAllOperations(error:)`` call — those are always treated as intentional and
never trigger a retry for the peripheral(s) they affect, regardless of the policy in effect. A
new `connect` call to a given identifier also cancels any reconnect loop already in flight for
that same identifier and adopts the new call's policy going forward — every other peripheral's
loop is untouched.

### Connection lifecycle events

``Central/connectionEvents()`` is a multicast stream of every ``ConnectionEvent``, across every
peripheral — no replay, since (unlike Bluetooth state) there's no single "current value" that
makes sense to replay to a late subscriber; use ``Central/connectionState(of:)``/
``Central/connectedPeripherals`` for a synchronous snapshot instead. Every case carries the
`PeripheralIdentifier` it's about, so a consumer tracking several peripherals filters by
identifier:

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

Instead, resubscribe explicitly in response to ``ConnectionEvent/connected(_:)``, using the
identifier it carries to look up that peripheral's handle:

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

### Disconnecting

Every disconnect verb is per-peripheral except ``Central/disconnectAll()``:

- ``Peripheral/disconnect(immediate:)`` — the ergonomic call-site: disconnects the peripheral
  the handle refers to. Prefer this when you already have a `Peripheral`.
- ``Central/disconnect(_:)`` — gracefully disconnects one peripheral by identifier; equivalent
  to `disconnect(id, immediate: false)`.
- ``Central/disconnect(_:immediate:)`` — same, with explicit control over whether pending
  operations are failed immediately or drained first.
- ``Central/disconnectAll()`` — best-effort teardown of every tracked peripheral at once: cancels
  every reconnect loop, then disconnects every tracked entry. Never throws — individual outcomes
  are observable on ``Central/connectionEvents()``. Idempotent, and a no-op with nothing tracked.

None of these ever trigger a ``ReconnectPolicy`` retry for the peripheral(s) they affect — an
explicit disconnect is always treated as intentional.

### Disconnecting mid-backoff

An auto-reconnect loop spends most of its time asleep between attempts — during that backoff
window, ``Central/connectionState(of:)`` reports ``ConnectionState/disconnected`` for that
peripheral, even though a reconnect attempt is still pending. Calling
``Central/disconnect(_:)``/``Central/disconnect(_:immediate:)`` for that identifier during that
window is honored as "stop trying to reconnect": it cancels the pending reconnect attempt and
returns normally, rather than throwing ``BLESwiftError/notConnected`` as it would if there were
truly nothing in flight for that peripheral. ``Central/cancelAllOperations(error:)`` does the
same, across every peripheral's pending reconnect loop. A `disconnect(id)` call for a peripheral
with no connection, connection attempt, *or* pending reconnect loop still throws
``BLESwiftError/notConnected``.

## See Also

- <doc:GettingStarted>
- <doc:ReadingWritingNotifications>
