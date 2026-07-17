# ``BLESwiftCore``

The backend-agnostic types and implementation seam underneath BLESwift.

## Overview

BLESwiftCore has no dependency on CoreBluetooth — it contains every type BLESwift's public
API speaks in (``CentralState``, ``PeripheralConnectionState``, ``ServiceIdentifier``,
``AdvertisementData``, ``BLESwiftError``, and the rest), plus the protocol seam
(``CentralManaging``, ``PeripheralRemote``) that lets `BLESwift`'s `Central` actor be
written against an abstraction instead of `CBCentralManager`/`CBPeripheral` directly.

**Most apps only need `import BLESwift`.** `BLESwift` re-exports everything in
BLESwiftCore, so ordinary consumer code never needs to import this module directly — see the
`BLESwift` module's own landing page and its "Getting Started" article. BLESwiftCore exists
as its own product for one reason: it's the one thing both real conformances of the backend
seam — CoreBluetooth (the `BLESwift` module) and the scriptable fakes (`BLESwiftTestSupport`)
— can depend on without depending on each other, or on CoreBluetooth itself.

### The backend seam

``CentralManaging`` and ``PeripheralRemote`` are protocol mirrors of `CBCentralManager` and
`CBPeripheral`, speaking exclusively in BLESwiftCore's own types (never a CoreBluetooth type,
never a raw `[String: Any]` options dictionary). `Central` is written entirely against these
protocols; the `BLESwift` module supplies the real CoreBluetooth conformances, and
`BLESwiftTestSupport` supplies scriptable fakes standing in for hardware.

This seam is documented and public so a fake backend can be constructed and wired up from
outside the package — the exact mechanism `BLESwiftTestSupport` uses — but it isn't a
general-purpose plugin API: conforming your own backend type is possible but unsupported. See
``CentralManaging``'s doc comment for the full caveat.

## Topics

### Backend Seam

- ``CentralManaging``
- ``PeripheralRemote``
- ``CentralEvent``
- ``PeripheralEvent``
- ``StartupBackgroundTaskRunning``
- ``WriteType``
- ``PeripheralConnectionState``
- ``ScanOptions``

### Bluetooth & Connection State

- ``CentralState``
- ``BluetoothAuthorization``

### Identifiers

- ``PeripheralIdentifier``
- ``ServiceIdentifier``
- ``CharacteristicIdentifier``

### Advertisement & Discovery

- ``AdvertisementData``
- ``Discovery``

### Configuration

- ``WarningOptions``

### Background Restoration

- ``RestoredState``
- ``RestoredPeripheral``
- ``RestoredScanOptions``

### Serialization

- ``Receivable``
- ``Transmittable``
- ``DataPadding``
- ``combine(_:)``

### Errors

- ``BLESwiftError``
