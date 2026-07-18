# Both roles in one process, over fakes

Drive a real ``PeripheralHost`` and a real ``Central`` through a full GATT conversation in a
single process — no CoreBluetooth, no hardware — by interconnecting their test fakes.

## Overview

``Central`` (the central role) and ``PeripheralHost`` (the peripheral role) are normally two
sides of a radio link between two devices. For tests, demos, and CI, `BLESwiftTestSupport` lets
you run **both roles in one process** and connect them to each other entirely in memory.

Each role has its own scriptable, queue-confined, CoreBluetooth-free backend — `FakeCentral`/
`FakePeripheral` for the central role, `FakePeripheralManager` for the peripheral role. On their
own the two families don't interconnect: each is scripted in isolation. `FakeGATTBridge` wires a
central-side `FakePeripheral` to a peripheral-side `FakePeripheralManager` so that:

- every ``GATTService`` the host publishes with ``PeripheralHost/add(_:)`` is mirrored into the
  central's discovery state — the central discovers exactly what the host hosts;
- a central `read`/`write` reaches the host's ``PeripheralHost/readRequests()``/
  ``PeripheralHost/writeRequests()`` streams, and the host's answer flows back as the central's
  result;
- enabling notifications surfaces on ``PeripheralHost/subscriptionEvents()``; and
- a ``PeripheralHost/updateValue(_:for:onSubscribed:)`` arrives on the central's
  `Peripheral/notifications(for:)` stream.

Everything stays queue-confined and deterministic: the two roles run on two distinct serial
queues, and the bridge forwards between them using each fake's asynchronous `simulate…` seams.

- Note: `FakeGATTBridge` and the fakes live in `BLESwiftTestSupport`, a test-only module. They
  are for tests and examples — not a production transport.

## Building the two roles

Give each role its own backend on its own serial queue, then bridge them:

```swift
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

// Central role, on its own queue.
let centralQueue = DispatchSerialQueue(label: "Example.Central")
let fakeCentral = FakeCentral(queue: centralQueue)
let fakePeripheral = FakePeripheral(name: "Rig", queue: centralQueue)
let central = Central(backend: fakeCentral, queue: centralQueue)

// Peripheral role, on its own distinct queue.
let hostQueue = DispatchSerialQueue(label: "Example.Host")
let fakeManager = FakePeripheralManager(queue: hostQueue)
let host = PeripheralHost(backend: fakeManager, queue: hostQueue)

// Interconnect the two fake families.
let bridge = FakeGATTBridge(central: fakeCentral, peripheral: fakePeripheral, manager: fakeManager)
```

Keep a strong reference to `bridge` for the duration of the interaction: it installs hooks on the
fakes that capture it weakly, so once it is released the two fakes revert to standalone scripted
behavior.

## Hosting a database and answering requests

Bring the host's radio up, publish a service, and start answering reads and writes. Subscribe to
the request streams **before** advertising — they do not replay.

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

Script the connection on the central fake, connect, then read and write — the values round-trip
all the way to the host and back:

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

Subscribe on the central, wait until the host sees the subscriber, then push a value from the
host — it arrives on the central's notification stream:

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

`CrossRoleEndToEndTests` in the test suite runs exactly this flow end to end.

## Topics

### Test support

- <doc:PeripheralRole>
- <doc:GettingStarted>
