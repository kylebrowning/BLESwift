# L2CAP Channels

Stream bytes over a connection-oriented L2CAP channel when a transfer is too large for GATT.

## Overview

Use GATT reads, writes, and notifications for small, structured values. For bulk transfers that need high throughput, GATT is too slow. Examples are firmware images, file sync, and streaming audio. For these, CoreBluetooth provides **L2CAP connection-oriented channels**. A channel is a two-way byte pipe to a PSM (Protocol/Service Multiplexer) that the peripheral publishes.

An open channel is a `Sendable` ``L2CAPChannel`` handle. It has an `AsyncThrowingStream<Data, Error>` for inbound data and an `async throws` write:

```swift
let channel = try await peripheral.openL2CAPChannel(psm: psm)

// Receive: iterate the inbound stream.
Task {
    do {
        for try await packet in channel.incomingData {
            handle(packet)
        }
    } catch {
        // The channel closed, or the peripheral disconnected.
    }
}

// Send: suspends until the bytes are fully written (back-pressure is honored).
try await channel.write(payload)

// Close when done (a disconnect also closes it automatically).
await channel.close()
```

### Finding the PSM

A peripheral usually publishes its dynamic PSM in a GATT characteristic. Read the 16-bit value, wrap it in an ``L2CAPPSM``, and open the channel:

```swift
let raw: UInt16 = try await peripheral.read(from: psmCharacteristic)
let channel = try await peripheral.openL2CAPChannel(psm: L2CAPPSM(raw))
```

``L2CAPPSM`` is a BLESwift value type. The public API does not expose CoreBluetooth's `CBL2CAPPSM`.

### Sending and receiving

- ``L2CAPChannel/incomingData`` is a **single-consumer** `AsyncThrowingStream<Data, Error>`. Iterate this one stream. Packets arrive in order. The stream finishes cleanly when the peer ends it or when you call ``L2CAPChannel/close()``. It finishes by **throwing** when the channel closes with an error or the peripheral disconnects. In the second case it throws the disconnect error.
- ``L2CAPChannel/write(_:)`` sends bytes and suspends until they are fully written. It honors back-pressure and does not drop bytes that the peer cannot accept yet. A loop of writes can send a large payload without loss.

### Lifetime

A channel lives as long as its connection. When the peripheral disconnects for any reason, BLESwift closes every open channel. Each ``L2CAPChannel/incomingData`` stream throws the disconnect error, as a notification stream does. The error is ``BLESwiftError/unexpectedDisconnect``, ``BLESwiftError/explicitDisconnect``, or the error that ended the connection. ``L2CAPChannel/close()`` closes one channel and leaves the peripheral connected.

`openL2CAPChannel(psm:timeout:)` takes an optional `timeout`. When it elapses, the call throws ``BLESwiftError/timedOut``. If you cancel the calling `Task`, the open stops. In both cases the connection stays healthy.

## See Also

- <doc:ReadingWritingNotifications>
- <doc:ConnectionsAndReconnection>
- ``L2CAPChannel``
- ``L2CAPPSM``
