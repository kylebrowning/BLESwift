# Getting Started

Configure and create a ``Central``, wait for the radio, connect to a peripheral, and read a characteristic.

## Overview

Every BLESwift app follows these steps. Configure once. Create one ``Central``. Wait for the Bluetooth radio to power on. Then connect to a peripheral and use it.

### Configuring `Central`

``Configuration`` has every start-time option. `Central` creates its `CBCentralManager` synchronously in ``Central/init(configuration:)``. There is no separate async `start()` step.

```swift
import BLESwift

let configuration = Configuration(
    showPowerAlert: true,
    warningOptions: .default
)
```

- `showPowerAlert` sets `CBCentralManagerOptionShowPowerAlertKey`. It controls whether iOS shows a system alert when Bluetooth is off and your app is in the background.
- `warningOptions` (see ``WarningOptions``) is the default for each connection that does not set its own.
- `logger` is a `swift-log` `Logger`. Its default label is `"BLESwift"`. Set a custom `LogHandler` on it to read the internal log.

### Creating `Central`

```swift
let central = Central(configuration: configuration)
```

``Central`` is an actor. Its methods that use CoreBluetooth are `async`. Two properties are readable from any isolation domain without `await`: ``Central/state`` (a ``CentralState``) and ``Central/isScanning``.

### Waiting for the radio

The state is ``CentralState/unknown`` until CoreBluetooth reports a real state. Before you scan or connect, wait for ``CentralState/poweredOn`` on ``Central/stateEvents()``:

```swift
for await state in await central.stateEvents() {
    if state == .poweredOn { break }
}
```

``Central/stateEvents()`` replays the latest state to a new subscriber. You do not need to read ``Central/state`` first.

### Connecting

Get a ``PeripheralIdentifier`` from a scan (see <doc:Scanning>) or from a saved value. Then call ``Central/connect(_:timeout:reconnect:warningOptions:compatibility:)``:

```swift
let peripheral = try await central.connect(identifier, timeout: .seconds(10))
```

The call can throw these errors:

- ``BLESwiftError/connectionTimedOut`` if `timeout` elapses.
- ``BLESwiftError/duplicateConnect(_:)`` if `identifier` already has a connection or an attempt.
- The error that CoreBluetooth reports for the attempt.

`Central` supports any number of concurrent connections. For reconnect policies and connection events, see <doc:ConnectionsAndReconnection>.

### Reading a characteristic

``Peripheral`` is a `Sendable` handle. Each GATT operation is an `async throws` method. The method goes through the owning ``Central`` and discovers the service and characteristic if necessary.

```swift
let batteryService = ServiceIdentifier(uuid: "180F")
let batteryLevelCharacteristic = CharacteristicIdentifier(uuid: "2A19", service: batteryService)

let level: UInt8 = try await peripheral.read(from: batteryLevelCharacteristic)
print("Battery: \(level)%")
```

``Receivable`` is implemented for `UInt8`, the other fixed-width integer types, `String`, and `Data`. For your own binary formats, conform your type to ``Receivable`` or ``Transmittable``. For writes and notification streams, see <doc:ReadingWritingNotifications>.

### Testing

You can unit-test code that uses `Central` without hardware. The **BLESwiftTestSupport** module has `FakeCentral` and `FakePeripheral`. These are scriptable replacements for `CBCentralManager` and `CBPeripheral`. `Central`'s public `init(backend:queue:configuration:startupBackgroundTask:connectedPeripherals:)` connects a real `Central` to them:

```swift
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

let queue = DispatchQueue(label: "MyAppTests.rig")
let fakeCentral = FakeCentral(queue: queue)
let central = Central(backend: fakeCentral, queue: queue)
```

This `central` behaves like a production `Central`. For the full rig pattern, the queue rules, and the scripting reference, see the "Testing Your BLE Code" article of the **BLESwiftTestSupport** module.

## See Also

- <doc:Scanning>
- <doc:ConnectionsAndReconnection>
- <doc:ReadingWritingNotifications>
- <doc:BackgroundRestoration>
