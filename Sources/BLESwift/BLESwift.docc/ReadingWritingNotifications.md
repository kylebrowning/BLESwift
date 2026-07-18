# Reading, Writing & Notifications

GATT reads, writes, multicast notification streams, and the composite request/response helpers.

## Overview

Every operation in this article is a method on ``Peripheral`` — the handle
``Central/connect(_:timeout:reconnect:warningOptions:)`` returns. Each lazily discovers the
service and characteristic it needs the first time it's used (cached thereafter), and each
serializes against other operations on the *same* characteristic (a different characteristic
proceeds concurrently, unaffected).

### Reading and writing

```swift
let value: UInt16 = try await peripheral.read(from: characteristic, timeout: .seconds(5))

try await peripheral.write(someTransmittableValue, to: characteristic, type: .withResponse)
```

`type: .withoutResponse` waits for CoreBluetooth's write-without-response back-pressure signal
(`canSendWriteWithoutResponse`) before writing, if needed, avoiding a payload that CoreBluetooth
silently drops.

### Introspecting a characteristic's capabilities

``Peripheral/properties(of:)`` reports the set of operations a characteristic advertises —
whether it's readable, writable, notifiable, and so on — as a ``CharacteristicProperties``
option set. Use it to drive capability-based UI, or to branch before an operation, instead of
attempting the operation and inspecting the error:

```swift
let properties = try await peripheral.properties(of: characteristic)

if properties.contains(.notify) {
    // subscribe for streaming updates
} else if properties.contains(.read) {
    // fall back to a one-shot read
}
```

Like every other operation here, it lazily discovers the service and characteristic the first
time it's used, and serializes against other operations on the same characteristic.

Any type conforming to ``Receivable``/``Transmittable`` can be read/written — every fixed-width
integer type (`Int8`/`16`/`32`/`64`, `UInt8`/`16`/`32`/`64`), `String` (UTF-8, throwing
``BLESwiftError/invalidStringEncoding`` instead of crashing on invalid data), and
`Data` itself (identity conformance) all conform out of the box. Conform your own types for
custom binary formats, and use ``combine(_:)`` (with ``DataPadding`` where needed) to assemble a
``Transmittable`` value out of several typed pieces:

```swift
struct Command: Transmittable {
    let opcode: UInt8
    let argument: UInt16

    func toBluetoothData() throws -> Data {
        try combine([opcode, DataPadding(1), argument])
    }
}
```

### Notification streams

``Peripheral/notifications(for:policy:)`` supports any number of concurrent subscribers.
BLESwift's notification streams are **multicast**: each subscriber independently receives
every value.

```swift
let readings: AsyncThrowingStream<HeartRateMeasurement, Error> =
    peripheral.notifications(for: heartRateMeasurement, policy: .bufferingNewest(1))

for try await reading in readings {
    print("\(reading.beatsPerMinute) bpm")
}
```

Underneath, the underlying CoreBluetooth notify state is refcounted: the first subscriber
enables notifications (`setNotifyValue(true)`, its handshake awaited before the call returns —
though the subscription itself is registered *before* that handshake completes, so nothing
delivered mid-handshake is ever lost), and only the last subscriber to stop consuming disables
them again (and only while still connected with the radio powered on).

There is no explicit "stop listening" call: stop consuming (`break`, or cancel the consuming
`Task`) to unsubscribe. A stream ends by **throwing** when the connection ends — see
<doc:ConnectionsAndReconnection> for why streams don't survive reconnection and how to
resubscribe.

``BufferingPolicy`` (BLESwift's own mirror of `AsyncStream.Continuation.BufferingPolicy`, since the
stdlib one is generic over the stream's element and so can't appear in `notifications`'s own
signature) controls what happens when a subscriber falls behind: `.unbounded` (the default)
keeps everything; `.bufferingOldest(n)`/`.bufferingNewest(n)` cap the buffer, dropping the
newest or oldest value respectively once full.

#### Decode isolation

`notifications(for:policy:)` decodes each raw value into `Value` **per subscriber** — every
subscriber has its own decode layer over one shared raw-`Data` multicast. If `Value`'s
``Receivable`` decoding throws for a particular value, only *that* subscriber's stream finishes
with the decode error; sibling subscribers (and the underlying subscription) are unaffected,
since a typed stream can't silently skip a value it failed to decode. Subscribe with `Value ==
Data` for a stream that can never fail decoding (its ``Receivable`` conformance is the
identity).

### Composite helpers

These are request/response conveniences implemented as plain `async` methods, with no
semaphore-based background task machinery required.

``Peripheral/writeAndAwaitNotification(write:to:awaitOn:timeout:)`` writes a value and returns
the first notification received on another characteristic — subscribing *before* writing, in one
atomic step, so a device that replies instantly can't slip its notification past you:

```swift
let response: ResponseType = try await peripheral.writeAndAwaitNotification(
    write: command,
    to: commandCharacteristic,
    awaitOn: responseCharacteristic
)
```

``Peripheral/writeAndAssemble(write:to:assembleFrom:expectedLength:timeout:)`` is the same, but
for replies that arrive as an unknown number of packets: raw payloads accumulate until exactly
`expectedLength` bytes have arrived, then decode. Receiving more than `expectedLength` throws
``BLESwiftError/tooMuchData(expected:received:)``. The `timeout` covers the **whole** assembly — a
device that sends part of a reply and then goes silent still times out, rather than resetting
its clock on every partial packet.

``Peripheral/flush(_:quietPeriod:)`` drains and discards stale, buffered notifications on a
characteristic, returning once a full `quietPeriod` passes with no data (every packet that
arrives resets the window) — useful immediately before a request/response exchange, so a
leftover notification from an earlier, abandoned exchange can't be mistaken for the fresh reply.

## See Also

- <doc:GettingStarted>
- <doc:ConnectionsAndReconnection>
