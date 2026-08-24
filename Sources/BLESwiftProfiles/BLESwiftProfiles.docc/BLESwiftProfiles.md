# ``BLESwiftProfiles``

Typed decoders for standard Bluetooth SIG GATT characteristics.

## Overview

BLESwiftProfiles turns the raw bytes of well-known GATT characteristics into strongly typed
Swift values. Each type is a ``BLESwiftCore/Receivable`` (and, where the characteristic is
writable, a ``BLESwiftCore/Transmittable``) whose byte layout follows the Bluetooth SIG GATT
Specification Supplement (GSS) exactly — little-endian throughout, with flag-driven optional
fields decoded in their specified order.

Every type carries the SIG-assigned identifiers it decodes, so call sites read naturally:

```swift
import BLESwiftProfiles

let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: HeartRateMeasurement.characteristic)

for try await reading in readings {
    print("\(reading.beatsPerMinute) bpm")
}
```

The module is a separate product — consumers who do not need it do not pay for it — that
depends on `BLESwift`, so it can also offer `Peripheral` conveniences like
``BLESwift/Peripheral/readDeviceInformation(timeout:)`` and
``BLESwift/Peripheral/readBatteryLevel(timeout:)``.

The floating-point value in ``TemperatureMeasurement`` uses the IEEE 11073-20601 32-bit
FLOAT-Type: a signed 24-bit mantissa (bytes 0-2, little-endian) and a signed 8-bit base-10
exponent (byte 3), representing `mantissa × 10^exponent`.

## Topics

### Streaming Measurements

- ``HeartRateMeasurement``
- ``CSCMeasurement``
- ``CyclingPowerMeasurement``
- ``TemperatureMeasurement``

### Device State

- ``BatteryLevel``
- ``BodySensorLocation``
- ``DeviceInformation``
- ``CurrentTime``

### Shared Building Blocks

- ``GATTDateTime``

### Reading Profiles

- <doc:UsingProfiles>
