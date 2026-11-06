# Running in the iOS Simulator

Give ``Central`` and ``PeripheralHost`` a working radio in the iOS Simulator. A provider process on your Mac serves them.

## Overview

CoreBluetooth does not work in the iOS Simulator. `CBCentralManager` reports ``CentralState/unsupported`` and stays in that state. Code that waits for the radio to power on does not continue. Hardware and a cable are the usual solution.

BLESwift has another solution. `BLESwiftSimulatorLink` replaces the backends that `Central()` and `PeripheralHost()` create. The new backends forward every call over a localhost TCP connection to `bleswift-provider`, a command-line tool on the host Mac. The provider can serve the traffic from one of these:

- The Mac's own Bluetooth radio.
- An in-process **virtual radio** that hosts devices that you declare.
- Both at the same time.

> Important: The link is **unauthenticated and for loopback only**. It has no handshake secret, no TLS, and no access control. A provider serves every client that completes the handshake. With `--passthrough`, this includes the Mac's real Bluetooth radio. Both ends default to `127.0.0.1:45541`. A provider with a loopback host binds only the loopback interface. If you give `--listen` any other host, the provider binds every interface and prints a warning.

`BLESwift` and `BLESwiftCore` have no simulator-specific code. The hook is `BackendRegistry`, a process-wide pair of optional backend factories. ``Central/init(configuration:)`` and ``PeripheralHost/init(configuration:)`` read it once, when they create an instance. If no factory is registered, they create CoreBluetooth backends.

## Adopting it

Add these lines to your app. They must run before the first ``Central`` or ``PeripheralHost`` exists:

```swift
import BLESwiftSimulatorLink

#if targetEnvironment(simulator)
SimulatorLink.install()
#endif
```

`install()` registers both backend factories. Call it **before** your first `Central()` or `PeripheralHost()`. An instance that exists already keeps CoreBluetooth. `SimulatorLink.uninstall()` removes the factories. `SimulatorLink.isInstalled` shows whether the link is installed.

The default endpoint is `127.0.0.1:45541`. Set the `BLESWIFT_LINK` environment variable to `host:port` to change it on both ends. `SimulatorLink.install(endpoint:)` overrides the variable. To check that a provider is listening, call `isProviderReachable()`:

```swift
if await SimulatorLink.isProviderReachable() {
    // A provider accepted a handshake within two seconds.
}
```

`isProviderReachable()` connects, completes the handshake, and disconnects. It never throws.

> Note: `BLESwiftSimulatorLink` builds on every platform that BLESwift supports. A target that links it still builds for a device. Put `install()` inside `#if targetEnvironment(simulator)`, and device builds keep CoreBluetooth.

## Running the provider

On the Mac, run the provider from a checkout of your package:

```sh
swift run bleswift-provider [--passthrough] [--fixture file.json …] [--listen host:port] [--json]
```

| Flag | Meaning |
|---|---|
| `--passthrough` | Also serve the Mac's real CoreBluetooth radio, alongside the virtual one. |
| `--fixture <path>` | Load a fixture document and host its devices. Repeatable. |
| `--listen <host:port>` | Where to listen. Defaults to `BLESWIFT_LINK`, then `127.0.0.1:45541`. Use a literal address. The provider and the client both change `localhost` to `127.0.0.1`, so that the two ends use the same loopback family. |
| `--json` | Encode outgoing messages as JSON instead of the binary property list default. |

The virtual radio always exists. `--passthrough` adds the Mac's radio. It does not replace the virtual radio. A hosted `PeripheralHost` is visible to other clients in both modes.

Use passthrough when a simulator build must talk to real hardware. Passthrough needs a signed build of the provider with the Bluetooth entitlement. macOS gates CoreBluetooth on the app-sandbox Bluetooth entitlement and on TCC approval. A bare `swift run` binary can lose access to the radio. The virtual radio needs no entitlement, no approval, and no hardware.

If the Mac's radio is off, the virtual radio still serves clients. The real radio joins when it powers on. A hosted `PeripheralHost` publishes its services and advertises on the radios that are on. It does not wait for a radio that is off, unauthorized, or resetting. So `add` and `startAdvertising` complete, and notifications continue, with Bluetooth off. When the Mac's radio powers on, the provider publishes the current services to it and restarts the advertisement. No reconnect is necessary.

## Declaring virtual devices with a fixture

A fixture is a JSON document that describes devices, their advertisements, and their GATT databases. The provider hosts every device in every `--fixture` file.

```json
{
  "devices": [
    {
      "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
      "name": "Fixture HRM",
      "advertisedServices": ["180D"],
      "services": [
        {
          "uuid": "180D",
          "characteristics": [
            {
              "uuid": "2A37",
              "properties": ["read", "notify"],
              "value": "AEg="
            },
            {
              "uuid": "2A39",
              "properties": ["read", "write", "notify"],
              "value": "AA=="
            }
          ]
        }
      ]
    }
  ]
}
```

- `id` is the peripheral identifier that your central sees. Keep it fixed so that the device keeps its identity when the provider restarts.
- `name` and `advertisedServices` become the local name and service UUIDs of the advertisement. The device always advertises as connectable.
- `value` and the device-level `manufacturerData` are **base64**. For example, `"AEg="` is the two bytes `00 48`, a heart-rate measurement of 72 bpm.
- `properties` lists the operations of the characteristic: `read`, `write`, `writeWithoutResponse`, `notify`, `indicate`, `broadcast`, `authenticatedSignedWrites`, and `extendedProperties`.
- `permissions` is optional. If it is absent, BLESwift derives it. A characteristic is `readable` if it declares `read`, `notify`, or `indicate`. It is `writeable` if it declares `write` or `writeWithoutResponse`.
- `isPrimary` on a service defaults to `true`.
- A device needs only `id`. A service and a characteristic need only `uuid`. All other keys are optional and have the same defaults as the Swift types. So `{ "id": "…" }` is a complete device that hosts no GATT database. `{ "uuid": "180D" }` is a complete service with no characteristics.

Fixture devices behave enough like real devices to test a client:

- A read returns the last value written. Before the first write, it returns the declared value.
- A write is checked against the declared properties and then stored.
- A write to a characteristic that declares `notify` or `indicate` is pushed to every subscriber.

For example, write to `2A39` from one client, and every subscriber receives the notification, even in a *different* simulator. `2A37` declares no `write`, so a write to it is refused.

Reads are also checked. They return the ATT errors that real hardware returns:

- `attributeNotFound` for a characteristic that the fixture does not declare.
- `readNotPermitted` for a characteristic that declares none of `read`, `notify`, and `indicate`.
- `invalidOffset` for an `offset` past the end of the stored value.

An offset inside the value returns the value from that offset. An offset equal to the length returns no data.

`Scripts/e2e/fixtures/hrm.json` in the repository is a ready-made copy of the document above.

## Declaring virtual devices in Swift

For a device that must *behave*, for example compute its answers, notify on a timer, or reject writes, register your own `VirtualDevice`. Depend on the `BLESwiftProvider` library. This is a complete executable:

```swift
import BLESwiftCore
import BLESwiftProvider
import Foundation

let heartRate = ServiceIdentifier(uuid: "180D")
let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

struct HeartRateHandler: VirtualDeviceHandler {
    func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
        .success(Data([0x00, 72]))
    }
    func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
        .failure(.writeNotPermitted)
    }
    func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
}

let provider = Provider(configuration: ProviderConfiguration())
let handle = await provider.addVirtualDevice(VirtualDevice(
    descriptor: VirtualDeviceDescriptor(
        name: "Virtual HRM",
        advertisement: AdvertisementData(localName: "Virtual HRM", serviceUUIDs: [heartRate], isConnectable: true),
        services: [GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable])
        ])]
    ),
    handler: HeartRateHandler()
))
try await provider.start()

while true {
    await handle.notify(Data([0x00, UInt8.random(in: 60...90)]), for: measurement, to: nil)
    try await Task.sleep(for: .seconds(1))
}
```

The radio itself answers reads of a characteristic with a non-`nil` ``GATTCharacteristic/value`` (a *static* characteristic). All other reads and all writes go to your handler. ``PeripheralHost`` follows the same rule.

`addVirtualDevice(_:)` returns a `VirtualDeviceHandle`. Use it to do these tasks:

- `notify(_:for:to:)` pushes a notification.
- `setAdvertising(_:)` starts or stops advertising.
- `setAdvertisement(_:)` and `setServices(_:)` replace the advertisement or the GATT database.
- `remove()` removes the device.

`ProviderConfiguration` has the same settings as the command line (`endpoint`, `codec`, `passthrough`, `fixtures`) and a `log` closure. `Provider.handle(for:)` returns the handle of a fixture device by its `id`.

To use a virtual radio in your own process, without a provider, see the `BLESwiftVirtualRadio` module.

## Two simulators

A `PeripheralHost` that is served over the link is a device on the virtual radio of the provider. A `Central` in another client can find it with a scan. So two simulator apps, or two instances of one app, can talk with no hardware and no entitlements. One app advertises. The other scans, connects, reads, writes, and subscribes.

`Scripts/sim-to-sim-e2e.sh` runs this flow with two booted simulators and the `BLESwiftExplorer` sample app. The provider binds an ephemeral loopback port. `BLESWIFT_LINK` gives that port to both apps. The script runs locally. It also runs on every push to `main` and on every same-repository pull request, on the self-hosted CI runner of the project. See `Scripts/e2e/README.md` for the topology, the environment overrides, and the checks to make when the test fails.

## Security and performance

The link has no authentication, no encryption, and no authorization. Any process that can open a TCP connection to `bleswift-provider` and send a `ClientHello` with the right protocol version gets a full central-role or peripheral-role session. It is a development tool for a Mac and its own simulators on loopback.

- Keep the provider on `127.0.0.1`.
- A non-loopback `--listen` host binds every interface. It exposes the provider, and with `--passthrough` the Mac's real radio, to anything that can reach the port. The provider prints `listening on a non-loopback interface; the link is unauthenticated` at startup.
- Do not run a passthrough provider on a shared network. Do not put one behind a port-forward.

The link is fast. In one test, 500 notifications from a virtual device to a simulator client took about 15 to 25 ms. This is not radio timing. The link has no connection interval, no MTU negotiation, and no packet loss. Code that works only because every operation is instant can fail on hardware. Test on a device also.

## Where the link differs from CoreBluetooth

These differences are deliberate and tested. Read them before you decide that the link is broken.

- **`systemConnectedPeripherals(withServices:)`** returns only the peripherals that *this client* connected and whose cached service discovery matches. A link session sees only its own connections.
- **No state restoration.** `Central.restorationEvents()` and `PeripheralHost.restorationEvents()` never deliver `willRestore`. ``Central/stopAndExtractState()`` and ``PeripheralHost/stopAndExtractState()`` throw ``BLESwiftError/stopped`` on a link backend. There is no `CBCentralManager` to return.
- **No ANCS.** The provider is a macOS process, and ANCS is an iOS feature. In both modes, `requiresANCS:` has no effect, and `Peripheral.ancsAuthorized` is always `false`.
- **System connection events.** `Central.connectionEventRegistration(services:peripherals:)` does nothing against the Mac's real radio, because macOS has no `registerForConnectionEvents(options:)`. The virtual radio does not create these events.
- **No L2CAP on the virtual radio.** ``Peripheral/openL2CAPChannel(psm:timeout:)`` against a virtual device fails with an `NSError` in the `BLESwiftProvider` domain, code `3`. L2CAP works only in `--passthrough` mode, against a real peripheral.
- **`knownPeripherals(withIdentifiers:)` accepts every identifier.** The call is synchronous, so the link cannot ask the provider. It returns a placeholder ``Peripheral`` for every identifier, even for unknown ones. This lets `Central.connect(identifier:)` reach a peripheral that the passthrough radio remembers from an earlier run. An unknown identifier fails at connect with `didFailToConnect` and an `NSError` in the `BLESwiftProvider` domain, code `1`.
- **No flow control toward your client.** The link limits what a hosted `PeripheralHost` pushes, with an application-level window. This is why `PeripheralHost/updateValue(_:for:onSubscribed:)` can wait. Nothing limits the other direction. A provider delivers each notification as fast as its backend produces it, as CoreBluetooth does. A client that does not drain its notification stream collects the values in the transport. The peripheral does not slow down.
- **A dropped link empties a hosted `PeripheralHost`.** The provider's session owns the GATT database and the advertising state of the device. Both are lost when the link drops. This is the same as a CoreBluetooth power cycle. On the next `.poweredOn`, call `add(_:)` and `startAdvertising(_:)` again. The provider replays nothing. The device identifier does not change for the life of the `PeripheralHost`. A central that saved the `PeripheralIdentifier` can connect again after the host publishes again.
- **Write limits are emulated. The MTU is not negotiated.** The virtual radio reports 512 bytes for a `.withResponse` write and 182 bytes for a `.withoutResponse` write. 182 is the iOS ATT_MTU of 185 less the 3-byte header. It enforces both limits. A `.withResponse` write above 512 bytes fails with `CBATTErrorDomain` code 13 (`invalidAttributeValueLength`). A `.withoutResponse` write above 182 bytes is dropped without a report, as CoreBluetooth does. A real connection can agree on a much smaller MTU. Call ``Peripheral/maximumWriteValueLength(for:)`` and do not assume a constant. A `--passthrough` connection reports the real maximum of the hardware.
- **Notifications are truncated, not split.** A notification is one ATT packet. The virtual radio reports 182 bytes as the ``Subscriber/maximumUpdateValueLength`` and clips a longer value to it. Nothing splits a large value into several notifications, on the link or on a device. Read ``Subscriber/maximumUpdateValueLength`` and split the value yourself.
- **An L2CAP open that is pending at a disconnect can get the wrong channel.** `didOpenL2CAPChannel` does not say which open it answers. The provider matches answers to your `openL2CAPChannel(_:)` calls in arrival order for each peripheral. An answer that arrives before you reconnect is discarded. An answer that arrives after you reconnect and open again is used for the new open. You then get the channel of the previous connection. If a channel that you opened after a reconnect behaves like one from the old connection, close it and open again. Virtual devices are not affected.
- **A `.withoutResponse` backlog has a limit. If you exceed it, the provider drops the backlog.** The client sends each `.withoutResponse` write immediately, even when its window of 64 writes is full. The provider holds the writes that its backend cannot accept, up to 1024 writes or 1 MiB for each peripheral. Above that limit, the provider discards the whole backlog of that peripheral, including older writes. It keeps the link and acknowledges the discarded writes, so the window opens again. ``Peripheral/write(_:to:type:timeout:)`` waits for the window, and ``Central`` resumes all waiting writers on one readiness signal. So an app with many more than 64 concurrent `.withoutResponse` writers can exceed the limit and lose payloads without an error. Limit the number of concurrent `.withoutResponse` writers for each peripheral, as you do on a device.
- **Initial radio state.** A link-backed ``Central`` reports ``CentralState/unsupported`` until the provider answers. Then it reports the state of the provider. If the provider goes away, operations in progress fail and the state returns to `.unsupported` until the provider returns.

## Topics

### Related articles

- <doc:PeripheralRole>
- <doc:L2CAPChannels>
- <doc:BackgroundRestoration>
