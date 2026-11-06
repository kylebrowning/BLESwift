# Scanning

Find nearby peripherals with ``Central/scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``. It returns one `AsyncThrowingStream` of ``ScanEvent``.

## Overview

You control a scan with normal `AsyncSequence` code on one stream. There is no callback that returns a scan action.

```swift
for try await event in await central.scan(services: [heartRateService]) {
    // ...
}
```

CoreBluetooth has one physical scanner, so only one scan can run at a time. If you start a second `scan(...)` while one runs, the *new* stream fails immediately with ``BLESwiftError/alreadyScanning``. The first scan does not change.

### Stopping a scan

There is no `stopScan()` method. The scan stops when nothing consumes its stream:

```swift
for try await event in await central.scan(services: [heartRateService]) {
    if case .discovered(let discovery) = event {
        print("Found \(discovery.peripheral)")
        break // stops the scan
    }
}
```

These actions stop a scan: a `break` out of the loop, a cancelled `Task`, and an elapsed `timeout:`. An elapsed `timeout:` finishes the stream without an error. If the radio leaves ``CentralState/poweredOn`` during the scan, the stream finishes by throwing ``BLESwiftError/bluetoothUnavailable``.

### Blacklisting a peripheral

To ignore a peripheral, filter the stream with the standard library's `AsyncSequence.filter`:

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

To connect to a peripheral that a scan found, call ``Central/connect(_:timeout:reconnect:warningOptions:compatibility:)`` with its identifier. Connecting does not stop the scan:

```swift
for try await event in await central.scan(services: [heartRateService]) {
    if case .discovered(let discovery) = event {
        let peripheral = try await central.connect(discovery.peripheral)
        // the scan is still running here — connecting does not implicitly stop it.
        // `break` if you want that.
    }
}
```

### Declarative filtering

To filter in the library, pass a ``ScanFilter`` to ``Central/scan(filter:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``. Only ``ScanFilter/services`` goes to the radio. BLESwift applies each other field to each sighting before it reports the sighting. A sighting that does not match is dropped. BLESwift does not record it, track its loss, or send an event. All set fields must match. ``ScanFilter/custom`` accepts any predicate.

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

To find one device, use ``Central/findFirst(matching:timeout:)``. It runs the scan, returns the first matching ``Discovery``, and stops the scan on every exit path, even on timeout and cancellation. `timeout` defaults to `nil`, which waits without a limit. Set a timeout:

```swift
let discovery = try await central.findFirst(matching: filter, timeout: .seconds(10))
let peripheral = try await central.connect(discovery.peripheral)
```

#### Names in filters

``PeripheralIdentifier/cachedName`` is the name exactly as CoreBluetooth reported it, or `nil`. ``PeripheralIdentifier/name`` still returns `"No Name"` when the peripheral has no name. A name filter (``ScanFilter/namePrefix`` or ``ScanFilter/nameExact``) compares the advertised local name. If the advertisement has no local name, it compares `cachedName`. A peripheral with neither name never matches a name filter.

### Saved devices

If you save the ``PeripheralIdentifier/uuid`` of a peripheral, ``Central/connect(identifier:fallbackScan:reconnect:timeout:compatibility:)`` reconnects in one call. It first tries ``Central/knownPeripherals(withIdentifiers:)``, which does not use the radio. If CoreBluetooth no longer knows the identifier, it runs `fallbackScan` and connects to the result:

```swift
let peripheral = try await central.connect(
    identifier: savedUUID,
    fallbackScan: ScanFilter(services: [heartRateService], namePrefix: "Kettle")
)
savedUUID = peripheral.id.uuid // re-persist: the fallback may find a NEW uuid
```

CoreBluetooth can assign a new UUID to a peripheral. The fallback peripheral can have a *different* UUID than the saved UUID. After you connect, save ``Peripheral/id`` again.

`timeout` applies to each phase separately. The fallback scan gets `timeout`, and then the connect gets `timeout` again. Without a `fallbackScan`, an unknown identifier throws ``BLESwiftError/unexpectedPeripheral(_:)``.

### Duplicate sightings and loss tracking

By default (`allowDuplicates: false`), CoreBluetooth reports each peripheral once in a scan session, as ``ScanEvent/discovered(_:)``. To also receive repeat sightings as ``ScanEvent/updated(_:)`` and to detect a peripheral that goes quiet, pass `allowDuplicates: true`:

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

- `rssiThreshold` suppresses an ``ScanEvent/updated(_:)`` when the RSSI changed by less than that many dBm since the last *reported* sighting. It does not change loss tracking. It does not apply to ``ScanEvent/discovered(_:)``.
- `lossTimeout` is the time without a sighting after which BLESwift reports ``ScanEvent/lost(_:)`` and forgets the peripheral. Each sighting resets it. The default is 15 seconds. A later sighting is a new ``ScanEvent/discovered(_:)``.

``ScanEvent/updated(_:)`` and ``ScanEvent/lost(_:)`` occur only when `allowDuplicates` is `true`.

### Background limits (iOS)

Apple does not recommend `allowDuplicates: true` or an unscoped scan (`services: nil`) in the background, and `allowDuplicates` does not work in the background. If your scan uses either, BLESwift fails the scan when the app enters the background:

- `allowDuplicates: true` fails with ``BLESwiftError/allowDuplicatesInBackgroundNotSupported``.
- `services: nil` (or an empty list) fails with ``BLESwiftError/missingServiceIdentifiersInBackground``.

On every platform, a scan with `nil` or empty `services` also logs a warning at the start. Always specify the services that you need.

### When you do not need a scan

If you know the identifier of a peripheral, ``Central/knownPeripherals(withIdentifiers:)`` finds it without a scan. It reads the local CoreBluetooth cache. ``Central/systemConnectedPeripherals(withServices:)`` finds peripherals that the system is already connected to, for any app. Use it when a peripheral never disconnected. Both return a ``PeripheralIdentifier`` that you can pass to ``Central/connect(_:timeout:reconnect:warningOptions:compatibility:)``.

## See Also

- <doc:GettingStarted>
- <doc:ConnectionsAndReconnection>
- <doc:BackgroundRestoration>
