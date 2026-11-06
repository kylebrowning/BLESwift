# Reading Standard Profiles

Decode notifications and reads with the typed profile decoders.

## Streaming a measurement

Each profile type has the SIG-assigned ``BLESwiftCore/CharacteristicIdentifier`` that it decodes. To subscribe, pass that identifier to `notifications(for:)`. You do not write UUIDs or parse bytes.

```swift
import BLESwiftProfiles

let stream: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: HeartRateMeasurement.characteristic)

for try await reading in stream {
    print("\(reading.beatsPerMinute) bpm, contact: \(reading.sensorContact)")
}
```

## Reading device information

The Device Information service has several optional String characteristics. ``BLESwift/Peripheral/readDeviceInformation(timeout:)`` discovers the service and reads the characteristics that the peripheral has. It sets the other values to `nil`. It does not throw when some strings are absent.

```swift
let info = try await peripheral.readDeviceInformation()
print(info.manufacturerName ?? "unknown manufacturer")
print(info.firmwareRevision ?? "unknown firmware")
```

## Cycling power layout

``CyclingPowerMeasurement`` decodes the Cycling Power Measurement characteristic. The value is little-endian. It has a 2-byte `Flags` field and a 2-byte signed `instantaneousPower` (watts). The optional fields that the flags select follow, in this order:

- Bit 0: Pedal Power Balance present (`UInt8`, units of 1/2 %).
- Bit 1: Pedal Power Balance Reference. 0 is unknown and 1 is left.
- Bit 2: Accumulated Torque present (`UInt16`, units of 1/32 N·m).
- Bit 3: Accumulated Torque Source. 0 is wheel-based and 1 is crank-based.
- Bit 4: Wheel Revolution Data. Cumulative (`UInt32`) and last event time (`UInt16`, units of 1/2048 s).
- Bit 5: Crank Revolution Data. Cumulative (`UInt16`) and last event time (`UInt16`, units of 1/1024 s).
- Bit 6: Extreme Force Magnitudes. Maximum (`Int16`) and minimum (`Int16`), in newtons.
- Bit 7: Extreme Torque Magnitudes. Maximum (`Int16`) and minimum (`Int16`), units of 1/32 N·m.
- Bit 8: Extreme Angles. Three bytes that hold two 12-bit values. `maxAngle = raw24 & 0xFFF` and `minAngle = raw24 >> 12`, in degrees.
- Bit 9: Top Dead Spot Angle (`UInt16`, degrees).
- Bit 10: Bottom Dead Spot Angle (`UInt16`, degrees).
- Bit 11: Accumulated Energy (`UInt16`, kilojoules).
- Bit 12: Offset Compensation Indicator. This flag has no payload.

## Reading a single value

To read one value, call ``BLESwift/Peripheral/read(from:timeout:)`` with the profile type. For some values, a purpose-built convenience is also available.

```swift
let battery = try await peripheral.readBatteryLevel()   // UInt8, 0–100
let location: BodySensorLocation = try await peripheral.read(from: BodySensorLocation.characteristic)
```
