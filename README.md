# BLESwift

[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylebrowning%2FBLESwift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylebrowning/BLESwift)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylebrowning%2FBLESwift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylebrowning/BLESwift)

**BLESwift** is an async/await-first Bluetooth Low Energy library for Swift 6.2.
It wraps CoreBluetooth in a single actor whose isolation is tied directly to the dispatch queue
CoreBluetooth delivers its callbacks on — no closures, no callback compatibility layer, and no
delegate protocols to implement. Connecting, reading, writing, and scanning are `async throws`
or `AsyncSequence`-based; every multi-consumer feed (Bluetooth state, connection lifecycle,
notifications, restoration) is a real multicast stream that every subscriber observes
independently; and both halves of CoreBluetooth — the central role and the peripheral role —
are covered, along with scriptable fakes so you can unit-test your BLE code without hardware.

## Features

- **Pure async/await API.** `actor Central`, `async throws` connect/read/write, and
  `AsyncSequence` for scanning and notifications — nothing to bridge from a callback yourself.
- **Actor-isolated core.** `Central`'s isolation is tied directly to the `DispatchSerialQueue`
  its `CBCentralManager` delivers delegate callbacks on, so every CoreBluetooth event is handled
  on the actor's own executor with no thread hop and no ordering hazards.
- **Rich scanning.** `scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)` yields
  `.discovered` / `.updated` / `.lost` events, with signal-strength filtering, a loss timeout
  for peripherals that stop advertising, and an overall scan timeout that finishes the stream
  cleanly.
- **Peripheral retrieval.** `knownPeripherals(withIdentifiers:)` and
  `systemConnectedPeripherals(withServices:)` reconnect to peripherals you already know about
  without scanning for them again.
- **Multi-peripheral connections.** Connect to any number of peripherals at once, each with its
  own independent connection lifecycle, `ReconnectPolicy`, and isolated GATT/notification state.
- **Declarative reconnection.** `ReconnectPolicy` (`.never`, `.always(maxAttempts:backoff:)`,
  or fully custom backoff logic) replaces manual retry bookkeeping.
- **Timeouts everywhere.** Connect, read, write, descriptor operations, RSSI reads, and L2CAP
  channel opens all take an optional `Duration` and throw on expiry instead of hanging.
- **Typed SIG profile decoders.** The optional `BLESwiftProfiles` product decodes standard
  Bluetooth SIG characteristics — Heart Rate Measurement, Battery Level, Device Information,
  Current Time, Body Sensor Location, CSC Measurement, Cycling Power Measurement, and
  Temperature Measurement (IEEE 11073 float) — into typed values, plus
  `Peripheral.readDeviceInformation()` / `readBatteryLevel()` conveniences.
- **GATT enumeration and introspection.** `discoverServices()`,
  `discoverCharacteristics(for:)`, `discoverDescriptors(for:)`, and `properties(of:)` let you
  walk an unknown peripheral's attribute graph.
- **Descriptors.** Descriptor discovery plus `readDescriptor(_:timeout:)` and
  `writeDescriptor(_:value:timeout:)`, addressed by `DescriptorIdentifier`.
- **Write-without-response backpressure.** `.withoutResponse` writes await CoreBluetooth's
  `canSendWriteWithoutResponse` / `isReadyToSendWriteWithoutResponse` signal instead of
  silently dropping packets, and `maximumWriteValueLength(for:)` reports the usable payload
  size for each write type.
- **RSSI and service changes.** `readRSSI(timeout:)` for live signal strength, and
  `serviceChanges()` for a stream of the peripheral re-declaring its services.
- **Multicast everything.** Bluetooth state, connection lifecycle, characteristic
  notifications, and restoration events all support any number of independent concurrent
  subscribers.
- **L2CAP channels.** Open a connection-oriented channel with `openL2CAPChannel(psm:timeout:)`
  and stream bytes over it — an `AsyncThrowingStream` in, `write(_:)` out.
- **Peripheral role.** `PeripheralHost` hosts a GATT database (`GATTService`,
  `GATTCharacteristic`, `CharacteristicProperties`, `AttributePermissions`), advertises it,
  streams read/write requests and subscriber changes, and responds with `ATTError` on failure.
  iOS and macOS only — CoreBluetooth has no peripheral role on the other platforms.
- **Background restoration for both roles.** iOS state restoration surfaces as a single
  buffered, replay-on-subscribe event stream for the central role and again for the peripheral
  role — see the DocC article for the launch-time discipline it requires.
- **Typed serialization.** `Transmittable` / `Receivable` give you typed reads and writes, with
  conformances for the fixed-width integers, `String`, `Data`, and `DataPadding`, plus
  `combine(_:)` for concatenating a payload.
- **Composite helpers.** `writeAndAwaitNotification`, `writeAndAssemble`, and `flush` collapse
  the common request/response and multi-packet-assembly patterns into one call.
- **Bluetooth SIG assigned numbers.** `GATTAssignedNumbers` (and `.name` on the identifier
  types) turns standard 16-bit and 128-bit UUIDs into human-readable names for logging and UI.
- **Adopt an existing manager.** `Central(adopting:connectedPeripherals:callbackQueue:)` wraps
  a `CBCentralManager` you already own, for incremental migration.
- **Unit-testable without hardware.** `BLESwiftTestSupport` ships `FakeCentral`,
  `FakePeripheral`, `FakeL2CAPChannel`, and `FakePeripheralManager` — scriptable stand-ins for
  the CoreBluetooth types, wired into a real `Central` through the public backend seam.
- **Every CoreBluetooth platform.** iOS, macOS, watchOS, tvOS, and visionOS, at each platform's
  floor for Swift 6.2's custom-executor isolation checking.
- **One runtime dependency.** [swift-log](https://github.com/apple/swift-log) — install a
  custom `LogHandler` to observe BLESwift's internal logging; nothing else.

## What BLESwift does for you

| Capability | Direct CoreBluetooth | BLESwift |
|---|---|---|
| Scanning | `didDiscover` callbacks; you dedupe, filter RSSI, and time out yourself | `scan(...)` yields `.discovered` / `.updated` / `.lost`, with `rssiThreshold`, `allowDuplicates`, `lossTimeout`, `timeout` |
| Connect/disconnect | `connect` returns void; success or failure arrives on a delegate later | `try await central.connect(id)` returns a `Peripheral` or throws |
| Reconnect | delegate callbacks, manual retry bookkeeping | `ReconnectPolicy` per connection (`.never`, `.always(maxAttempts:backoff:)`, `.custom`) |
| Read/write | untyped `Data` matched to a `CBCharacteristic` you must first discover | `try await peripheral.read(from:)` / `write(_:to:type:)`, typed via `Receivable`/`Transmittable`, addressed by identifier |
| Timeouts | none; a stalled operation never completes | optional `Duration` on connect, read, write, descriptor ops, RSSI, and L2CAP open |
| Write without response | check `canSendWriteWithoutResponse`, else wait for a delegate callback | writes await readiness automatically; `maximumWriteValueLength(for:)` for sizing |
| Notifications | one delegate callback for all characteristics on the peripheral | per-characteristic multicast `AsyncThrowingStream`, typed, with a `BufferingPolicy` |
| Descriptors | discover, then match `CBDescriptor` objects by hand | `DescriptorIdentifier` plus `discoverDescriptors(for:)`, `readDescriptor`, `writeDescriptor` |
| RSSI | `readRSSI()` then `didReadRSSI` on the delegate | `try await peripheral.readRSSI(timeout:)` |
| Service changed | `didModifyServices`; you rediscover and reconcile | `serviceChanges()` stream of the affected services |
| L2CAP | open, then bridge `NSStream` delegates to your own buffering | `openL2CAPChannel(psm:)` gives `incomingData` as a stream and `write(_:)` |
| Peripheral role | `CBPeripheralManager` plus a second delegate protocol | `PeripheralHost` actor: `add(_:)`, `startAdvertising(_:)`, request/subscriber streams (iOS, macOS) |
| Background restoration | a `willRestoreState` options dictionary you must decode at launch | typed `RestoredState` on a buffered, replay-on-subscribe event stream, for both roles |
| Multi-peripheral | one delegate demultiplexes every peripheral's events | one `Peripheral` value per connection, each with isolated GATT and notification state |
| Unit testing without hardware | `CBCentralManager` cannot be constructed or scripted | `FakeCentral`/`FakePeripheral`/`FakePeripheralManager` drive a real `Central` |

## Quick start

```swift
import BLESwift
import BLESwiftProfiles

let central = Central()

// Wait for the radio to power on.
for await state in await central.stateEvents() {
    if state == .poweredOn { break }
}

// Scan for a peripheral advertising the Heart Rate service, then stop.
var target: PeripheralIdentifier?
for try await event in await central.scan(services: [HeartRateMeasurement.service]) {
    if case .discovered(let discovery) = event {
        target = discovery.peripheral
        break
    }
}

guard let identifier = target else { return }

// Connect, with automatic reconnection on unexpected disconnects.
let peripheral = try await central.connect(identifier, reconnect: .always())

// Subscribe to heart-rate notifications (decoder from BLESwiftProfiles).
let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: HeartRateMeasurement.characteristic)

for try await reading in readings {
    print("\(reading.beatsPerMinute) bpm")
}
```

See [`Examples/HeartRateMonitor`](Examples/HeartRateMonitor/HeartRateMonitor.swift) for the full
worked example (using `BLESwiftProfiles`' `HeartRateMeasurement`), and the DocC catalog for a full
walkthrough: Getting Started, Scanning, Connections & Reconnection, Reading/Writing &
Notifications, L2CAP Channels, the Peripheral Role, and Background Restoration.

## Testing

You don't need real hardware to unit-test code built on `Central`. The `BLESwiftTestSupport`
product ships `FakeCentral`/`FakePeripheral` — scriptable stand-ins for
`CBCentralManager`/`CBPeripheral` — plus `FakeL2CAPChannel` and `FakePeripheralManager` for the
L2CAP and peripheral-role paths, and `Central`'s public
`init(backend:queue:configuration:startupBackgroundTask:connectedPeripherals:)`, which wires a
real `Central` to them instead of CoreBluetooth:

```swift
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

let queue = DispatchSerialQueue(label: "MyAppTests.rig")
let fakeCentral = FakeCentral(queue: queue)
let central = Central(backend: fakeCentral, queue: queue)

fakeCentral.simulateStateChange(.poweredOn)
// ... script connects, reads, writes, and notifications against `fakeCentral`/a `FakePeripheral`
```

See the `BLESwiftTestSupport` module's "Testing Your BLE Code" DocC article for the full rig
pattern and scripting reference, and
[`Examples/ConsumerTests`](Examples/ConsumerTests/Tests/ConsumerTests/ConsumerTests.swift) for
a complete, standalone package exercising this exact pattern from outside BLESwift itself (no
`@testable import`).

## BLE in the iOS Simulator

CoreBluetooth is non-functional in the iOS Simulator. `BLESwiftSimulatorLink` fixes that without
changing a line of your BLE code: it swaps the backends `Central()` and `PeripheralHost()`
construct for ones that forward every call over localhost TCP to `bleswift-provider` on your Mac.

```swift
import BLESwiftSimulatorLink

#if targetEnvironment(simulator)
SimulatorLink.install()   // before your first Central() / PeripheralHost()
#endif
```

```sh
swift run bleswift-provider --passthrough        # also serve the Mac's real radio
swift run bleswift-provider --fixture hrm.json   # serve virtual devices from JSON
```

The virtual radio needs no hardware, no entitlements, and no approval — and because a
simulator's `PeripheralHost` is hosted on it as a device, **two simulators can talk to each
other** (`Scripts/sim-to-sim-e2e.sh`, which runs on CI). `--passthrough` additionally exposes
your Mac's real radio, and needs a Bluetooth-entitled, signed provider build. See the
[Running in the iOS Simulator](Sources/BLESwift/BLESwift.docc/SimulatorSupport.md) DocC article
for fixtures, code-defined virtual devices, and the documented divergences from CoreBluetooth.

## Platform support

| Platform  | Minimum version |
|-----------|-----------------|
| iOS       | 18.0            |
| macOS     | 15.0            |
| watchOS   | 11.0            |
| tvOS      | 18.0            |
| visionOS  | 2.0             |
| iOS Simulator | 18.0, via `BLESwiftSimulatorLink` + `bleswift-provider` |

The central role is available on every platform above. The peripheral role (`PeripheralHost`)
is iOS and macOS only, because CoreBluetooth's `CBPeripheralManager` does not exist elsewhere.
The iOS Simulator has no working CoreBluetooth at all; both roles run there over
`BLESwiftSimulatorLink` and a host-side `bleswift-provider` — see
[BLE in the iOS Simulator](#ble-in-the-ios-simulator).

## Installation

Add BLESwift to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/kylebrowning/BLESwift.git", from: "2.0.0")
]
```

Then add `"BLESwift"` to your target's dependencies.

## Documentation

Each module ships a DocC catalog. Hosted on the Swift Package Index:

- [BLESwift](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswift) —
  `Central`, connections, scanning, GATT, L2CAP, the peripheral role, restoration
  ([in repo](Sources/BLESwift/BLESwift.docc/BLESwift.md))
- [BLESwiftCore](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftcore) —
  the backend-agnostic types, the backend seam, and assigned numbers
  ([in repo](Sources/BLESwiftCore/BLESwiftCore.docc/BLESwiftCore.md))
- [BLESwiftProfiles](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftprofiles) —
  typed decoders for standard Bluetooth SIG GATT characteristics
  ([in repo](Sources/BLESwiftProfiles/BLESwiftProfiles.docc/BLESwiftProfiles.md))
- [BLESwiftTestSupport](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswifttestsupport) —
  the fakes and the testing rig
  ([in repo](Sources/BLESwiftTestSupport/BLESwiftTestSupport.docc/BLESwiftTestSupport.md))
- [BLESwiftSimulatorLink](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftsimulatorlink) —
  `SimulatorLink.install()` and the simulator-side link backends
  ([in repo](Sources/BLESwiftSimulatorLink/BLESwiftSimulatorLink.docc/BLESwiftSimulatorLink.md))
- [BLESwiftProvider](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftprovider) —
  the host-side provider, the virtual radio, and code-defined virtual devices
  ([in repo](Sources/BLESwiftProvider/BLESwiftProvider.docc/BLESwiftProvider.md))
- [BLESwiftLink](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftlink) —
  the wire protocol and the fixture format the two halves share
  ([in repo](Sources/BLESwiftLink/BLESwiftLink.docc/BLESwiftLink.md))

(The hosted pages appear once the next tagged release is indexed; until then, read the catalogs
in the repository or build them locally with `swift package generate-documentation`.)

Examples:

- [`Examples/BLESwiftExplorer`](Examples/BLESwiftExplorer) — a SwiftUI sample app for iOS and
  macOS that exercises the full public surface: filtered scanning, connecting, GATT browsing,
  reads/writes (single and chunked), notifications, RSSI polling, connection logging, saved-device
  reconnect, system connection events, ANCS, and background restoration.
- [`Examples/HeartRateMonitor`](Examples/HeartRateMonitor) — an end-to-end central-role app flow.
- [`Examples/ConsumerTests`](Examples/ConsumerTests) — a standalone package unit-testing BLE
  code against the fakes, from outside BLESwift.

Contributing: see [CONTRIBUTING.md](CONTRIBUTING.md). Release history:
[CHANGELOG.md](CHANGELOG.md).

## License

BLESwift is available under the Apache License 2.0. See [LICENSE](LICENSE) for the full text.
