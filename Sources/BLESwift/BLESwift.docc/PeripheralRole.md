# Hosting a GATT server (peripheral role)

Advertise services, host a GATT database, and answer reads, writes, and subscriptions from
remote centrals with ``PeripheralHost``.

## Overview

Where ``Central`` is the *central* role — scanning for and connecting to remote peripherals —
``PeripheralHost`` is the other half of CoreBluetooth: the *peripheral* role. It wraps a single
`CBPeripheralManager` in an actor whose isolation is tied directly to the `DispatchSerialQueue`
its manager delivers delegate callbacks on, exactly like ``Central``. You build a GATT database
from value types, advertise it, and respond to remote centrals through `async`/`AsyncSequence`
APIs — no delegate, no callbacks.

- Important: The peripheral role is not usable at runtime on every platform. tvOS and watchOS
  restrict or disallow BLE advertising; the radio may report ``CentralState/unsupported`` there.
  The API compiles everywhere (its CoreBluetooth types are available on all five platforms) —
  whether advertising actually starts is a runtime property surfaced through ``PeripheralHost/state``
  and ``PeripheralHost/startAdvertising(_:)``.

## Building a GATT database

A service is a value type, ``GATTService``, holding value-type ``GATTCharacteristic``s.
Properties and permissions mirror CoreBluetooth's option sets:

```swift
let heartRate = ServiceIdentifier(uuid: "180D")
let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

let service = GATTService(identifier: heartRate, characteristics: [
    GATTCharacteristic(
        identifier: measurement,
        properties: [.read, .notify],
        permissions: [.readable]
    )
])
```

A characteristic with a non-`nil` ``GATTCharacteristic/value`` is *static* — CoreBluetooth
answers reads from that constant itself. A `nil` value (the default) makes it *dynamic*: reads
and writes surface as requests for your code to answer, and you push notifications yourself.

## Advertising

Create a host, add the service (awaiting CoreBluetooth's confirmation), then start advertising:

```swift
let host = PeripheralHost()

// Wait for the radio to power on.
for await state in await host.stateEvents() where state == .poweredOn { break }

try await host.add(service)
try await host.startAdvertising(
    PeripheralAdvertisement(localName: "My Rig", serviceUUIDs: [heartRate])
)
```

``PeripheralHost/startAdvertising(_:)`` returns once `peripheralManagerDidStartAdvertising`
fires. Only a local name and service UUIDs are advertised — the only two fields CoreBluetooth
honors on the advertising side (see ``PeripheralAdvertisement``).

## Answering reads and writes

Consume the request streams and answer each request exactly once. Subscribe **before** you
start advertising — the streams do not replay.

```swift
Task {
    for await request in await host.readRequests() {
        await host.respond(to: request, with: .success(currentValue))
    }
}

Task {
    for await request in await host.writeRequests() {
        for entry in request.entries {
            apply(entry.value, to: entry.characteristic)
        }
        await host.respond(to: request, with: .success(()))
    }
}
```

Reject a request instead with a `.failure(ATTError)` — e.g. `.failure(.writeNotPermitted)`. A
write request arrives as a **batch** (``WriteRequest/entries``); a single
`respond(to:with:)` call acknowledges the whole batch.

## Notifying subscribers with back-pressure

Track subscribers via ``PeripheralHost/subscriptionEvents()`` (or the
``PeripheralHost/subscribers(for:)`` snapshot), then push values with
``PeripheralHost/updateValue(_:for:onSubscribed:)``:

```swift
Task {
    for await event in await host.subscriptionEvents() {
        switch event {
        case .subscribed(let central, let characteristic):
            print("\(central.id) is listening to \(characteristic)")
        case .unsubscribed(let central, let characteristic):
            print("\(central.id) stopped listening to \(characteristic)")
        }
    }
}

// Later, push a new value to every subscriber:
try await host.updateValue(newReading, for: measurement)
```

``PeripheralHost/updateValue(_:for:onSubscribed:)`` applies the same back-pressure discipline
as the central-side `writeWithoutResponse`: when CoreBluetooth's transmit queue is full it
suspends until `peripheralManagerIsReady(toUpdateSubscribers:)` and retries, so the call returns
only once the update has actually been queued.

## Tearing down

``PeripheralHost/stopAndExtractState()`` detaches the delegate and hands the underlying
`CBPeripheralManager` back to you, failing every pending operation with
``BLESwiftError/stopped``. Use ``PeripheralHost/stopAdvertising()`` /
``PeripheralHost/removeAllServices()`` for a softer stop.

## Restoring state after a background relaunch

On iOS, CoreBluetooth can relaunch your app in the background and hand back the GATT database
and advertising state it preserved while your app was suspended or terminated. Opt in by
passing a ``PeripheralRestorationConfiguration`` as ``Configuration/peripheralRestoration`` —
its identifier is registered with CoreBluetooth
(`CBPeripheralManagerOptionRestoreIdentifierKey`) when the manager is created:

```swift
let host = PeripheralHost(configuration: Configuration(
    peripheralRestoration: PeripheralRestorationConfiguration(identifier: "com.example.peripheral")
))
```

- Important: The peripheral restore identifier must be **distinct** from any ``Central``'s
  ``RestorationConfiguration/identifier`` — CoreBluetooth requires a unique restore identifier
  per manager. That is why the two are separate ``Configuration`` settings.

Restoration results arrive on ``PeripheralHost/restorationEvents()`` — a **buffered, replayed**
stream, exactly like ``Central/restorationEvents()``. Every event is buffered from the host's
creation and replayed, in order, to the first consumer, so state restored during launch is
never lost even if your consumer task starts strictly afterwards:

```swift
Task {
    for await event in await host.restorationEvents() {
        switch event {
        case .willRestore(let state):
            print("Restored \(state.services.count) service(s)")
            if let advertisement = state.advertisement {
                print("Advertising resumed as \(advertisement.localName ?? "<no name>")")
            }
        }
    }
}
```

Peripheral-role restoration has a single event: CoreBluetooth itself re-publishes the preserved
services and resumes the preserved advertisement on your behalf, so there is nothing to
re-drive. `PeripheralHost` reflects a resumed advertisement in its ``PeripheralHost/isAdvertising``
snapshot (it does **not** re-issue ``PeripheralHost/startAdvertising(_:)`` — CoreBluetooth
already did), and pushing notifications via ``PeripheralHost/updateValue(_:for:onSubscribed:)``
works against the restored characteristics without re-adding them.

## Testing without hardware

`BLESwiftTestSupport`'s `FakePeripheralManager` is a queue-confined, CoreBluetooth-free stand-in
for `CBPeripheralManager`. Drive a real ``PeripheralHost`` through
``PeripheralHost/init(backend:queue:configuration:)`` and script the events a real manager would
deliver — simulate reads, writes, subscriptions, and transmit-queue back-pressure — all without
a device.

To drive a real ``PeripheralHost`` *and* a real ``Central`` against each other in one process —
the peripheral hosting a database that the central connects to, reads, writes, and receives
notifications from — bridge the two fake families with `FakeGATTBridge`; see
<doc:CrossRoleExample>.

## Topics

### Essentials

- ``PeripheralHost``

### GATT database

- ``GATTService``
- ``GATTCharacteristic``
- ``CharacteristicProperties``
- ``AttributePermissions``

### Advertising

- ``PeripheralAdvertisement``

### Requests and responses

- ``ReadRequest``
- ``WriteRequest``
- ``RequestToken``
- ``ATTError``
- ``Subscriber``
- ``SubscriptionEvent``

### Background restoration

- ``PeripheralRestorationConfiguration``
- ``PeripheralRestorationEvent``
- ``RestoredPeripheralState``
