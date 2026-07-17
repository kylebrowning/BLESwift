# ``BLESwiftTestSupport``

Scriptable fakes for unit-testing your own BLE code without hardware.

## Overview

`CBCentralManager` and `CBPeripheral` can't be instantiated or scripted in tests — there's no
way to construct one, drive its delegate callbacks, or make it report a particular GATT
table. BLESwiftTestSupport ships ``FakeCentral`` and ``FakePeripheral``, scriptable stand-ins
that conform to BLESwiftCore's backend seam (`CentralManaging`/`PeripheralRemote`) the
same way a real `CBCentralManager`/`CBPeripheral` does, plus ``FakeStartupBackgroundTask`` for
scripting the iOS background-task seam that protects state restoration.

Wired into a real `Central` (from the `BLESwift` module) via its public
`Central.init(backend:queue:configuration:startupBackgroundTask:connectedPeripheral:)`, these
fakes let you exercise your app's actual BLE code — scan handling, connection logic, GATT
reads/writes, notification subscriptions — end to end, deterministically, with no hardware and
no third-party mocking library. See <doc:TestingYourBLECode> for the full pattern.

BLESwiftTestSupport depends on BLESwiftCore only — not on `BLESwift` or CoreBluetooth — so it
carries no CoreBluetooth-backed code into your test target at all.

## Topics

### Getting Started

- <doc:TestingYourBLECode>

### Fakes

- ``FakeCentral``
- ``FakePeripheral``
- ``FakeStartupBackgroundTask``
