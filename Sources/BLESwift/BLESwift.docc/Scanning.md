# Scanning

Discover nearby peripherals with ``Central/scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``,
a single `AsyncThrowingStream` of ``ScanEvent``.

## Overview

BLESwift steers an ongoing scan with ordinary `AsyncSequence` composition over one stream, rather
than a closure returning a scan-control action:

```swift
for try await event in await central.scan(services: [heartRateService]) {
    // ...
}
```

Only one scan can be active at a time (CoreBluetooth exposes a single physical scanner):
starting a second `scan(...)` while one is already running immediately fails the *new* stream
with ``BLESwiftError/alreadyScanning`` — the original scan is unaffected.

### Stopping a scan

There is no `stopScan()` method. Instead, the scan stops when its stream stops being consumed:

```swift
for try await event in await central.scan(services: [heartRateService]) {
    if case .discovered(let discovery) = event {
        print("Found \(discovery.peripheral)")
        break // stops the scan
    }
}
```

`break`ing out of the loop, cancelling the `Task` iterating it, or letting a `timeout:` elapse
all end the scan. A `timeout:` that elapses finishes the stream cleanly (no error); the radio
leaving ``CentralState/poweredOn`` while scanning finishes it by throwing
``BLESwiftError/bluetoothUnavailable``.

### Blacklisting a peripheral

Blacklisting a peripheral is just filtering the stream yourself, using the standard
library's `AsyncSequence.filter`:

```swift
let blacklisted: Set<UUID> = loadBlacklist()

let filtered = await central.scan(services: [heartRateService]).filter { event in
    switch event {
    case .discovered(let discovery), .updated(let discovery), .lost(let discovery):
        return !blacklisted.contains(discovery.peripheral.uuid)
    }
}

for try await event in filtered {
    // never sees a blacklisted peripheral's events
}
```

### Connecting from a scan

BLESwift has no dedicated "connect" scan action — just call
``Central/connect(_:timeout:reconnect:warningOptions:)`` with a sighted peripheral's identifier:

```swift
for try await event in await central.scan(services: [heartRateService]) {
    if case .discovered(let discovery) = event {
        let peripheral = try await central.connect(discovery.peripheral)
        // the scan is still running here — connecting does not implicitly stop it.
        // `break` if you want that.
    }
}
```

Connecting while a scan is live does not stop or otherwise affect that scan.

### Declarative filtering

Instead of filtering the stream by hand, pass a ``ScanFilter`` to
``Central/scan(filter:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``. Only
``ScanFilter/services`` reaches the radio; every other field is applied per sighting before
anything is reported — a non-matching sighting is dropped entirely (not recorded, not
loss-tracked, no event). All set fields must hold, and ``ScanFilter/custom`` is an arbitrary
escape hatch:

```swift
let filter = ScanFilter(
    services: [heartRateService],
    namePrefix: "Kettle",
    manufacturerID: 0x004C,
    custom: { $0.rssi > -70 }
)

for try await event in await central.scan(filter: filter) {
    // only sightings passing every field arrive here
}
```

When all you want is one device, ``Central/findFirst(matching:timeout:)`` runs the scan for
you, returns the first matching ``Discovery``, and stops the scan — on every exit path,
including timeout and cancellation. `timeout` defaults to `nil` (wait indefinitely), but
passing one is recommended:

```swift
let discovery = try await central.findFirst(matching: filter, timeout: .seconds(10))
let peripheral = try await central.connect(discovery.peripheral)
```

### The saved-device pattern

If you persist a peripheral's ``PeripheralIdentifier/uuid`` across launches,
``Central/connect(identifier:fallbackScan:reconnect:timeout:)`` reconnects to it in one
call: it tries ``Central/knownPeripherals(withIdentifiers:)`` first (no radio), and only if
CoreBluetooth no longer knows the identifier does it run the `fallbackScan` and connect to
whatever that finds:

```swift
let peripheral = try await central.connect(
    identifier: savedUUID,
    fallbackScan: ScanFilter(services: [heartRateService], namePrefix: "Kettle")
)
savedUUID = peripheral.id.uuid // re-persist: the fallback may find a NEW uuid
```

Two things to know: a fallback-found peripheral may have a *different* UUID than the saved
one (CoreBluetooth reassigns UUIDs; rescuing a stale UUID by name/service is the point), so
re-persist ``Peripheral/id`` after connecting — and `timeout` applies to each phase
separately (the fallback scan gets `timeout`, then the connect attempt gets `timeout`
again); it is not a shared budget. Without a `fallbackScan`, an unknown identifier throws
``BLESwiftError/unexpectedPeripheral(_:)``.

### Duplicate sightings and loss tracking

By default (`allowDuplicates: false`), CoreBluetooth reports each peripheral only once per scan
session, as ``ScanEvent/discovered(_:)``. Pass `allowDuplicates: true` to also see repeat
sightings as ``ScanEvent/updated(_:)``, and to track when a peripheral goes quiet:

```swift
for try await event in await central.scan(
    services: [heartRateService],
    allowDuplicates: true,
    rssiThreshold: 8,
    lossTimeout: .seconds(10)
) {
    switch event {
    case .discovered(let discovery):
        print("Discovered \(discovery.peripheral) at \(discovery.rssi) dBm")
    case .updated(let discovery):
        print("Updated \(discovery.peripheral): \(discovery.rssi) dBm")
    case .lost(let discovery):
        print("Lost \(discovery.peripheral)")
    }
}
```

`rssiThreshold` suppresses an ``ScanEvent/updated(_:)``
when the RSSI hasn't moved by at least that many dBm since the last *reported* sighting — it
does not affect loss tracking, and does not apply to ``ScanEvent/discovered(_:)``.
`lossTimeout` is the loss deadline (configurable), refreshed on every sighting, after which an
unseen peripheral is reported as
``ScanEvent/lost(_:)`` and forgotten; a later re-sighting is reported as a fresh
``ScanEvent/discovered(_:)``, not ``ScanEvent/updated(_:)``. Both only matter when
`allowDuplicates` is `true` — otherwise ``ScanEvent/updated(_:)`` and ``ScanEvent/lost(_:)`` are
never emitted.

### Background caveats (iOS)

Apple discourages `allowDuplicates: true` and unscoped scanning (`services: nil`) while
backgrounded — both increase battery/CPU cost, and `allowDuplicates` scanning doesn't work in
the background at all. If either applies, BLESwift automatically fails the scan the moment the app
enters the background:

- `allowDuplicates: true` → ``BLESwiftError/allowDuplicatesInBackgroundNotSupported``
- `services: nil` (or empty) → ``BLESwiftError/missingServiceIdentifiersInBackground``

Passing `nil`/empty `services` also logs a warning at scan start regardless of platform, per
Apple's general guidance against unscoped scanning — prefer always specifying the services
you're interested in.

### You may not need to scan

If you already know a peripheral's identifier — from a previous session, or because you
persist it yourself — ``Central/knownPeripherals(withIdentifiers:)`` resolves it without a
scan at all, synchronously against CoreBluetooth's local cache. And
``Central/systemConnectedPeripherals(withServices:)`` finds peripherals the *system* is
already holding a connection to (by any app on the device, not just yours), by service —
useful when a peripheral never actually disconnected and re-scanning for it would be wasted
radio time. Both hand back a ``PeripheralIdentifier`` you feed straight to
``Central/connect(_:timeout:reconnect:warningOptions:)``, the same as a scan result.

## See Also

- <doc:GettingStarted>
- <doc:ConnectionsAndReconnection>
- <doc:BackgroundRestoration>
