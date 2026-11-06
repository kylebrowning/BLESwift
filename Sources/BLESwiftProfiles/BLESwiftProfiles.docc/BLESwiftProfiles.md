# ``BLESwiftProfiles``

Typed decoders for standard Bluetooth SIG GATT characteristics.

## Overview

BLESwiftProfiles decodes the raw bytes of well-known GATT characteristics into typed Swift values. Each type is a ``BLESwiftCore/Receivable``. If the characteristic is writable, the type is also a ``BLESwiftCore/Transmittable``. The byte layout follows the Bluetooth SIG GATT Specification Supplement (GSS). All values are little-endian. Flags select the optional fields, and the decoder reads them in the specified order.

Every type has the SIG-assigned identifiers that it decodes:

```swift
import BLESwiftProfiles

let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: HeartRateMeasurement.characteristic)

for try await reading in readings {
    print("\(reading.beatsPerMinute) bpm")
}
```

This module is a separate product and depends on `BLESwift`. It adds `Peripheral` conveniences such as ``BLESwift/Peripheral/readDeviceInformation(timeout:)`` and ``BLESwift/Peripheral/readBatteryLevel(timeout:)``.

``TemperatureMeasurement`` uses the IEEE 11073-20601 32-bit FLOAT-Type. It has a signed 24-bit mantissa (bytes 0-2, little-endian) and a signed 8-bit base-10 exponent (byte 3). The value is `mantissa × 10^exponent`.

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
