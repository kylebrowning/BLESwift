# ``BLESwiftSimulatorLink``

Run BLESwift against real or virtual Bluetooth hardware from the iOS Simulator.

## Overview

CoreBluetooth is non-functional in the iOS Simulator. This module provides backend
conformances that forward `Central` and `PeripheralHost` traffic to a `bleswift-provider`
process on the host Mac, and a one-line `SimulatorLink.install()` that routes every
`Central()` / `PeripheralHost()` in your app through them.

## Topics

### Installing the link

- ``SimulatorLink``

### Backends

- ``LinkCentral``
- ``LinkPeripheral``
- ``LinkPeripheralManager``
- ``LinkClientSession``
