# Getting Started

Configure, create, and connect a ``Central`` — from radio power-on to your first GATT read.

## Overview

Every BLESwift app follows the same shape: configure once, create a single ``Central``, wait for
the Bluetooth radio to power on, then connect and talk to a peripheral. This article walks
through that shape end to end.

### Configuring `Central`

``Configuration`` captures every start-time option BLESwift needs, since the underlying
`CBCentralManager` is created synchronously inside ``Central/init(configuration:)`` (not behind
a separate async `start()` step):

```swift
import BLESwift

let configuration = Configuration(
    showPowerAlert: true,
    warningOptions: .default
)
```

`showPowerAlert` mirrors `CBCentralManagerOptionShowPowerAlertKey` — whether iOS shows a system
alert if Bluetooth is off while your app is backgrounded. `warningOptions` (see
``WarningOptions``) is the default applied to every connection that doesn't override it.
`Configuration` also carries a `swift-log` `Logger` (defaulting to `Logger(label: "BLESwift")`) —
install a custom `LogHandler` on it to observe BLESwift's internal logging.

### Creating `Central`

```swift
let central = Central(configuration: configuration)
```

``Central`` is an actor: every stored piece of connection/scan state lives inside its isolation
domain, and every method that touches CoreBluetooth is `async`. Two properties are exceptions,
readable synchronously from any isolation domain because they're backed by a `Mutex` snapshot:
``Central/state`` (the current ``CentralState``) and ``Central/isScanning``.

### Waiting for the radio

Bluetooth starts in ``CentralState/unknown`` until CoreBluetooth reports its first real state.
Subscribe to ``Central/stateEvents()`` and wait for ``CentralState/poweredOn`` before scanning
or connecting:

```swift
for await state in await central.stateEvents() {
    if state == .poweredOn { break }
}
```

``Central/stateEvents()`` replays the most recently observed state to a subscriber that starts
listening after that state was reached, so a late subscriber never misses the current state —
you don't need to separately check ``Central/state`` first.

### Connecting

Once you have a ``PeripheralIdentifier`` — typically from a scan (see <doc:Scanning>), or one
you already know about — connect with ``Central/connect(_:timeout:reconnect:warningOptions:)``:

```swift
let peripheral = try await central.connect(identifier, timeout: .seconds(10))
```

This throws ``BLESwiftError/connectionTimedOut`` if `timeout` elapses,
``BLESwiftError/multipleConnectNotSupported`` if a connection or connection attempt is already in
progress (BLESwift is single-peripheral), or whatever error CoreBluetooth reports for
the attempt. See <doc:ConnectionsAndReconnection> for reconnect policies and connection-lifecycle
events.

### Reading a characteristic

``Peripheral`` is a lightweight, `Sendable` handle: every GATT operation on it is an `async
throws` method that routes through the owning ``Central``, lazily discovering the service and
characteristic it needs first.

```swift
let batteryService = ServiceIdentifier(uuid: "180F")
let batteryLevelCharacteristic = CharacteristicIdentifier(uuid: "2A19", service: batteryService)

let level: UInt8 = try await peripheral.read(from: batteryLevelCharacteristic)
print("Battery: \(level)%")
```

`UInt8` conforms to ``Receivable`` out of the box (as do every fixed-width integer type,
`String`, and `Data` itself) — decode your own binary formats by conforming your own type to
``Receivable``/``Transmittable``. See <doc:ReadingWritingNotifications> for writes and
notification streams.

### Testing

You don't need real hardware to unit-test code built on `Central`. The **BLESwiftTestSupport**
module ships `FakeCentral`/`FakePeripheral` — scriptable stand-ins for
`CBCentralManager`/`CBPeripheral` — plus `Central`'s public
`init(backend:queue:configuration:startupBackgroundTask:connectedPeripheral:)`, which wires a
real `Central` to them instead of CoreBluetooth:

```swift
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

let queue = DispatchSerialQueue(label: "MyAppTests.rig")
let fakeCentral = FakeCentral(queue: queue)
let central = Central(backend: fakeCentral, queue: queue)
```

From there, `central` behaves exactly like a production `Central` — `stateEvents()`,
`connect(_:)`, and every `Peripheral` GATT method work unchanged, because `Central` itself has
no idea it isn't talking to real hardware. See the **BLESwiftTestSupport** module's "Testing
Your BLE Code" article for the full rig pattern, the queue-confined contract these fakes
enforce, and the scripting reference (`connectBehavior`, `scriptedReadValues`,
`availableServices`, and more).

## See Also

- <doc:Scanning>
- <doc:ConnectionsAndReconnection>
- <doc:ReadingWritingNotifications>
- <doc:BackgroundRestoration>
