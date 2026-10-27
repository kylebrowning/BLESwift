# Mocking Bluetooth in-process

Run a fully mocked radio inside your own process, on device or in the simulator.

## Overview

CoreBluetooth cannot be faked from the outside, and the simulator has none at all. A
``VirtualRadio`` stands in for it entirely in-process: you register devices on it, and a
real `Central` talks to them through the same code paths it uses against hardware.

### Register a device

A ``VirtualDevice`` pairs a ``VirtualDeviceDescriptor`` (identity, advertisement, GATT
database) with a ``VirtualDeviceHandler`` that answers the dynamic traffic. A characteristic
with a non-`nil` `value` is *static*: the radio answers its reads itself. Every other read,
and every write, reaches the handler — once the radio has let it through. Like hardware's
ATT layer, the radio refuses a read of a characteristic that isn't readable or notifiable,
and a write to one that isn't writable, before the handler sees anything, and it silently
drops a write without response that is too long for one packet.

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

The returned ``VirtualDeviceHandle`` also starts and stops advertising, replaces the
advertisement or the GATT database, and removes the device.

### Route your app to the radio

There are two ways to wire a `Central` to the radio.

**Install it.** ``VirtualRadio/install(_:)`` registers the radio with the process-wide
`BackendRegistry`, so every `Central()` and `PeripheralHost()` built afterwards uses it. Call
it once at launch, before the first of either is constructed — the registry is read when a
`Central` is built, so installing later has no effect on one that already exists.

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

The registry has one slot, so ``VirtualRadio/install(_:)`` and `SimulatorLink.install` replace
each other, and ``VirtualRadio/installed`` reports only what this type last did.
``VirtualRadio/uninstall()`` puts CoreBluetooth back.

**Pass the backend.** `Central(backend:queue:)` ignores the registry entirely, so nothing
global is touched. Prefer this in unit tests:

```swift
let queue = DispatchQueue(label: "MyTests.central")
let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
```

On iOS and macOS, where `PeripheralHost` exists, it works the same way with
``VirtualPeripheralManagerBackend``, and hosts a
device of its own on the radio that any ``VirtualCentralBackend`` on that radio can discover.

### Simulating MTU

Real peripherals negotiate different ATT MTUs, and code that sizes its chunks from
`maximumWriteValueLength(for:)` — a firmware update, a file transfer — behaves differently
against each. Give a device its own one-packet length with
``VirtualDeviceDescriptor/maximumWriteWithoutResponseLength`` (20 through 512; the default
is ``VirtualRadio/maximumWriteWithoutResponseLength``, 182). A connected `Central` reports
it for `.withoutResponse`, the radio drops a write without response longer than it, and a
notification is truncated to it — exactly what hardware does. A `.withResponse` write is
unaffected: ATT long writes reach ``VirtualRadio/maximumValueLength`` whatever the MTU.

```swift
let descriptor = VirtualDeviceDescriptor(
    name: "Small-MTU HRM",
    advertisement: AdvertisementData(localName: "Small-MTU HRM", serviceUUIDs: [heartRate], isConnectable: true),
    services: services,
    maximumWriteWithoutResponseLength: 20
)
```

### Injecting faults

The failures a real peripheral produces and a handler cannot are armed through the device's
``VirtualDeviceHandle``. Each one goes with the registration: `remove()` and registering the
identifier again starts clean, and a handle from an earlier registration is ignored.

- ``VirtualDeviceHandle/failConnections(with:times:)`` fails the next `times` connection
  attempts (`nil` for every attempt until ``VirtualDeviceHandle/clearConnectionFailures()``)
  with an `NSError` the `Central` receives unchanged, so pass the one CoreBluetooth would.
- ``VirtualDeviceHandle/disconnect(_:error:)`` drops every connected central, or only the
  ones named, as a peripheral-initiated disconnect: the `Central` sees the error (by default
  ``VirtualRadio/peripheralDisconnectedError``, `CBError.peripheralDisconnected`), its
  subscriptions are reported to the handler as unsubscribes, and it is free to reconnect.
- ``VirtualDeviceHandle/setATTError(_:for:operations:)`` answers reads, writes with
  response, and subscribes on one characteristic with an `ATTError`, ahead of the database
  and the handler, so even a static value fails. A write without response has no ATT
  response to carry an error, so it reaches the handler as usual. Note that on iOS,
  CoreBluetooth answers `.insufficientEncryption` and `.insufficientAuthentication` by
  starting pairing and retrying, so an app sees those errors only if pairing fails; the
  radio returns them on the first attempt, so a test asserting on them is testing the
  pairing-failed path.

```swift
// The next connect fails the way a peripheral that forgot its bond does.
await handle.failConnections(with: NSError(domain: "CBErrorDomain", code: 14))

// Reads of the measurement need encryption the central does not have.
await handle.setATTError(.insufficientEncryption, for: measurement, operations: .read)

// Then the link drops.
await handle.disconnect()
```

### Limits

The radio is a harness, not a simulation of the air:

- There is no state restoration: `willRestoreState` is never delivered.
- RSSI is a constant, ``VirtualRadio/rssi``.
- There are no system-connected peripherals; nothing is connected before your code connects it.
- Writes without response and notifications are held to ``VirtualRadio/maximumWriteWithoutResponseLength``,
  and responses to ``VirtualRadio/maximumValueLength``, the way hardware's ATT limits are.
