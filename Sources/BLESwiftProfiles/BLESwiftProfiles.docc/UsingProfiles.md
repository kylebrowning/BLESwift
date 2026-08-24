# Reading Standard Profiles

Decode notifications and reads with the typed profile decoders.

## Streaming a measurement

Each profile type exposes the SIG-assigned ``BLESwiftCore/CharacteristicIdentifier`` it
decodes, so subscribing is a one-liner — no hand-written UUIDs, no manual byte parsing:

```swift
import BLESwiftProfiles

let stream: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: HeartRateMeasurement.characteristic)

for try await reading in stream {
    print("\(reading.beatsPerMinute) bpm, contact: \(reading.sensorContact)")
}
```

## Reading device information

The Device Information service exposes several optional String characteristics.
``BLESwift/Peripheral/readDeviceInformation(timeout:)`` discovers the service, reads
whichever characteristics the peripheral actually exposes, and leaves the rest `nil` — it
does not throw just because some strings are absent:

```swift
let info = try await peripheral.readDeviceInformation()
print(info.manufacturerName ?? "unknown manufacturer")
print(info.firmwareRevision ?? "unknown firmware")
```

## Reading a single value

For a one-shot read, decode straight through ``BLESwift/Peripheral/read(from:timeout:)`` by
naming the profile type, or use a purpose-built convenience:

```swift
let battery = try await peripheral.readBatteryLevel()   // UInt8, 0–100
let location: BodySensorLocation = try await peripheral.read(from: BodySensorLocation.characteristic)
```
