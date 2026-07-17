# BLESwift

**BLESwift** ("BLE Interface") is an async/await-first Bluetooth Low Energy library for Swift 6.2.
It wraps CoreBluetooth in a single actor whose isolation is tied directly to the dispatch queue
CoreBluetooth delivers its callbacks on — no closures, no callback compatibility layer, and no
delegate protocols to implement. Connecting, reading, writing, and scanning are `async throws`
or `AsyncSequence`-based, and every multi-consumer feed (Bluetooth state, connection lifecycle,
notifications) is a real multicast stream that every subscriber observes independently.

## Features

- **Pure async/await API.** `actor Central`, `async throws` connect/read/write, and
  `AsyncSequence` for scanning and notifications — nothing to bridge from a callback yourself.
- **Actor-isolated core.** `Central`'s isolation is tied directly to the `DispatchSerialQueue`
  its `CBCentralManager` delivers delegate callbacks on, so every CoreBluetooth event is handled
  on the actor's own executor with no thread hop and no ordering hazards.
- **Multicast everything.** Bluetooth state, connection lifecycle, and characteristic
  notifications all support any number of independent concurrent subscribers.
- **Declarative reconnection.** `ReconnectPolicy` (`.never`, `.always(maxAttempts:backoff:)`,
  or fully custom backoff logic) replaces manual retry bookkeeping.
- **Background restoration.** iOS state restoration surfaces as a single buffered,
  replay-on-subscribe event stream — see the DocC article for the launch-time discipline it
  requires.
- **Every CoreBluetooth platform.** iOS, macOS, watchOS, tvOS, and visionOS, at each platform's
  floor for Swift 6.2's custom-executor isolation checking.
- **One runtime dependency.** [swift-log](https://github.com/apple/swift-log) — install a
  custom `LogHandler` to observe BLESwift's internal logging; nothing else.

## Quick start

```swift
import BLESwift

let central = Central()

// Wait for the radio to power on.
for await state in await central.stateEvents() {
    if state == .poweredOn { break }
}

// Scan for a peripheral advertising the Heart Rate service, then stop.
let heartRateService = ServiceIdentifier(uuid: "180D")
var target: PeripheralIdentifier?
for try await event in await central.scan(services: [heartRateService]) {
    if case .discovered(let discovery) = event {
        target = discovery.peripheral
        break
    }
}

guard let identifier = target else { return }

// Connect, with automatic reconnection on unexpected disconnects.
let peripheral = try await central.connect(identifier, reconnect: .always())

// Subscribe to heart-rate notifications.
let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)
let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: heartRateMeasurement)

for try await reading in readings {
    print("\(reading.beatsPerMinute) bpm")
}
```

See [`Examples/HeartRateMonitor`](Examples/HeartRateMonitor/HeartRateMonitor.swift) for the full
worked example (including the `HeartRateMeasurement` decoding), and the
[DocC catalog](Sources/BLESwift/BLESwift.docc/BLESwift.md) for a full walkthrough: Getting Started, Scanning,
Connections & Reconnection, Reading/Writing & Notifications, and Background Restoration.

## Platform support

| Platform  | Minimum version |
|-----------|-----------------|
| iOS       | 18.0            |
| macOS     | 15.0            |
| watchOS   | 11.0            |
| tvOS      | 18.0            |
| visionOS  | 2.0             |

## Installation

Add BLESwift to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/kylebrowning/BLESwift.git", from: "1.0.0")
]
```

Then add `"BLESwift"` to your target's dependencies.
