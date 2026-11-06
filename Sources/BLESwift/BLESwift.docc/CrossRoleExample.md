# Both roles in one process, over fakes

Run a real ``PeripheralHost`` and a real ``Central`` through a full GATT conversation in one process. No CoreBluetooth or hardware is necessary.

## Overview

``Central`` and ``PeripheralHost`` are normally on two sides of a radio link. For tests, demos, and CI, `BLESwiftTestSupport` lets you run both roles in one process and connect them in memory.

Each role has a scriptable backend that does not use CoreBluetooth. `FakeCentral` and `FakePeripheral` serve the central role. `FakePeripheralManager` serves the peripheral role. These two families do not connect to each other. `FakeGATTBridge` connects a `FakePeripheral` to a `FakePeripheralManager`:

- Each ``GATTService`` that the host publishes with ``PeripheralHost/add(_:)`` appears in the central's discovery state.
- A central `read` or `write` reaches ``PeripheralHost/readRequests()`` or ``PeripheralHost/writeRequests()``. The host's answer returns as the central's result.
- Enabled notifications appear on ``PeripheralHost/subscriptionEvents()``.
- A ``PeripheralHost/updateValue(_:for:onSubscribed:)`` arrives on the `Peripheral/notifications(for:)` stream of the central.

The two roles run on two different serial queues. The bridge forwards between them with the asynchronous `simulate...` calls of each fake.

> Note: `FakeGATTBridge` and the fakes are in `BLESwiftTestSupport`, a module for tests and examples. Do not use them as a production transport.

## Building the two roles

Give each role its own backend and its own serial queue. Then connect them with a bridge:

```swift
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

// Central role, on its own queue.
let centralQueue = DispatchQueue(label: "Example.Central")
let fakeCentral = FakeCentral(queue: centralQueue)
let fakePeripheral = FakePeripheral(name: "Rig", queue: centralQueue)
let central = Central(backend: fakeCentral, queue: centralQueue)

// Peripheral role, on its own distinct queue.
let hostQueue = DispatchQueue(label: "Example.Host")
let fakeManager = FakePeripheralManager(queue: hostQueue)
let host = PeripheralHost(backend: fakeManager, queue: hostQueue)

// Interconnect the two fake families.
let bridge = FakeGATTBridge(central: fakeCentral, peripheral: fakePeripheral, manager: fakeManager)
```

Keep a strong reference to `bridge` while you use the fakes. The hooks that it installs capture it weakly. If you release it, the fakes return to standalone scripted behavior.

## Hosting a database and answering requests

Power on the host's radio, publish a service, and answer reads and writes. Subscribe to the request streams **before** you advertise. They do not replay.

```swift
let heartRate = ServiceIdentifier(uuid: "180D")
let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

fakeManager.simulateStateChange(.poweredOn)

try await host.add(GATTService(identifier: heartRate, characteristics: [
    GATTCharacteristic(
        identifier: measurement,
        properties: [.read, .write, .notify],
        permissions: [.readable, .writeable]
    )
]))

// A tiny in-memory "device": a read returns the current value, a write replaces it.
let value = Mutex<Data>(Data([0x00]))

Task {
    for await request in await host.readRequests() {
        await host.respond(to: request, with: .success(value.withLock { $0 }))
    }
}
Task {
    for await request in await host.writeRequests() {
        for entry in request.entries { value.withLock { $0 = entry.value } }
        await host.respond(to: request, with: .success(()))
    }
}

try await host.startAdvertising(
    PeripheralAdvertisement(localName: "Rig", serviceUUIDs: [heartRate])
)
```

## Connecting and talking from the central

Script the connection on the central fake. Then connect, read, and write. The values go to the host and come back:

```swift
fakeCentral.simulateStateChange(.poweredOn)
fakeCentral.onQueue {
    fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
    fakeCentral.connectBehavior = .succeed
}

let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)

// Reads the host's current value (0x00), then writes a new one and reads it back.
let initial: Data = try await peripheral.read(from: measurement)   // 0x00
try await peripheral.write(Data([0x2A]), to: measurement)          // reaches host.writeRequests()
let updated: Data = try await peripheral.read(from: measurement)   // 0x2A
```

## Receiving a notification

Subscribe on the central and wait until the host sees the subscriber. Then push a value from the host. It arrives on the notification stream of the central:

```swift
let notifications: AsyncThrowingStream<Data, Error> = peripheral.notifications(for: measurement)

// The subscription surfaces on the host side; `bridge.subscriber` is the central's identity.
while await !host.subscribers(for: measurement).contains(where: { $0.id == bridge.subscriber.id }) {
    await Task.yield()
}

try await host.updateValue(Data([0x99]), for: measurement)

for try await value in notifications {
    print(value)   // 0x99
    break
}
```

`CrossRoleEndToEndTests` in the test suite runs this flow.

## Topics

### Test support

- <doc:PeripheralRole>
- <doc:GettingStarted>
