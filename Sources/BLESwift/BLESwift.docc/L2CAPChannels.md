# L2CAP Channels

Stream bytes over a connection-oriented L2CAP channel when a transfer outgrows GATT.

## Overview

GATT reads, writes, and notifications are the right tool for small, structured values. For
bulk, throughput-sensitive transfers — firmware images, file sync, streaming audio — they
become a bottleneck. CoreBluetooth exposes **L2CAP connection-oriented channels** for
exactly this: a bidirectional byte pipe to a PSM (Protocol/Service Multiplexer) the
peripheral publishes.

BLESwift surfaces an open channel as a `Sendable` ``L2CAPChannel`` handle exposing async
byte I/O — an `AsyncThrowingStream<Data, Error>` inbound and an `async throws` write:

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

A peripheral typically advertises the dynamic PSM to connect on through a GATT
characteristic. Read it, wrap the raw 16-bit value in an ``L2CAPPSM``, and open the channel:

```swift
let raw: UInt16 = try await peripheral.read(from: psmCharacteristic)
let channel = try await peripheral.openL2CAPChannel(psm: L2CAPPSM(raw))
```

``L2CAPPSM`` is BLESwift's owned value type — CoreBluetooth's `CBL2CAPPSM` never appears in
the public API, matching how ``ServiceIdentifier``/``CharacteristicIdentifier`` keep
`CBUUID` out.

### Sending and receiving

- ``L2CAPChannel/incomingData`` is a **single-consumer** `AsyncThrowingStream<Data, Error>`.
  Iterate the one stream; every packet the peripheral sends arrives in order. It finishes by
  **throwing** when the channel closes on error or the peripheral disconnects (with the
  disconnect error), and cleanly when the peer ends the stream or you call
  ``L2CAPChannel/close()``.
- ``L2CAPChannel/write(_:)`` sends bytes outbound and suspends until they have been fully
  written. It honors the channel's back-pressure rather than dropping bytes the peer can't
  yet accept, so a tight `for`-loop of writes streams a large payload without loss.

### Lifetime and teardown

A channel's lifetime is tied to its connection. If the peripheral disconnects — for any
reason — every open channel is torn down automatically and its ``L2CAPChannel/incomingData``
stream finishes by throwing the disconnect error (``BLESwiftError/unexpectedDisconnect``,
``BLESwiftError/explicitDisconnect``, or whatever tore the connection down), exactly like a
notification stream. ``L2CAPChannel/close()`` ends a single channel explicitly while the
peripheral stays connected.

Opening can also be bounded: `openL2CAPChannel(psm:timeout:)` takes an optional `timeout`
(throwing ``BLESwiftError/timedOut``), and cancelling the calling `Task` aborts the open —
either way the connection is left healthy.

### Off-actor stream pumping

`CBL2CAPChannel` vends Foundation `InputStream`/`OutputStream`, which are event-driven and
classically RunLoop-scheduled. BLESwift's ``Central`` actor forbids RunLoop scheduling on its
executor, so the CoreBluetooth transport schedules both streams on a **dedicated serial
`DispatchQueue` per channel** (via `CFReadStreamSetDispatchQueue`/`CFWriteStreamSetDispatchQueue`)
— never a RunLoop, and never the actor's queue. Every read, write, and stream event runs on
that dedicated queue, completely off the actor, and the queue is torn down deterministically
when the channel closes. This is entirely internal; callers just see async byte I/O.

## See Also

- <doc:ReadingWritingNotifications>
- <doc:ConnectionsAndReconnection>
- ``L2CAPChannel``
- ``L2CAPPSM``
