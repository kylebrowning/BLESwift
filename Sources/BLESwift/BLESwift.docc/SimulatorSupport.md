# Running in the iOS Simulator

Give ``Central`` and ``PeripheralHost`` a working radio in the iOS Simulator by serving them
from a provider process on your Mac.

## Overview

CoreBluetooth is non-functional in the iOS Simulator: `CBCentralManager` reports
``CentralState/unsupported`` and never leaves it, so anything built on BLESwift stops at the
"wait for the radio to power on" line. The usual answer is a hardware device and a cable.

BLESwift ships a second answer. `BLESwiftSimulatorLink` replaces the backends `Central()` and
`PeripheralHost()` construct with ones that forward every call over a localhost TCP connection
to `bleswift-provider`, a command-line tool running on the host Mac. The provider serves that
traffic from the Mac's own Bluetooth radio, from an in-process **virtual radio** hosting devices
you declare, or from both at once.

> Important: The link is **unauthenticated, and intended for loopback only**. A provider serves
> every client that completes its handshake, and there is no handshake secret, no TLS, and no
> access control of any kind — with `--passthrough`, that means the Mac's real Bluetooth radio.
> Both ends default to `127.0.0.1:45541`, and a provider given a loopback host binds the
> loopback interface alone. Give `--listen` any other host and the provider binds every
> interface and prints a warning saying so.

Nothing about this is simulator-specific inside `BLESwift` or `BLESwiftCore`: the whole hook is
`BackendRegistry`, a process-wide pair of optional backend factories that
``Central/init(configuration:)`` and ``PeripheralHost/init(configuration:)`` consult once, at
construction. With nothing registered — every build that is not a Simulator build — they
construct CoreBluetooth exactly as before.

## Adopting it

Two lines in your app, before the first ``Central`` or ``PeripheralHost`` exists:

```swift
import BLESwiftSimulatorLink

#if targetEnvironment(simulator)
SimulatorLink.install()
#endif
```

`install()` registers both backend factories. It must run **before** your first `Central()` /
`PeripheralHost()`: those initializers resolve their backend once, at construction, so an
instance built earlier keeps CoreBluetooth. `SimulatorLink.uninstall()` reverts the registry,
and `SimulatorLink.isInstalled` reports whether the link is in place.

The default endpoint is `127.0.0.1:45541`. The `BLESWIFT_LINK` environment variable, in
`host:port` form, overrides it — on both ends — and an explicit
`SimulatorLink.install(endpoint:)` overrides that. To find out whether a provider is actually
listening before you build anything:

```swift
if await SimulatorLink.isProviderReachable() {
    // A provider accepted a handshake within two seconds.
}
```

`isProviderReachable()` dials, completes the handshake, and disconnects; it never throws.

- Note: `BLESwiftSimulatorLink` builds on every platform BLESwift supports, so a target that
  links it still builds for device. Guard the `install()` call with
  `#if targetEnvironment(simulator)` and your device builds keep CoreBluetooth.

## Running the provider

From a checkout of your package, on the Mac:

```sh
swift run bleswift-provider [--passthrough] [--fixture file.json …] [--listen host:port] [--json]
```

| Flag | Meaning |
|---|---|
| `--passthrough` | Also serve the Mac's real CoreBluetooth radio, alongside the virtual one. |
| `--fixture <path>` | Load a fixture document and host its devices. Repeatable. |
| `--listen <host:port>` | Where to listen. Defaults to `BLESWIFT_LINK`, then `127.0.0.1:45541`. |
| `--json` | Encode outgoing messages as JSON instead of the binary property list default. |

The virtual radio always exists — `--passthrough` *adds* the Mac's radio rather than replacing
anything, so a hosted `PeripheralHost` remains visible to other clients in both modes.

Passthrough is the mode to use when you want your simulator build to talk to real hardware
sitting on your desk. It needs a Bluetooth-entitled, signed build of the provider: macOS gates
CoreBluetooth on the app-sandbox Bluetooth entitlement and on TCC approval, so a bare
`swift run` binary may be denied the radio. Virtual mode needs nothing at all — no entitlement,
no approval, no hardware.

## Declaring virtual devices with a fixture

A fixture is a JSON document describing devices, their advertisements, and their GATT
databases. The provider hosts every device in every `--fixture` it is given:

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
            }
          ]
        }
      ]
    }
  ]
}
```

- `id` is the peripheral identifier your central will see, so pin it to keep a device's
  identity stable across provider restarts.
- `name` and `advertisedServices` become the advertisement's local name and service UUIDs; the
  device always advertises as connectable.
- `value` and the device-level `manufacturerData` are **base64** — `"AEg="` is the two bytes
  `00 48`, a heart-rate measurement of 72 bpm.
- `properties` names the operations the characteristic advertises (`read`, `write`,
  `writeWithoutResponse`, `notify`, `indicate`, `broadcast`, `authenticatedSignedWrites`,
  `extendedProperties`). `permissions` is optional: when it is absent, permissions are
  **derived** — `readable` if the characteristic declares `read`, `notify`, or `indicate`;
  `writeable` if it declares `write` or `writeWithoutResponse`.
- `isPrimary` on a service defaults to `true`.

Fixture devices come with just enough behavior to exercise a real client: reads return the last
value written (starting from the declared one), writes are permission-checked against the
declared properties and then stored, and a write to a characteristic declaring `notify` or
`indicate` is pushed to every subscriber. Write to `2A37` above from one client and every
subscriber to it — including a *different* simulator — receives the notification.

`Scripts/e2e/fixtures/hrm.json` in the repository is a ready-made copy of the document above.

## Declaring virtual devices in Swift

For a device that has to *behave* — computing its answers, notifying on a timer, rejecting
writes — depend on the `BLESwiftProvider` library directly and register a
`VirtualDevice` of your own. A complete executable:

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

A characteristic with a non-`nil` ``GATTCharacteristic/value`` is *static* and answered by the
radio itself; every other read, and every write, reaches your handler — exactly the split
``PeripheralHost`` uses. The `VirtualDeviceHandle` returned by `addVirtualDevice(_:)` lets you
push notifications (`notify(_:for:to:)`), start and stop advertising (`setAdvertising(_:)`),
replace the advertisement or the GATT database (`setAdvertisement(_:)` / `setServices(_:)`), and
remove the device entirely (`remove()`). `ProviderConfiguration` carries the same settings the
command line exposes — `endpoint`, `codec`, `passthrough`, `fixtures` — plus a `log` closure,
and `Provider.handle(for:)` retrieves the handle of a fixture device by its `id`.

## Two simulators talking to each other

Because a `PeripheralHost` served over the link is registered on the provider's virtual radio as
a device, another client's `Central` scan finds it. Two simulator apps — or two instances of the
same app — meet on the virtual radio with no hardware and no entitlements involved: one
advertises, the other scans, connects, reads, writes, and subscribes.

`Scripts/sim-to-sim-e2e.sh` runs exactly that, end to end, across two booted simulators and the
`BLESwiftExplorer` sample app, and runs on CI. See `Scripts/e2e/README.md` for the topology, the
environment overrides, and what to check when it goes red.

## Security

There is none, deliberately. The link carries no authentication, no encryption, and no
authorization: any process that can open a TCP connection to a running `bleswift-provider` and
send a `ClientHello` of the right protocol version is served a full central- or
peripheral-role session. It is a development tool for a Mac talking to its own simulators over
loopback, and it is only safe on that footing.

So: leave the provider on `127.0.0.1`. Passing `--listen` a non-loopback host binds every
interface, exposes the provider — and, under `--passthrough`, the Mac's real radio — to anything
that can route to the port, and makes the provider print
`listening on a non-loopback interface; the link is unauthenticated` at startup. Do not run a
passthrough provider on a shared network, and do not put one behind a port-forward.

## Performance

The link is loopback TCP with a framed, `Codable` message per call. It is fast enough not to
change how your code is written: 500 notifications delivered from a virtual device to a
simulator client complete in roughly 15–25 ms end to end.

That is *not* radio timing. A real connection has a connection interval, a negotiated MTU, and
packets that get lost; the link has none of those. Code that happens to work only because every
operation returns in microseconds may still fail on hardware, which is why the link complements
device testing rather than replacing it.

## Where the link diverges from CoreBluetooth

Everything below is deliberate, tested behavior — worth knowing before you conclude the link
is broken.

- **`systemConnectedPeripherals(withServices:)`.** Over the link this returns only peripherals
  *this client* connected, whose cached service discovery matches the requested services. It is
  not a view of what the whole system is connected to, because a link session sees only its own
  connections.
- **No state restoration.** The link has no equivalent of CoreBluetooth relaunching your app:
  `Central.restorationEvents()` and `PeripheralHost.restorationEvents()` never deliver a
  `willRestore`. Relatedly, ``Central/stopAndExtractState()`` and
  ``PeripheralHost/stopAndExtractState()`` throw ``BLESwiftError/stopped`` on a link backend —
  there is no `CBCentralManager` underneath to hand back.
- **ANCS.** The `requiresANCS:` argument to `Central.connect(_:)` is forwarded to the Mac's
  real radio under `--passthrough`, and `Peripheral.ancsAuthorized` mirrors whatever the
  provider reports for that connection. The virtual radio has no ANCS, so a virtual device
  always reports `false`.
- **System connection events.** `Central.connectionEventRegistration(services:peripherals:)`
  is a no-op against the Mac's real radio: CoreBluetooth has no
  `registerForConnectionEvents(options:)` on macOS, so there is nothing for the provider to
  register. The virtual radio does not synthesize them either.
- **No L2CAP on the virtual radio.** ``Peripheral/openL2CAPChannel(psm:timeout:)`` against a
  virtual device fails with an `NSError` in the `BLESwiftProvider` domain, code `3`. L2CAP works
  over the link only in `--passthrough` mode, against a real peripheral.
- **`knownPeripherals(withIdentifiers:)` answers for every identifier.** The seam call behind
  it is synchronous, with no wire round trip to ask the provider what it has seen, so the link
  vends a placeholder ``Peripheral`` for *every* identifier passed — including ones neither it
  nor the provider recognizes. That is what lets `Central.connect(identifier:)` reach a
  peripheral the passthrough radio remembers from a previous run of your app. An identifier
  nothing knows fails at connect instead of being omitted here: `didFailToConnect` with an
  `NSError` in the `BLESwiftProvider` domain, code `1`.
- **Initial radio state.** A link-backed ``Central`` reports ``CentralState/unsupported`` until
  the provider answers — the same state the Simulator reports today, so an app that waits for
  `.poweredOn` simply waits — and then reports whatever state the provider does. If the provider
  goes away, in-flight operations fail and the state returns to `.unsupported` until it comes
  back.

## Topics

### Related articles

- <doc:PeripheralRole>
- <doc:L2CAPChannels>
- <doc:BackgroundRestoration>
