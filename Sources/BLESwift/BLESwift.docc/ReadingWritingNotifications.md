# Reading, Writing & Notifications

Read and write GATT characteristics, subscribe to notification streams, and use the composite request/response helpers.

## Overview

Each operation in this article is a method on ``Peripheral``. ``Central/connect(_:timeout:reconnect:warningOptions:compatibility:)`` returns this handle. Each operation discovers the service and characteristic that it needs the first time, and caches the result. Operations on the *same* characteristic run one after another. Operations on different characteristics run at the same time.

### Reading and writing

```swift
let value: UInt16 = try await peripheral.read(from: characteristic, timeout: .seconds(5))

try await peripheral.write(someTransmittableValue, to: characteristic, type: .withResponse)
```

For `type: .withoutResponse`, BLESwift waits for the CoreBluetooth signal `canSendWriteWithoutResponse` before it writes. This prevents CoreBluetooth from dropping the payload.

Any type that conforms to ``Receivable`` or ``Transmittable`` can be read or written. These types conform already:

- The fixed-width integer types (`Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`, `UInt64`).
- `String` (UTF-8). Invalid data throws ``BLESwiftError/invalidStringEncoding``.
- `Data`.

To support a custom binary format, conform your own type. Use ``combine(_:)`` and ``DataPadding`` to build a ``Transmittable`` value from several typed parts:

```swift
struct Command: Transmittable {
    let opcode: UInt8
    let argument: UInt16

    func toBluetoothData() throws -> Data {
        try combine([opcode, DataPadding(1), argument])
    }
}
```

### Chunked writes

If a payload is larger than one ATT write, split it into chunks. `Peripheral.writeChunked(_:to:type:chunkSize:timeout:)` sends each chunk after the previous chunk completes. It holds the characteristic for the whole sequence, so no other write can come between chunks.

```swift
try await peripheral.writeChunked(firmwareImage, to: dataCharacteristic, chunkSize: 244)
```

`chunkSize` defaults to ``Peripheral/maximumWriteValueLength(for:)`` for the write type. A `chunkSize` that is zero, negative, or above this maximum throws ``BLESwiftError/invalidArgument(_:)``. Each chunk uses the same path as ``Peripheral/write(_:to:type:timeout:)``.

A second overload returns an `AsyncThrowingStream` of ``WriteProgress``. It emits one value for each chunk, and the last value is the total. Use it for a progress display:

```swift
let stream: AsyncThrowingStream<WriteProgress, Error> =
    peripheral.writeChunked(firmwareImage, to: dataCharacteristic, chunkSize: 244)
for try await progress in stream {
    updateProgressBar(progress.bytesSent, of: progress.totalBytes)
}
```

Note these rules:

- `timeout` applies to each chunk. It does not apply to the whole payload.
- If you cancel between chunks, the call stops and throws ``BLESwiftError/operationCancelled``. You must reconcile a partly sent payload in your protocol.
- BLESwift has no framing hook. It slices the raw bytes at `chunkSize` boundaries. Put any header or sequence number in the value that you pass.

### Characteristic properties

``Peripheral/properties(of:)`` returns the operations that a characteristic supports, as a ``CharacteristicProperties`` option set. Use it to choose an operation before you try it:

```swift
let properties = try await peripheral.properties(of: characteristic)

if properties.contains(.notify) {
    // subscribe for streaming updates
} else if properties.contains(.read) {
    // fall back to a one-shot read
}
```

### Discovering an unknown peripheral

The operations above need the ``CharacteristicIdentifier`` in advance. To inspect a peripheral with unknown UUIDs, enumerate its GATT graph:

- ``Peripheral/discoverServices()`` lists every service.
- ``Peripheral/discoverCharacteristics(for:)`` lists the characteristics of one service.
- ``Peripheral/discoverDescriptors(for:)`` lists the descriptors of one characteristic.

```swift
for service in try await peripheral.discoverServices() {
    print(service)
    for characteristic in try await peripheral.discoverCharacteristics(for: service) {
        let properties = try await peripheral.properties(of: characteristic)
        print("  \(characteristic) — \(properties)")

        for descriptor in try await peripheral.discoverDescriptors(for: characteristic) {
            print("    \(descriptor)")
        }
    }
}
```

BLESwift caches each enumeration for the connection. A second call for the same service sends no new request. A `didModifyServices` event clears the cache. You can observe this event on ``Peripheral/serviceChanges()``. The next call then enumerates again. The identifiers that these calls return are the same types that the other operations take. You can read, write, or subscribe to anything that you discover.

### Notification streams

``Peripheral/notifications(for:policy:survivesReconnect:)`` supports any number of subscribers. The streams are **multicast**. Each subscriber receives every value.

```swift
let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: heartRateMeasurement, policy: .bufferingNewest(1))

for try await reading in readings {
    print("\(reading.beatsPerMinute) bpm")
}
```

The CoreBluetooth notify state is reference-counted. The first subscriber enables notifications with `setNotifyValue(true)`. The call returns after the handshake. BLESwift registers the subscription before the handshake ends, so no value is lost. The last subscriber that stops disables notifications, if the peripheral is still connected and the radio is on.

There is no call to stop a subscription. To unsubscribe, leave the loop with `break` or cancel the consuming `Task`.

By default, a stream finishes by **throwing** when its connection ends. To keep the stream through an unexpected disconnect that a ``ReconnectPolicy`` will retry, pass `survivesReconnect: true`:

```swift
let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: heartRateMeasurement, survivesReconnect: true)
```

For the full rules, see <doc:ConnectionsAndReconnection>. That article also describes the ``ConnectionEvent/notificationsRestored(_:restored:failed:)`` event and how to subscribe again in the default mode.

``BufferingPolicy`` controls what happens when a subscriber falls behind:

- `.unbounded` (the default) keeps every value.
- `.bufferingOldest(n)` keeps the first `n` values and drops new values when the buffer is full.
- `.bufferingNewest(n)` keeps the last `n` values and drops the oldest value when the buffer is full.

#### Decode isolation

Each subscriber decodes the raw values into `Value` on its own, from one shared stream of `Data`. If ``Receivable`` decoding throws for a value, only the stream of that subscriber finishes, with the decode error. The other subscribers and the subscription are not affected. To get a stream that cannot fail to decode, subscribe with `Value == Data`.

### Composite helpers

These helpers are plain `async` methods for request/response exchanges.

- ``Peripheral/writeAndAwaitNotification(write:to:awaitOn:timeout:)`` writes a value and returns the first notification from another characteristic. It subscribes *before* it writes, in one atomic step. A device that replies immediately cannot send its notification before the subscription exists.
- ``Peripheral/writeAndAssemble(write:to:assembleFrom:expectedLength:timeout:)`` is the same for replies that arrive in an unknown number of packets. It collects payloads until exactly `expectedLength` bytes arrive, and then decodes them. More data throws ``BLESwiftError/tooMuchData(expected:received:)``. `timeout` covers the **whole** assembly. A partial packet does not reset it.
- ``Peripheral/flush(_:quietPeriod:)`` discards stale buffered notifications on a characteristic. It returns after a full `quietPeriod` with no data. Each packet resets the period. Call it before an exchange so that an old notification is not read as the new reply.

```swift
let response: ResponseType = try await peripheral.writeAndAwaitNotification(
    write: command,
    to: commandCharacteristic,
    awaitOn: responseCharacteristic
)
```

### Peripherals that do not follow the specification

After discovery, each read, write, and subscription checks the ``CharacteristicProperties`` of the characteristic:

- A read needs `.read`.
- A `.withResponse` write needs `.write`.
- A `.withoutResponse` write needs `.writeWithoutResponse`.
- A subscription needs `.notify` or `.indicate`.

If the property is missing, the call throws ``BLESwiftError/unsupportedCharacteristicOperation(_:required:)``. A new call to ``Peripheral/notifications(for:policy:survivesReconnect:)`` makes this check. The re-arm of a `survivesReconnect: true` subscription after a reconnect does not make it. If the characteristic lost `.notify` and `.indicate` in the meantime, the stream finishes with the CoreBluetooth enable error.

Some low-cost modules report their properties incorrectly. For example, they notify on a characteristic that does not advertise `.notify`. Some fill the GATT table only for unfiltered service discovery. For these devices, pass a ``GATTCompatibility`` to ``Central/connect(_:timeout:reconnect:warningOptions:compatibility:)``. It applies to that connection only:

```swift
// Known-noncompliant module: bypass every property check, discover all services.
let peripheral = try await central.connect(id, compatibility: .lenient)

// Targeted: only this device's phantom notifications are tolerated.
let peripheral = try await central.connect(
    id,
    compatibility: GATTCompatibility(allowNotifyWithoutProperty: true)
)
```

``GATTCompatibility/DiscoveryMode/all`` replaces targeted service discovery with one cached `discoverServices(nil)` for each connection. When a bypass skips a check that would fail, BLESwift logs one warning for each characteristic and operation. A bypass on a compliant device logs nothing.

> Important: Use the ``GATTCompatibility/strict`` default for compliant hardware. The property checks find real protocol errors, for example a wrong characteristic or write type, at the call site. Without them, you get an unclear CoreBluetooth failure.

## See Also

- <doc:GettingStarted>
- <doc:ConnectionsAndReconnection>
- <doc:L2CAPChannels>
