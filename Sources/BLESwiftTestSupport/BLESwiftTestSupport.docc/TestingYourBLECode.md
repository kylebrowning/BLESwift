# Testing Your BLE Code

Build a scriptable `Central`, script the fakes, and assert on your app's actual BLE code —
without hardware.

## Overview

Every test in this article uses the same two ingredients: a ``FakeCentral``/``FakePeripheral``
pair standing in for `CBCentralManager`/`CBPeripheral`, and a real `Central` (from the
`BLESwift` module) wired to them via its public backend initializer. Nothing here requires
`@testable import` — this is the same path an out-of-package consumer uses, and is exercised
as such by BLESwift's own `Examples/ConsumerTests` package.

### The rig pattern

```swift
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

// 1. One serial queue, shared by every fake and by `Central` itself.
let queue = DispatchSerialQueue(label: "MyAppTests.rig")
// 2. The fakes, confined to that queue.
let fakeCentral = FakeCentral(queue: queue)
let fakePeripheral = FakePeripheral(queue: queue)
// 3. `Central`'s public backend initializer — no hardware, no special test access.
let central = Central(backend: fakeCentral, queue: queue)
```

From here, `central` behaves like any other `Central`: `await central.stateEvents()`,
`try await central.connect(_:)`, and every `Peripheral` GATT method work exactly as they do
against real hardware — because `Central`'s own code has no idea it isn't talking to one.

A typical test also powers the radio on and connects before doing anything else, mirroring
what every real app does first:

```swift
fakeCentral.simulateStateChange(.poweredOn)
for await state in await central.stateEvents() {
    if state == .poweredOn { break }
}

fakeCentral.onQueue {
    fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
    fakeCentral.connectBehavior = .succeed
}
let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
```

`retrievablePeripherals` is what ``FakeCentral`` returns from `retrievePeripherals(withIdentifiers:)`
— `Central.connect(_:)` looks a peripheral up there first, mirroring CoreBluetooth's own
"connect only works on a peripheral CoreBluetooth already knows about" behavior.

### The queue-confined contract

``FakeCentral`` and ``FakePeripheral`` are **queue-confined, not lock-protected** — the same
discipline a real `CBCentralManager`/`CBPeripheral` follows, where every delegate callback (and
every property CoreBluetooth documents as delegate-queue-only) is only safe to touch from the
queue delegate callbacks arrive on. Both fakes enforce this structurally:

- **Every property and every CB-mirroring method traps via `dispatchPrecondition` if touched
  off-queue.** If your test crashes with a `dispatchPrecondition` failure, that's the contract
  telling you a fake was touched from the wrong place — not a bug in the fake.
- **``FakeCentral/onQueue(_:)`` / ``FakePeripheral/onQueue(_:)`` is the one sanctioned door**
  for off-queue (i.e. ordinary test) code to configure or inspect a fake. Every scripted-value
  assignment and every counter read above goes through it.
- **Never call `onQueue(_:)` from inside an `eventHandler`/``FakePeripheral/onWrite``
  closure**, or from any other code already running on the shared queue (which is where
  `Central`'s own actor-isolated code runs, since its executor is tied to the same queue) —
  `onQueue(_:)` is a synchronous hop onto that queue, and calling it while already on it is a
  reentrant deadlock.
- **Every `simulate...` call delivers its event *asynchronously*.** A `simulate` call
  schedules the delivery and returns immediately — it does not deliver inline. Two ways to
  wait for it to land:
  - **Flush with `onQueue {}`** — an empty block run synchronously on the shared, serial
    queue only returns once every previously-scheduled delivery (including the one you just
    triggered) has run:
    ```swift
    fakeCentral.simulateStateChange(.poweredOn)
    fakeCentral.onQueue {} // flush: the didUpdateState delivery has now landed
    ```
  - **Poll, for state you can only observe by awaiting an actor call** (e.g. a `Central`
    method, rather than a fake's own counter) — a small helper like this one works well with
    Swift Testing:
    ```swift
    func waitFor(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    ```

### Scripting reference

- ``FakeCentral/connectBehavior``: how the next `connect(_:options:)` call resolves —
  `.succeed`, `.fail(_:)` with an `NSError`, or `.hang` (never resolves, for exercising
  timeout/cancellation).
- ``FakePeripheral/scriptedReadValues``: the `Data` a `readValue(for:)` call reports back,
  keyed by characteristic — what `Peripheral.read(from:)` ultimately decodes.
- ``FakePeripheral/availableServices``: the peripheral's actual GATT table, when you need
  discovery to genuinely omit something (rather than always succeeding permissively) — set
  this to make a requested-but-absent service or characteristic surface
  `BLESwiftError.missingService(_:)`/`BLESwiftError.missingCharacteristic(_:)`, exactly as a
  real peripheral whose GATT table doesn't contain what was asked for would.
- ``FakePeripheral/holdReadCompletions`` + ``FakePeripheral/simulateNextHeldReadCompletion()``:
  withhold a read's completion instead of delivering it immediately, to observe ordering
  against other work queued behind it.
- ``FakePeripheral/onWrite``: a closure invoked synchronously from inside `writeValue(_:for:type:)`,
  before the write's own completion is enqueued — script a device that replies to a write
  instantly (e.g. by calling `simulateNotification(for:value:)` from inside it).
- **Write-without-response back pressure**:
  ``FakePeripheral/simulateWriteWithoutResponseBackPressure()`` marks the peripheral as
  temporarily unable to accept a `.withoutResponse` write;
  ``FakePeripheral/simulateReadyToSendWriteWithoutResponse()`` clears it and delivers the
  corresponding event.
- **Restoration (iOS only)**: `FakeCentral.simulateRestoration(_:)` delivers a
  `willRestoreState` event built from a `RestoredState` value you construct directly (Core's
  public memberwise inits) — call it before the `.poweredOn` state change, mirroring
  CoreBluetooth's own delivery ordering.

## What isn't supported

BLESwiftTestSupport ships exactly two backend conformances beyond CoreBluetooth's own: these
fakes. Conforming your own type to `CentralManaging`/`PeripheralRemote` (a third-party or
hand-rolled backend) is possible — the protocols are public — but unsupported: their semantic
contract (event ordering, queue confinement, delivery asynchrony) is documented on a
best-effort basis on `CentralManaging` and `PeripheralRemote` themselves and may gain
requirements in any release. If you need a scriptable backend, script ``FakeCentral``/
``FakePeripheral`` — don't write a new conformance.

