# Mocking Bluetooth in-process

Run a fully mocked radio inside your own process, on device or in the simulator.

## Overview

CoreBluetooth cannot be faked from outside, and the simulator has none. A ``VirtualRadio`` replaces it inside your process. You register devices on the radio. A real `Central` talks to them through the same code that it uses with hardware.

### Register a device

A ``VirtualDevice`` has two parts:

- A ``VirtualDeviceDescriptor`` with the identity, the advertisement, and the GATT database.
- A ``VirtualDeviceHandler`` that answers the dynamic traffic.

A characteristic with a `value` that is not `nil` is static. The radio answers its reads. Every other read and every write goes to the handler.

Like the ATT layer of hardware, the radio refuses some requests before the handler sees them:

- A read of a characteristic that is not readable or notifiable.
- A write to a characteristic that is not writable.

The radio silently drops a write without response that is too long for one packet.

```swift
import BLESwift
import BLESwiftVirtualRadio
import Foundation

let heartRate = ServiceIdentifier(uuid: "180D")
let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)
let control = CharacteristicIdentifier(uuid: "2A39", service: heartRate)

struct HeartRateHandler: VirtualDeviceHandler {
    func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
        .success(Data([0x00, 72]))
    }
    func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
        .success(())
    }
    func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
}

let radio = VirtualRadio()
let handle = await radio.register(VirtualDevice(
    descriptor: VirtualDeviceDescriptor(
        name: "Virtual HRM",
        advertisement: AdvertisementData(localName: "Virtual HRM", serviceUUIDs: [heartRate], isConnectable: true),
        services: [GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable]),
            GATTCharacteristic(identifier: control, properties: [.write], permissions: [.writeable])
        ])]
    ),
    handler: HeartRateHandler()
))

// Later, from anywhere: push a notification to every subscriber.
await handle.notify(Data([0x00, 75]), for: measurement, to: nil)
```

The returned ``VirtualDeviceHandle`` can also start and stop advertising, replace the advertisement or the GATT database, and remove the device.

### Route your app to the radio

You can connect a `Central` to the radio in two ways.

**Install the radio.** ``VirtualRadio/install(_:)`` registers the radio with the process-wide `BackendRegistry`. Then every `Central()` and `PeripheralHost()` that the app builds uses the radio. Call it once at launch, before the app builds the first `Central` or `PeripheralHost`. A `Central` that already exists does not change.

```swift
func configureBluetooth() async {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-useVirtualRadio") {
        let radio = VirtualRadio()
        // ... register devices on `radio` ...
        VirtualRadio.install(radio)
    }
    #endif
}

// At launch, before the first Central() or PeripheralHost():
await configureBluetooth()
```

The registry has one slot. ``VirtualRadio/install(_:)`` and `SimulatorLink.install` replace each other. ``VirtualRadio/installed`` shows only the last radio that this type installed. ``VirtualRadio/uninstall()`` restores CoreBluetooth.

**Pass the backend.** `Central(backend:queue:)` ignores the registry, so it changes no global state. Use this method in unit tests.

```swift
let queue = DispatchQueue(label: "MyTests.central")
let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
```

On iOS and macOS, `PeripheralHost` works the same way with ``VirtualPeripheralManagerBackend``. It hosts a device on the radio. Any ``VirtualCentralBackend`` on that radio can discover the device.

### Driving the backend directly

A `Central` only connects a `.disconnected` remote. It reserves its slot after the previous connection's termination event arrives. If you drive ``VirtualCentralBackend`` directly, `connect(_:options:requiresANCS:)` also accepts the other states. The result depends on the remote's `connectionState`:

- `.disconnected`: the attempt goes to the radio. `didConnect` or `didFailToConnect` reports its outcome.
- `.connected`: nothing goes to the radio and nothing changes. The backend delivers `didConnect`, hopped and never inline.
- `.connecting`: nothing happens. The pending attempt's `didConnect` or `didFailToConnect` answers both requests.
- `.disconnecting`: nothing goes to the radio and the state does not change. The backend delivers `didFailToConnect` with ``VirtualCentralBackend/connectWhileDisconnectingError``, hopped.

The failure for `.disconnecting` arrives after the `didDisconnect` of the cancel in progress. It goes through the serial chain, behind the cancel's step. The caller sees the remote settle `.disconnected` first and the attempt refused second. Then the caller can ask again. `BLESwiftProvider`'s `CentralSession` discards the peripheral's per-connection state on the `didDisconnect`, so the `didFailToConnect` finds nothing left to discard.

A connect delay (``VirtualLatency/connect``) sleeps before the backend enqueues the attempt. The sleep runs on a task that the remote holds as its pending connect, not in the serial chain. Thus a cancel that is queued behind a delayed attempt does not wait out the delay. When the sleep ends, the backend enqueues the connect body only if all of these are true:

- The attempt is still the current one.
- The remote is still `.connecting`.
- Nothing cancelled the attempt.

The connect body is the same body that an undelayed attempt takes, with all its guards. The radio sees nothing of the attempt until then. The attempt consumes an armed connection failure when it lands, after the delay.

### Cancelling a connection

``VirtualCentralBackend/cancelPeripheralConnection(_:)`` delivers `didDisconnect` only when this call removed the connection on the radio. A forced disconnect or a removal can reach the radio after the cancel, and it owns the `didDisconnect`. An answer from the cancel too would send a second `didDisconnect(nil)`. It could also overwrite a `.connecting` state of a remote that reconnected in between, so `Central` would fail the reconnect while the radio's `didConnect` left the remote connected. The forced event settles the remote when it arrives on the queue. This can be after the cancel's answer, because the radio holds it behind the device's in-flight subscription reports.

A cancel that catches an attempt that still sleeps out its connect delay never reaches the radio. The backend cancels the sleep and invalidates the attempt. It sets the remote to `.disconnecting` at once. On the next hop, the remote becomes `.disconnected` and gets `didDisconnect(nil)`. A `connect` in between fails with ``VirtualCentralBackend/connectWhileDisconnectingError``, as it does behind an undelayed cancel.

### Simulating MTU

Real peripherals negotiate different ATT MTUs. Code that sizes its chunks with `maximumWriteValueLength(for:)` behaves differently with each MTU. Examples are a firmware update and a file transfer.

To set the one-packet length of a device, use ``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength``. The range is 20 to 512. The default is ``VirtualRadio/maximumWriteWithoutResponseLength`` (182). The radio then does what hardware does:

- A connected `Central` reports this length for `.withoutResponse`.
- The radio drops a write without response that is longer.
- The radio truncates a notification to this length.

A `.withResponse` write is not affected. ATT long writes can reach ``VirtualRadio/maximumValueLength`` at any MTU.

```swift
let descriptor = VirtualDeviceDescriptor(
    name: "Small-MTU HRM",
    advertisement: AdvertisementData(localName: "Small-MTU HRM", serviceUUIDs: [heartRate], isConnectable: true),
    services: services,
    maximumWriteWithoutResponseLength: 20
)
```

### Injecting faults

Use the ``VirtualDeviceHandle`` of a device to cause the failures that a real peripheral produces and a handler cannot. A fault lasts for one registration. If you call `remove()` and then register the identifier again, the new registration has no faults. The radio ignores a handle from an earlier registration.

If you register an identifier that is still registered, the radio first retires the old registration. It disconnects the connected centrals with code 2. The old handler receives their unsubscribes. See ``VirtualRadio/register(_:advertising:)``.

- ``VirtualDeviceHandle/failConnections(with:times:)`` fails the next `times` connection attempts. If `times` is `nil`, every attempt fails until you call ``VirtualDeviceHandle/clearConnectionFailures()``. The `Central` receives the `NSError` unchanged. Pass the error that CoreBluetooth would give. The count is per device and covers all centrals on the radio. If two `Central` instances connect to the same device, the first one uses the count.
- ``VirtualDeviceHandle/disconnect(_:error:)`` drops all connected centrals, or only the centrals that you name. It acts as a disconnect that the peripheral starts. The `Central` receives the error. The default error is ``VirtualRadio/peripheralDisconnectedError`` (`CBError.peripheralDisconnected`). The handler receives the subscriptions of the central as unsubscribes. The central can reconnect. See <doc:InProcessMocking#Forced-disconnects>.
- ``VirtualDeviceHandle/setATTError(_:for:operations:)`` answers reads, writes with response, and subscribes on one characteristic with an `ATTError`. The error comes before the database and the handler, so a static value also fails. A write without response has no ATT response, so it reaches the handler as usual.

> Note: On iOS, CoreBluetooth answers `.insufficientEncryption` and `.insufficientAuthentication` by pairing and retrying. An app sees these errors only if pairing fails. The radio returns them on the first attempt. Thus a test that asserts on them tests the path for a failed pairing.

```swift
// The next connect fails the way a peripheral that forgot its bond does.
await handle.failConnections(with: NSError(domain: "CBErrorDomain", code: 14))

// Reads of the measurement need encryption the central does not have.
await handle.setATTError(.insufficientEncryption, for: measurement, operations: .read)

// Then the link drops.
await handle.disconnect()
```

### Report order and reentrancy

The radio keeps one report chain for each device identifier. A report tells the device's handler about a subscription change. These rules apply:

- The handler receives the reports one at a time, in the order that the radio applied the changes. A subscribe that is still in flight when a drop lands is reported before the drop's unsubscribe.
- After a forced disconnect, a removal, or a re-registration, the `didDisconnect` events follow the unsubscribes. They also follow every report already in flight for the device, such as another central's subscribe or an unsubscribe from `setServices`.
- If a device has nothing in flight and no subscription to drop, the `didDisconnect` goes out in the same actor turn as the drop.
- A subscribe or unsubscribe from a `Central` returns after the radio delivers the report. The radio decides the answer from its table, before the delivery.

The `didDisconnect` goes last because the actor is reentrant across the reports. A `Central` with a reconnect policy could hear it first, subscribe again, and have the old unsubscribe reach the handler after the new subscribe. The handler would then take a live subscriber for one that had left.

If you call ``VirtualDeviceHandle/disconnect(_:error:)``, or ``VirtualRadio/register(_:advertising:)`` for an identifier that is registered, from inside a subscription report, the call returns before the radio delivers the reports. The call can come from the handler's `subscriptionChanged`, or from a task that it started there. The call does not wait, because it would wait for the report that made the call. The radio still delivers the reports, in order, after that report returns.

When you register an identifier that is registered, the radio installs the new device state before its first `await`, and the identifier stays known throughout. A backend that resolves the identifier while the old handler hears its unsubscribes thus finds the device. The new registration shares the report chain, so the new handler hears nothing until the old handler's reports have run. The radio does not carry connections or subscriptions over, because the new handler never received `subscriptionChanged(isSubscribed: true)` for them.

### Forced disconnects

``VirtualDeviceHandle/disconnect(_:error:)`` drops the connection on the radio first. It delivers `didDisconnect` only after every report in flight for the device. While the handler is still inside one of those reports, the central has no connection on the radio but has not heard `didDisconnect`. A re-registration has the same window, and a scanning central can also see the new registration's sighting before that `didDisconnect`. In the window:

- A read or write that the central sends fails with `ATTError.invalidHandle`.
- A `setNotifyValue(true)` answers that the characteristic is not notifying.
- A `cancelPeripheralConnection` removes nothing. A `Central.disconnect()` still returns normally. But the `.disconnected` connection event that it produces carries the forced error (code 7 by default) and not `nil`. A connect queued behind that cancel fails with ``VirtualCentralBackend/connectWhileDisconnectingError`` (code 11).
- A connect on the remote with no cancel in between gets the answer for a connected remote: a repeated `didConnect`. Through `Central`, which still tracks the connection, it is `BLESwiftError.duplicateConnect`. The forced `didDisconnect` then settles the remote.

A device with no report in flight has no window. See <doc:InProcessMocking#Report-order-and-reentrancy>.

### Testing timeouts deterministically

The radio answers at once unless a device has a delay. To add a delay, give the device a ``VirtualLatency``. Use ``VirtualDeviceDescriptor/latency`` when you register the device, or ``VirtualDeviceHandle/setLatency(_:)`` later. The connects, discoveries, reads, writes with response, and subscribes of the device then take that time to answer. A write without response has no answer to delay. The handler decides when a notification goes out.

Delays sleep on ``VirtualRadio/clock``. The timers of `Central` sleep on `Configuration.clock`. Both clocks use wall time by default. To control time, give the same `ManualClock` from `BLESwiftTestSupport` to both. Then you cross a timeout of tens of seconds, or miss it by a millisecond, when you advance the clock. The next sample uses `heartRate`, `measurement`, and `HeartRateHandler` from the first sample on this page.

```swift
import BLESwift
import BLESwiftTestSupport
import BLESwiftVirtualRadio
import Foundation
import Testing

let clock = ManualClock()
let radio = VirtualRadio(clock: clock)
let slowDevice = VirtualDeviceDescriptor(
    name: "Slow HRM",
    advertisement: AdvertisementData(localName: "Slow HRM", serviceUUIDs: [heartRate], isConnectable: true),
    services: [GATTService(identifier: heartRate, characteristics: [
        GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable])
    ])],
    latency: VirtualLatency(connect: .seconds(60))
)
await radio.register(VirtualDevice(descriptor: slowDevice, handler: HeartRateHandler()))

let queue = DispatchQueue(label: "MyTests.central")
let central = Central(
    backend: VirtualCentralBackend(radio: radio, queue: queue),
    queue: queue,
    configuration: Configuration(clock: clock)
)

let id = PeripheralIdentifier(uuid: slowDevice.identifier, name: nil)
let attempt = Task { try await central.connect(id, timeout: .seconds(30)) }
await clock.waitForSleepers(2)       // the device's delay and the Central's timeout are both parked
clock.advance(by: .seconds(30))      // the timeout fires; the delayed attempt is withdrawn
await #expect(throws: BLESwiftError.connectionTimedOut) { try await attempt.value }
```

`waitForSleepers(_:)` makes the test deterministic. `advance(by:)` resumes only the sleepers that are already suspended. Wait until the code under test reaches its sleep. Then move the clock and await the result.

These rules apply to a delayed operation:

- If a `connect(timeout:)` fires or a `disconnect` happens during a delayed connect, the radio withdraws the attempt before it sees it. Nothing connects later.
- A connection failure from ``VirtualDeviceHandle/failConnections(with:times:)`` is consumed when the attempt arrives, after the delay.
- ``VirtualDeviceHandle/disconnect(_:error:)`` during the delay does nothing, because no connection exists yet.
- A delayed read, write, or subscribe uses the state of the device when the delay ends. If the central disconnected during the delay, the request fails.

### Limits

The radio is a test harness. It does not simulate the radio link. These limits apply:

- There is no state restoration. The radio never delivers `willRestoreState`.
- RSSI is a constant. See ``VirtualRadio/rssi``.
- There are no system-connected peripherals. Nothing is connected before your code connects it.
- Writes without response and notifications have the limit ``VirtualRadio/maximumWriteWithoutResponseLength``. Responses have the limit ``VirtualRadio/maximumValueLength``. Hardware has the same ATT limits.
