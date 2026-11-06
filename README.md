# BLESwift

[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylebrowning%2FBLESwift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylebrowning/BLESwift)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylebrowning%2FBLESwift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylebrowning/BLESwift)

**BLESwift** is a Bluetooth Low Energy library for Swift 6.2 that uses async/await.
It puts CoreBluetooth inside one actor. You do not write delegates or callbacks.
You connect, read, write, and scan with `async throws` calls and `AsyncSequence` streams.
BLESwift supports the central role and the peripheral role. It also includes fakes, so you
can test your BLE code without hardware.

## Installation

Add BLESwift to the dependencies in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kylebrowning/BLESwift.git", from: "3.1.0")
]
```

Then add `"BLESwift"` to the dependencies of your target.

## Quick start

```swift
import BLESwift
import BLESwiftProfiles

let central = Central()

// Wait until the radio is on.
for await state in await central.stateEvents() {
    if state == .poweredOn { break }
}

// Find one peripheral that advertises the Heart Rate service, then stop the scan.
var target: PeripheralIdentifier?
for try await event in await central.scan(services: [HeartRateMeasurement.service]) {
    if case .discovered(let discovery) = event {
        target = discovery.peripheral
        break
    }
}

guard let identifier = target else { return }

// Connect. If the connection drops unexpectedly, BLESwift connects again.
let peripheral = try await central.connect(identifier, reconnect: .always())

// Receive heart-rate notifications. BLESwiftProfiles decodes each value.
let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: HeartRateMeasurement.characteristic)

for try await reading in readings {
    print("\(reading.beatsPerMinute) bpm")
}
```

For the full example, see
[`Examples/HeartRateMonitor`](Examples/HeartRateMonitor/HeartRateMonitor.swift).
The DocC catalog has articles about these topics:

- Getting started
- Scanning
- Connections and reconnection
- Reads, writes, and notifications
- L2CAP channels
- The peripheral role
- Background restoration

## Testing

You do not need real hardware to test code that uses `Central`. The `BLESwiftTestSupport`
product contains these fakes:

- `FakeCentral` and `FakePeripheral`, which replace `CBCentralManager` and `CBPeripheral`
- `FakeL2CAPChannel`, for L2CAP code
- `FakePeripheralManager`, for peripheral-role code

You control each fake from your test. To connect a real `Central` to a fake instead of to
CoreBluetooth, use the public
`init(backend:queue:configuration:startupBackgroundTask:connectedPeripherals:)`:

```swift
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

let queue = DispatchQueue(label: "MyAppTests.rig")
let fakeCentral = FakeCentral(queue: queue)
let central = Central(backend: fakeCentral, queue: queue)

fakeCentral.simulateStateChange(.poweredOn)
// Script the connects, reads, writes, and notifications on `fakeCentral` and a `FakePeripheral`.
```

For the full procedure, read the "Testing Your BLE Code" article in the `BLESwiftTestSupport`
documentation. For a complete example, see
[`Examples/ConsumerTests`](Examples/ConsumerTests/Tests/ConsumerTests/ConsumerTests.swift).
That package uses the fakes from outside BLESwift, without `@testable import`.

## BLE in the iOS Simulator

CoreBluetooth does not work in the iOS Simulator. `BLESwiftSimulatorLink` lets your BLE code
run there without changes. It replaces the backends that `Central()` and `PeripheralHost()`
use. The new backends send each call over a localhost TCP connection to `bleswift-provider`,
which runs on your Mac.

```swift
import BLESwiftSimulatorLink

#if targetEnvironment(simulator)
SimulatorLink.install()   // Call this before your first Central() or PeripheralHost().
#endif
```

```sh
swift run bleswift-provider --passthrough        # Also give access to the Mac's real radio.
swift run bleswift-provider --fixture hrm.json   # Serve virtual devices from a JSON file.
```

The provider has a virtual radio. The virtual radio does not need hardware, entitlements, or
approval. A `PeripheralHost` in a simulator becomes a device on the virtual radio, so
**two simulators can communicate**. `Scripts/sim-to-sim-e2e.sh` tests this. You can run it
locally. CI also runs it on each push to `main` and on each pull request from this repository.

The `--passthrough` option also gives access to the real radio of your Mac. For this option,
the provider build must be signed and must have the Bluetooth entitlement.

For fixtures, virtual devices in code, and the differences from CoreBluetooth, read the
[Running in the iOS Simulator](Sources/BLESwift/BLESwift.docc/SimulatorSupport.md) article.

### Mocking Bluetooth in-process

`BLESwiftVirtualRadio` is the same virtual radio without the provider. It runs inside your
app or test process, on all platforms. A `Central` can scan for, connect to, and read the
devices that you register in code. This works on a device and in the simulator. It does not
use TCP or a second process.

```swift
import BLESwiftVirtualRadio

let radio = VirtualRadio()
// Register your VirtualDevice values on `radio`.
VirtualRadio.install(radio)   // Call this before your first Central() or PeripheralHost().
```

In a unit test, you do not need the registry. Make the `Central` directly:
`Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)`.
For more information, read the "Mocking Bluetooth in-process" article in the
[BLESwiftVirtualRadio](Sources/BLESwiftVirtualRadio/BLESwiftVirtualRadio.docc/BLESwiftVirtualRadio.md)
documentation.

## Platform support

| Platform  | Minimum version |
|-----------|-----------------|
| iOS       | 16.0            |
| macOS     | 13.0            |
| watchOS   | 9.0             |
| tvOS      | 16.0            |
| visionOS  | 1.0             |
| iOS Simulator | 16.0, with `BLESwiftSimulatorLink` and `bleswift-provider` |

The central role is available on all of these platforms. The peripheral role
(`PeripheralHost`) is available only on iOS and macOS, because `CBPeripheralManager` does not
exist on the other platforms. In the iOS Simulator, both roles use `BLESwiftSimulatorLink` and
`bleswift-provider`. For more information, see [BLE in the iOS Simulator](#ble-in-the-ios-simulator).

BLESwift uses the iOS 18 standard library. Two internal modules supply the missing parts on
older systems:

- `BLESwiftCompat17` supplies a `Mutex` for iOS 17, macOS 14, watchOS 10, tvOS 17, and
  visionOS 1.
- `BLESwiftCompat16` supplies a serial-queue executor and `assumeIsolated` for iOS 16,
  macOS 13, watchOS 9, and tvOS 16.

These modules are not public API.

On each commit, CI runs all tests in these configurations:

- the newest iOS simulator, with each of the two executors
- an iOS 17 simulator
- macOS, with Thread Sanitizer

CI only builds for iOS 16, because current macOS cannot run an iOS 16 simulator.

Each public API takes a `DispatchQueue`, and that queue must be serial. On iOS 17 and later,
a concurrent queue causes a trap. The BLESwiftExplorer sample app requires iOS 18 or
macOS 15.

## Documentation

Each module has a DocC catalog. The Swift Package Index hosts the catalogs:

- [BLESwift](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswift):
  `Central`, connections, scanning, GATT, L2CAP, the peripheral role, and restoration
  ([in repo](Sources/BLESwift/BLESwift.docc/BLESwift.md))
- [BLESwiftCore](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftcore):
  the types that do not depend on a backend, the backend protocols, and the assigned numbers
  ([in repo](Sources/BLESwiftCore/BLESwiftCore.docc/BLESwiftCore.md))
- [BLESwiftProfiles](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftprofiles):
  typed decoders for standard Bluetooth SIG GATT characteristics
  ([in repo](Sources/BLESwiftProfiles/BLESwiftProfiles.docc/BLESwiftProfiles.md))
- [BLESwiftTestSupport](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswifttestsupport):
  the fakes and the test rig
  ([in repo](Sources/BLESwiftTestSupport/BLESwiftTestSupport.docc/BLESwiftTestSupport.md))
- [BLESwiftSimulatorLink](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftsimulatorlink):
  `SimulatorLink.install()` and the backends that run in the simulator
  ([in repo](Sources/BLESwiftSimulatorLink/BLESwiftSimulatorLink.docc/BLESwiftSimulatorLink.md))
- [BLESwiftVirtualRadio](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftvirtualradio):
  the in-process virtual radio, `VirtualRadio.install(_:)`, and virtual devices in code
  ([in repo](Sources/BLESwiftVirtualRadio/BLESwiftVirtualRadio.docc/BLESwiftVirtualRadio.md))
- [BLESwiftProvider](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftprovider):
  the provider that runs on the Mac and serves the virtual radio and the real radio
  ([in repo](Sources/BLESwiftProvider/BLESwiftProvider.docc/BLESwiftProvider.md))
- [BLESwiftLink](https://swiftpackageindex.com/kylebrowning/BLESwift/documentation/bleswiftlink):
  the wire protocol and the fixture format that the simulator and the provider use
  ([in repo](Sources/BLESwiftLink/BLESwiftLink.docc/BLESwiftLink.md))

To build the catalogs locally, run `swift package generate-documentation`.

Examples:

- [`Examples/BLESwiftExplorer`](Examples/BLESwiftExplorer): a SwiftUI sample app for iOS and
  macOS that uses all of the public API. It shows filtered scans, connections, GATT browsing,
  reads and writes, notifications, RSSI, connection logs, saved devices, system connection
  events, ANCS, and background restoration.
- [`Examples/HeartRateMonitor`](Examples/HeartRateMonitor): a complete app flow for the
  central role.
- [`Examples/ConsumerTests`](Examples/ConsumerTests): a separate package that tests BLE code
  with the fakes, from outside BLESwift.

## Features

- **Async/await API.** `Central` is an actor. Connect, read, and write are `async throws`.
  Scans and notifications are `AsyncSequence` streams.
- **Actor isolation on the CoreBluetooth queue.** `Central` runs on the same serial
  `DispatchQueue` that its `CBCentralManager` uses for delegate callbacks. Each event arrives
  on the executor of the actor. There is no thread hop, so events cannot arrive out of order.
- **Scans.** `scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)` gives
  `.discovered`, `.updated`, and `.lost` events. You can filter by signal strength. A loss
  timeout reports peripherals that stop advertising. A scan timeout ends the stream.
- **Known peripherals.** `knownPeripherals(withIdentifiers:)` and
  `systemConnectedPeripherals(withServices:)` find peripherals without a new scan.
- **Many connections.** You can connect to many peripherals at the same time. Each connection
  has its own lifecycle, `ReconnectPolicy`, and GATT and notification state.
- **Reconnection policy.** `ReconnectPolicy` can be `.never`, `.always(maxAttempts:backoff:)`,
  or a custom backoff. You do not write retry logic.
- **Timeouts.** Connect, read, write, descriptor operations, RSSI reads, and L2CAP opens
  accept an optional `Duration`. When the time ends, the call throws an error.
- **Bluetooth SIG profiles.** The `BLESwiftProfiles` product decodes standard
  characteristics into typed values: Heart Rate Measurement, Battery Level, Device
  Information, Current Time, Body Sensor Location, CSC Measurement, Cycling Power
  Measurement, and Temperature Measurement. It also adds
  `Peripheral.readDeviceInformation()` and `readBatteryLevel()`.
- **GATT discovery.** `discoverServices()`, `discoverCharacteristics(for:)`,
  `discoverDescriptors(for:)`, and `properties(of:)` show the attributes of an unknown
  peripheral.
- **Descriptors.** You can discover descriptors, and read and write them with
  `readDescriptor(_:timeout:)` and `writeDescriptor(_:value:timeout:)`.
- **Flow control for writes without response.** A `.withoutResponse` write waits until
  CoreBluetooth can send it, so no packets are lost. `maximumWriteValueLength(for:)` gives
  the maximum payload for each write type.
- **RSSI and service changes.** `readRSSI(timeout:)` reads the signal strength.
  `serviceChanges()` gives a stream of the services that the peripheral changes.
- **Multicast streams.** Bluetooth state, connection events, notifications, and restoration
  events each support many subscribers at the same time.
- **L2CAP channels.** `openL2CAPChannel(psm:timeout:)` opens a channel. You receive data as an
  `AsyncThrowingStream` and send data with `write(_:)`.
- **Peripheral role.** `PeripheralHost` publishes a GATT database and advertises it. It gives
  streams of read requests, write requests, and subscriber changes. It answers a failed
  request with an `ATTError`. This role is available only on iOS and macOS.
- **Background restoration for both roles.** iOS state restoration gives one stream for the
  central role and one stream for the peripheral role. Each stream keeps its events until the
  first subscriber reads them. Read the DocC article for the rules at app launch.
- **Typed values.** `Transmittable` and `Receivable` give typed reads and writes. Fixed-width
  integers, `String`, `Data`, and `DataPadding` conform. `combine(_:)` joins values into one
  payload.
- **Combined operations.** `writeAndAwaitNotification`, `writeAndAssemble`, and `flush` do a
  request and response, or a multi-packet read, in one call.
- **Bluetooth SIG assigned numbers.** `GATTAssignedNumbers` and the `.name` property of the
  identifier types give a readable name for each standard UUID.
- **Use an existing manager.** `Central(adopting:connectedPeripherals:callbackQueue:)` uses a
  `CBCentralManager` that you already have. You can move to BLESwift one part at a time.
- **Tests without hardware.** `BLESwiftTestSupport` contains `FakeCentral`, `FakePeripheral`,
  `FakeL2CAPChannel`, and `FakePeripheralManager`. A real `Central` uses them through the
  public backend protocols.
- **All CoreBluetooth platforms.** BLESwift supports iOS 16, macOS 13, watchOS 9, tvOS 16,
  visionOS 1, and later. For more information, see [Platform support](#platform-support).
- **One runtime dependency.** BLESwift depends only on
  [swift-log](https://github.com/apple/swift-log). To see the internal logs of BLESwift,
  install a custom `LogHandler`.

### Comparison with CoreBluetooth

| Capability | CoreBluetooth | BLESwift |
|---|---|---|
| Scans | `didDiscover` callbacks. You remove duplicates, filter by RSSI, and add a timeout. | `scan(...)` gives `.discovered`, `.updated`, and `.lost`, with `rssiThreshold`, `allowDuplicates`, `lossTimeout`, and `timeout`. |
| Connect and disconnect | `connect` returns nothing. The result comes later on a delegate. | `try await central.connect(id)` returns a `Peripheral` or throws an error. |
| Reconnection | Delegate callbacks and your own retry logic. | One `ReconnectPolicy` for each connection: `.never`, `.always(maxAttempts:backoff:)`, or `.custom`. |
| Reads and writes | Untyped `Data` for a `CBCharacteristic` that you must discover first. | `try await peripheral.read(from:)` and `write(_:to:type:)`, typed with `Receivable` and `Transmittable`, by identifier. |
| Timeouts | None. An operation that stops never completes. | An optional `Duration` on connect, read, write, descriptor operations, RSSI, and L2CAP open. |
| Writes without response | You check `canSendWriteWithoutResponse`, or wait for a delegate callback. | Each write waits until CoreBluetooth is ready. `maximumWriteValueLength(for:)` gives the size. |
| Notifications | One delegate callback for all characteristics of the peripheral. | One typed multicast `AsyncThrowingStream` for each characteristic, with a `BufferingPolicy`. |
| Descriptors | You discover them, then find each `CBDescriptor` object yourself. | `DescriptorIdentifier`, `discoverDescriptors(for:)`, `readDescriptor`, and `writeDescriptor`. |
| RSSI | `readRSSI()`, then `didReadRSSI` on the delegate. | `try await peripheral.readRSSI(timeout:)` |
| Service changes | `didModifyServices`. You discover the services again. | `serviceChanges()`, a stream of the changed services. |
| L2CAP | You open the channel, then connect `NSStream` delegates to your own buffers. | `openL2CAPChannel(psm:)` gives `incomingData` as a stream, and `write(_:)`. |
| Peripheral role | `CBPeripheralManager` and a second delegate protocol. | The `PeripheralHost` actor: `add(_:)`, `startAdvertising(_:)`, and streams of requests and subscribers. iOS and macOS only. |
| Background restoration | A `willRestoreState` dictionary that you must decode at launch. | A typed `RestoredState` on a stream that keeps its events for the first subscriber, for both roles. |
| Many peripherals | One delegate gets the events of all peripherals. | One `Peripheral` value for each connection, with its own GATT and notification state. |
| Tests without hardware | You cannot make or control a `CBCentralManager`. | `FakeCentral`, `FakePeripheral`, and `FakePeripheralManager` control a real `Central`. |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). For the release history, see [CHANGELOG.md](CHANGELOG.md).

## License

BLESwift uses the Apache License 2.0. See [LICENSE](LICENSE) for the full text.
