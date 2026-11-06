# ``BLESwift``

Bluetooth Low Energy for Swift 6.2, built on async/await.

## Overview

BLESwift wraps CoreBluetooth in a single actor, ``Central``. The actor's isolation is the serial
`DispatchQueue` on which its `CBCentralManager` delivers delegate callbacks. BLESwift has no
closure or callback layer. Connecting, reading, writing, and scanning are `async throws` calls
or `AsyncSequence` streams. Each multi-consumer feed is a multicast stream. The feeds are
Bluetooth state, connection events, and notifications. Each subscriber sees every value.

BLESwift supports every platform that has CoreBluetooth: iOS 16, macOS 13, watchOS 9, tvOS 16,
and visionOS 1 and later. Two internal modules back-deploy the features that older systems do
not have. See <doc:BackDeployment>. The central role is available on all platforms. The
peripheral role (``PeripheralHost``) is available on iOS and macOS only. See <doc:PeripheralRole>.

### Modules

BLESwift ships as several products. `import BLESwift` also re-exports `BLESwiftCore`. Most apps
need no other import.

- **`BLESwiftCore`** has the backend-agnostic types and the backend seam under `Central`. It has
  no CoreBluetooth dependency.
- **`BLESwift`** (this module) has `Central`, `PeripheralHost`, and the CoreBluetooth backend.
- **`BLESwiftTestSupport`** has scriptable fakes for tests without hardware. These are
  `FakeCentral` and `FakePeripheral` for the central role, and `FakePeripheralManager` for the
  peripheral role. See the "Testing" section of <doc:GettingStarted>.
- **`BLESwiftProfiles`** has typed decoders for standard Bluetooth SIG characteristics.

Four more modules give `Central` and `PeripheralHost` a working radio where CoreBluetooth does
not work. See <doc:SimulatorSupport>.

- **`BLESwiftVirtualRadio`** is an in-process radio that serves virtual devices to a `Central`
  or `PeripheralHost`. It works on every platform.
- **`BLESwiftSimulatorLink`** has the backends that forward calls to a provider on the host Mac.
  Its `SimulatorLink.install()` routes every `Central()` and `PeripheralHost()` through them.
- **`BLESwiftProvider`** is the host-side half. A `Provider` serves link clients from the Mac's
  real radio, from a virtual radio, or from both. The `bleswift-provider` executable runs it.
- **`BLESwiftLink`** has the wire protocol and the fixture format that the two halves share.
  You rarely import it.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:SimulatorSupport>
- <doc:BackDeployment>
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

BLESwift supports any number of concurrent peripheral connections. See
<doc:ConnectionsAndReconnection>.

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

Connection-event registration is available on every platform except macOS. The ANCS members
are available on iOS only. These are `requiresANCS:` on `connect`, `Peripheral/ancsAuthorized`,
and `Peripheral/ancsAuthorizationEvents()`.

- <doc:SystemEvents>
- ``SystemConnectionEvent``
- ``Central/connectionEventRegistration(services:peripherals:)``

### Reading, Writing, and Notifications

- <doc:ReadingWritingNotifications>
- ``WriteType``
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
- ``RestoredState``
- ``RestoredPeripheralState``

### Peripheral Role (GATT server)

Host a GATT database and advertise it. See <doc:PeripheralRole>. To drive both roles in one
process over fakes, see <doc:CrossRoleExample>.

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
