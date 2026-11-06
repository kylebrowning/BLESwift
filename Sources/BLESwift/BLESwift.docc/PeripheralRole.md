# Hosting a GATT server (peripheral role)

Advertise services, host a GATT database, and answer reads, writes, and subscriptions from remote centrals with ``PeripheralHost``.

## Overview

``Central`` is the *central* role. It scans for remote peripherals and connects to them. ``PeripheralHost`` is the *peripheral* role. It wraps one `CBPeripheralManager` in an actor. Like ``Central``, its isolation is the serial `DispatchQueue` on which the manager delivers callbacks. You build a GATT database from value types, advertise it, and answer remote centrals with `async` calls and `AsyncSequence` streams.

> Important: The peripheral role is available on iOS and macOS only. CoreBluetooth does not support `CBPeripheralManager` on watchOS and tvOS, or a GATT database on visionOS. On those platforms, ``PeripheralHost`` does not exist. The central role (``Central``) is available on all five platforms.

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

A characteristic with a non-`nil` ``GATTCharacteristic/value`` is *static*. CoreBluetooth answers reads from that constant. A `nil` value (the default) makes the characteristic *dynamic*. Reads and writes arrive as requests that your code must answer. You push notifications yourself.

## Advertising

Create a host, add the service, and start to advertise. ``PeripheralHost/add(_:)`` returns after CoreBluetooth confirms the service.

```swift
let host = PeripheralHost()

// Wait for the radio to power on.
for await state in await host.stateEvents() where state == .poweredOn { break }

try await host.add(service)
try await host.startAdvertising(
    PeripheralAdvertisement(localName: "My Rig", serviceUUIDs: [heartRate])
)
```

``PeripheralHost/startAdvertising(_:)`` returns when `peripheralManagerDidStartAdvertising` fires. CoreBluetooth honors only a local name and service UUIDs in an advertisement. See ``PeripheralAdvertisement``.

## Answering reads and writes

Consume the request streams and answer each request exactly once. Subscribe **before** you start to advertise. The streams do not replay.

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

To reject a request, respond with a `.failure(ATTError)`, for example `.failure(.writeNotPermitted)`. A write request is a **batch** (``WriteRequest/entries``). One `respond(to:with:)` call acknowledges the whole batch.

## Notifying subscribers with back-pressure

To track subscribers, use ``PeripheralHost/subscriptionEvents()`` or the ``PeripheralHost/subscribers(for:)`` snapshot. To push values, use ``PeripheralHost/updateValue(_:for:onSubscribed:)``:

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

If the CoreBluetooth transmit queue is full, ``PeripheralHost/updateValue(_:for:onSubscribed:)`` suspends. It waits for `peripheralManagerIsReady(toUpdateSubscribers:)` and tries again. The call returns when CoreBluetooth has queued the update.

## Tearing down

``PeripheralHost/stopAndExtractState()`` detaches the delegate and returns the `CBPeripheralManager` to you. It fails every pending operation with ``BLESwiftError/stopped``. For a softer stop, use ``PeripheralHost/stopAdvertising()`` or ``PeripheralHost/removeAllServices()``.

## Restoring state after a background relaunch

On iOS, CoreBluetooth can relaunch your app in the background. It then returns the GATT database and the advertising state that it kept. To enable this, pass a ``PeripheralRestorationConfiguration`` as ``Configuration/peripheralRestoration``. BLESwift registers its identifier with CoreBluetooth (`CBPeripheralManagerOptionRestoreIdentifierKey`) when it creates the manager:

```swift
let host = PeripheralHost(configuration: Configuration(
    peripheralRestoration: PeripheralRestorationConfiguration(identifier: "com.example.peripheral")
))
```

> Important: The peripheral restore identifier must be **different** from the ``RestorationConfiguration/identifier`` of any ``Central``. CoreBluetooth requires a unique restore identifier for each manager. For this reason, ``Configuration`` has two separate settings.

Restoration results arrive on ``PeripheralHost/restorationEvents()``. Like ``Central/restorationEvents()``, this stream is **buffered and replayed**. BLESwift buffers every event from the creation of the host and replays them in order to the first consumer. A consumer that starts late does not lose state that was restored during launch.

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

Peripheral-role restoration has one event. CoreBluetooth publishes the preserved services again and resumes the preserved advertisement. You do not need to do either. ``PeripheralHost/isAdvertising`` shows a resumed advertisement. Do not call ``PeripheralHost/startAdvertising(_:)`` again. ``PeripheralHost/updateValue(_:for:onSubscribed:)`` works on the restored characteristics without ``PeripheralHost/add(_:)``.

## Testing without hardware

`FakePeripheralManager` in `BLESwiftTestSupport` replaces `CBPeripheralManager` in tests. It does not use CoreBluetooth. Create a real ``PeripheralHost`` with ``PeripheralHost/init(backend:queue:configuration:)``. Then script the events that a real manager delivers: reads, writes, subscriptions, and transmit-queue back-pressure.

To connect a real ``PeripheralHost`` to a real ``Central`` in one process, use `FakeGATTBridge`. See <doc:CrossRoleExample>.

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
