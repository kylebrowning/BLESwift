# ``BLESwiftTestSupport``

Scriptable fakes for unit-testing your own BLE code without hardware.

## Overview

You cannot create or script a `CBCentralManager` or `CBPeripheral` in a test. You cannot drive its delegate callbacks or set its GATT table. BLESwiftTestSupport has scriptable replacements:

- ``FakeCentral`` and ``FakePeripheral`` conform to the backend seam of BLESwiftCore (`CentralManaging` and `PeripheralRemote`).
- ``FakeStartupBackgroundTask`` scripts the iOS background-task seam that protects state restoration.
- ``ManualClock`` is a clock that moves only when the test moves it.

Wire the fakes into a real `Central` with `Central.init(backend:queue:configuration:startupBackgroundTask:connectedPeripherals:)`. Then your tests run the real BLE code of your app, with no hardware and no mocking library. This includes scan handling, connection logic, GATT reads and writes, and notification subscriptions. See <doc:TestingYourBLECode>.

To test timeouts, give the same ``ManualClock`` to `Configuration(clock:)`. To control the delays of a virtual device, also give it to `VirtualRadio(clock:)`. Then the test advances time and does not wait for it.

BLESwiftTestSupport depends only on BLESwiftCore. It does not depend on `BLESwift` or CoreBluetooth.

## Topics

### Getting Started

- <doc:TestingYourBLECode>

### Fakes

- ``FakeCentral``
- ``FakePeripheral``
- ``FakePeripheralManager``
- ``FakeL2CAPChannel``
- ``FakeGATTBridge``
- ``FakeStartupBackgroundTask``

### Clocks

- ``ManualClock``
