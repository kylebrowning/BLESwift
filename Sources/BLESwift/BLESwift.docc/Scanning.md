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

## See Also

- <doc:GettingStarted>
- <doc:ConnectionsAndReconnection>
