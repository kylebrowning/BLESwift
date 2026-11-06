# ``BLESwiftCore``

The backend-agnostic types and implementation seam underneath BLESwift.

## Overview

BLESwiftCore does not depend on CoreBluetooth. It has the types that the public API of BLESwift uses, for example ``CentralState``, ``PeripheralConnectionState``, ``ServiceIdentifier``, ``AdvertisementData``, and ``BLESwiftError``. It also has the protocol seam (``CentralManaging`` and ``PeripheralRemote``). The `Central` actor of `BLESwift` uses this seam and not `CBCentralManager` or `CBPeripheral`.

Most apps only need `import BLESwift`. `BLESwift` re-exports everything in BLESwiftCore. See the "Getting Started" article of the `BLESwift` module.

BLESwiftCore is a separate product for one reason. The two real conformances of the seam (CoreBluetooth in `BLESwift` and the fakes in `BLESwiftTestSupport`) both depend on it. Thus neither depends on the other or on CoreBluetooth.

### The backend seam

``CentralManaging`` and ``PeripheralRemote`` mirror `CBCentralManager` and `CBPeripheral`. They use only BLESwiftCore types. They never use a CoreBluetooth type or a raw `[String: Any]` options dictionary. `BLESwift` supplies the CoreBluetooth conformances. `BLESwiftTestSupport` supplies the fakes.

The seam is public so that code outside the package can wire up a fake backend, as `BLESwiftTestSupport` does. It is not a plugin API. You can conform your own backend type, but this is not supported. See the doc comment of ``CentralManaging``.

### Replacing the default backend

``BackendRegistry`` holds two process-wide factories. The default initializers `Central()` and `PeripheralHost()` use them to build a backend. If a factory is `nil`, they use CoreBluetooth. `SimulatorLink.install` and `VirtualRadio.install(_:)` set the factories. The initializers that take a `backend:` argument ignore the registry.

To replace both factories in one step, call ``BackendRegistry/setFactories(central:peripheralManager:)``. Do not set the two properties one at a time.

### Naming a GATT graph

``GATTAssignedNumbers`` converts UUIDs to the names that the Bluetooth SIG assigns to standard attributes. Use it for logging, debugging, and UI. After you list the services, characteristics, and descriptors of a peripheral, you can name every node. The 16-bit form and the expanded 128-bit Base-UUID form give the same name. An unknown or vendor-private UUID returns `nil`.

```swift
func describe(_ service: ServiceIdentifier, characteristics: [CharacteristicIdentifier]) {
    // `.name` is a convenience for GATTAssignedNumbers.name(for:).
    let serviceName = service.name ?? service.uuidString      // "Heart Rate"
    print("Service: \(serviceName)")
    for characteristic in characteristics {
        let name = characteristic.name ?? characteristic.uuidString
        print("  • \(name)")                                  // "  • Heart Rate Measurement"
    }
}
```

## Topics

### Backend Seam

- ``CentralManaging``
- ``PeripheralRemote``
- ``PeripheralManaging``
- ``L2CAPChannelRemote``
- ``CentralEvent``
- ``PeripheralEvent``
- ``PeripheralHostEvent``
- ``StartupBackgroundTaskRunning``
- ``WriteType``
- ``PeripheralConnectionState``
- ``ScanOptions``
- ``L2CAPPSM``

### Replacing the Default Backend

- ``BackendRegistry``
- ``BackendRegistry/setFactories(central:peripheralManager:)``

### Bluetooth & Connection State

- ``CentralState``
- ``BluetoothAuthorization``
- ``SystemConnectionEvent``
- ``GATTCompatibility``

### Identifiers

- ``PeripheralIdentifier``
- ``ServiceIdentifier``
- ``CharacteristicIdentifier``
- ``DescriptorIdentifier``

### Assigned Numbers

- ``GATTAssignedNumbers``

### Advertisement & Discovery

- ``AdvertisementData``
- ``PeripheralAdvertisement``
- ``Discovery``
- ``ScanFilter``

### Hosting a GATT Database

- ``GATTService``
- ``GATTCharacteristic``
- ``CharacteristicProperties``
- ``AttributePermissions``
- ``ReadRequest``
- ``WriteRequest``
- ``RequestToken``
- ``Subscriber``
- ``SubscriptionEvent``
- ``ATTError``

### Configuration

- ``WarningOptions``

### Background Restoration

- ``RestoredState``
- ``RestoredPeripheral``
- ``RestoredPeripheralState``
- ``RestoredScanOptions``

### Serialization

- ``Receivable``
- ``Transmittable``
- ``DataPadding``
- ``combine(_:)``

### Errors

- ``BLESwiftError``
