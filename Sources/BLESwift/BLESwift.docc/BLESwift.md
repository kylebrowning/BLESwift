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
iOS 18, macOS 15, watchOS 11, tvOS 18, visionOS 2. The central role is available everywhere;
the peripheral role (``PeripheralHost``) is iOS/macOS-only because CoreBluetooth does not
support it on the other platforms — see <doc:PeripheralRole>.

BLESwift is built around Swift's structured concurrency from the ground up — see the articles
below for the resulting flows.

### Modules

BLESwift ships as several products. `import BLESwift` is all most apps need — it re-exports
everything below, so every type on this page is available without a separate import:

- **`BLESwiftCore`** — the backend-agnostic types and implementation seam underneath
  `Central`, with no CoreBluetooth dependency. Most apps never import it directly.
- **`BLESwift`** (this module) — `Central`, the CoreBluetooth-backed production
  implementation of the backend seam, and every type re-exported from `BLESwiftCore`.
- **`BLESwiftTestSupport`** — scriptable `FakeCentral`/`FakePeripheral` (central-role) and
  `FakePeripheralManager` (peripheral-role) fakes for unit-testing your own BLE code without
  hardware. See <doc:GettingStarted>'s "Testing" section.

Three further modules make `Central` and `PeripheralHost` work in the iOS Simulator, where
CoreBluetooth is non-functional — see <doc:SimulatorSupport>:

- **`BLESwiftSimulatorLink`** — the simulator-side half: backends that forward the seam to a
  host-side provider, and the `SimulatorLink.install()` that routes every `Central()` /
  `PeripheralHost()` through them.
- **`BLESwiftProvider`** — the host-side half: a `Provider` that serves link clients from the
  Mac's real radio, from an in-process virtual radio, or both. Behind the `bleswift-provider`
  executable, and importable directly to host virtual devices written in Swift.
- **`BLESwiftLink`** — the framed, `Codable` wire protocol and the fixture format the two
  halves share. Rarely imported directly.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:SimulatorSupport>
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
- ``ScanFilter``
- ``Discovery``
- ``AdvertisementData``
- ``Central/findFirst(matching:timeout:)``
- ``Central/connect(identifier:fallbackScan:reconnect:timeout:compatibility:)``

### Connecting

BLESwift supports any number of concurrent peripheral connections — see
<doc:ConnectionsAndReconnection> for the full multi-peripheral model.

- <doc:ConnectionsAndReconnection>
- ``Peripheral``
- ``Central/connectedPeripherals``
- ``Central/knownPeripherals(withIdentifiers:)``
- ``Central/systemConnectedPeripherals(withServices:)``
- ``ConnectionEvent``
- ``ReconnectPolicy``
- ``GATTCompatibility``
- ``GATTCompatibility/DiscoveryMode``

### System Connection Events & ANCS

Platform-fenced exactly as CoreBluetooth is: connection-event registration exists
everywhere but macOS; the ANCS members (`requiresANCS:` on `connect`,
`Peripheral/ancsAuthorized`, `Peripheral/ancsAuthorizationEvents()`) are iOS-only.

- <doc:SystemEvents>
- ``SystemConnectionEvent``
- ``Central/connectionEventRegistration(services:peripherals:)``

### Reading, Writing, and Notifications

- <doc:ReadingWritingNotifications>
- ``BufferingPolicy``
- ``WriteProgress``

### L2CAP Channels

- <doc:L2CAPChannels>
- ``L2CAPChannel``
- ``L2CAPPSM``

### Background Restoration

- <doc:BackgroundRestoration>
- ``RestorationConfiguration``
- ``RestorationEvent``
- ``PeripheralRestorationConfiguration``
- ``PeripheralRestorationEvent``

### Peripheral Role (GATT server)

Host a GATT database and advertise it — the peripheral half of CoreBluetooth. See
<doc:PeripheralRole>, and <doc:CrossRoleExample> to drive both roles at once over fakes.

- <doc:PeripheralRole>
- <doc:CrossRoleExample>
- ``PeripheralHost``
- ``GATTService``
- ``GATTCharacteristic``
- ``CharacteristicProperties``
- ``AttributePermissions``
- ``PeripheralAdvertisement``
- ``ReadRequest``
- ``WriteRequest``
- ``RequestToken``
- ``ATTError``
- ``Subscriber``
- ``SubscriptionEvent``
- ``PeripheralHostEvent``

### Identifiers

- ``PeripheralIdentifier``
- ``ServiceIdentifier``
- ``CharacteristicIdentifier``
- ``DescriptorIdentifier``

### Serialization

- ``Receivable``
- ``Transmittable``
- ``DataPadding``
- ``combine(_:)``

### Errors

- ``BLESwiftError``
