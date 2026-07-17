# ``BLESwift``

Async/await-first Bluetooth Low Energy for Swift 6.2.

## Overview

BLESwift ("BLE Interface") wraps CoreBluetooth in a single actor, ``Central``, whose isolation is
tied directly to the `DispatchSerialQueue` its underlying `CBCentralManager` delivers delegate
callbacks on. There is no closure or callback compatibility layer: connecting, reading, writing,
and scanning are all `async throws` or `AsyncSequence`-based, and every multi-consumer feed
(Bluetooth state, connection lifecycle, notifications) is a proper multicast stream that every
subscriber sees independently.

BLESwift targets every platform CoreBluetooth ships on — iOS, macOS, watchOS, tvOS, and visionOS —
at each platform's floor needed for Swift 6.2's custom-executor isolation checking (SE-0424):
iOS 18, macOS 15, watchOS 11, tvOS 18, visionOS 2.

BLESwift is built around Swift's structured concurrency from the ground up — see the articles
below for the resulting flows.

### Modules

BLESwift ships as three products. `import BLESwift` is all most apps need — it re-exports
everything below, so every type on this page is available without a separate import:

- **`BLESwiftCore`** — the backend-agnostic types and implementation seam underneath
  `Central`, with no CoreBluetooth dependency. Most apps never import it directly.
- **`BLESwift`** (this module) — `Central`, the CoreBluetooth-backed production
  implementation of the backend seam, and every type re-exported from `BLESwiftCore`.
- **`BLESwiftTestSupport`** — scriptable `FakeCentral`/`FakePeripheral` fakes for
  unit-testing your own BLE code without hardware. See <doc:GettingStarted>'s "Testing"
  section.

## Topics

### Essentials

- <doc:GettingStarted>
- ``Central``
- ``Configuration``
- ``WarningOptions``

### Bluetooth & Connection State

- ``CentralState``
- ``BluetoothAuthorization``
- ``ConnectionState``

### Scanning

- <doc:Scanning>
- ``ScanEvent``
- ``Discovery``
- ``AdvertisementData``

### Connecting

- <doc:ConnectionsAndReconnection>
- ``Peripheral``
- ``Central/knownPeripherals(withIdentifiers:)``
- ``Central/systemConnectedPeripherals(withServices:)``
- ``ConnectionEvent``
- ``ReconnectPolicy``

### Reading, Writing, and Notifications

- <doc:ReadingWritingNotifications>
- ``BufferingPolicy``

### Background Restoration

- <doc:BackgroundRestoration>

### Identifiers

- ``PeripheralIdentifier``
- ``ServiceIdentifier``
- ``CharacteristicIdentifier``

### Serialization

- ``Receivable``
- ``Transmittable``
- ``DataPadding``
- ``combine(_:)``

### Errors

- ``BLESwiftError``
