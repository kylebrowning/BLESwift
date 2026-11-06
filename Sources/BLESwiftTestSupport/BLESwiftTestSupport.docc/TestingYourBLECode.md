# Testing Your BLE Code

Build a `Central` on scriptable fakes, and test the BLE code of your app without hardware.

## Overview

Every test in this article uses two parts:

- A ``FakeCentral`` and a ``FakePeripheral`` that replace `CBCentralManager` and `CBPeripheral`.
- A real `Central` (from the `BLESwift` module) that uses the fakes through its public backend initializer.

You do not need `@testable import`. An out-of-package consumer uses the same path. The `Examples/ConsumerTests` package of BLESwift tests this path.

### The rig pattern

```swift
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch

// 1. One serial queue, shared by every fake and by `Central` itself.
let queue = DispatchQueue(label: "MyAppTests.rig")
// 2. The fakes, confined to that queue.
let fakeCentral = FakeCentral(queue: queue)
let fakePeripheral = FakePeripheral(queue: queue)
// 3. `Central`'s public backend initializer — no hardware, no special test access.
let central = Central(backend: fakeCentral, queue: queue)
```

From here, `central` behaves like any other `Central`. `await central.stateEvents()`, `try await central.connect(_:)`, and every `Peripheral` GATT method work as they do with hardware. The code of `Central` cannot tell that the backend is a fake.

Most tests first power on the radio and connect, as a real app does:

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

``FakeCentral`` returns `retrievablePeripherals` from `retrievePeripherals(withIdentifiers:)`. `Central.connect(_:)` looks there first. CoreBluetooth also connects only to a peripheral that it already knows.

### The queue-confined contract

``FakeCentral`` and ``FakePeripheral`` are queue-confined and not lock-protected. A real `CBCentralManager` has the same rule: touch its delegate-queue properties only on the delegate queue. The fakes enforce the rule:

- Every property and every method that mirrors CoreBluetooth traps with `dispatchPrecondition` if you touch it off the queue. If your test crashes with a `dispatchPrecondition` failure, a fake was touched from the wrong place. This is not a bug in the fake.
- ``FakeCentral/onQueue(_:)`` and ``FakePeripheral/onQueue(_:)`` are the only permitted way for test code that runs off the queue to configure or inspect a fake.
- Do not call `onQueue(_:)` from inside an `eventHandler` or ``FakePeripheral/onWrite`` closure. Do not call it from other code that already runs on the shared queue, such as the actor code of `Central`. `onQueue(_:)` is a synchronous hop onto the queue. If you call it on the queue, it deadlocks.
- Every `simulate...` call delivers its event asynchronously. The call schedules the delivery and returns at once. To wait for the delivery, use one of the two methods below.

To flush, call `onQueue {}`. This empty block runs synchronously on the shared serial queue. It returns only after all earlier deliveries have run, including the delivery that you triggered:

```swift
fakeCentral.simulateStateChange(.poweredOn)
fakeCentral.onQueue {} // flush: the didUpdateState delivery has now landed
```

To poll, use a helper when you can observe the state only through an actor call. An example is a `Central` method. This helper works with Swift Testing:

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

- ``FakeCentral/connectBehavior`` sets how the next `connect(_:options:)` call ends. The values are `.succeed`, `.fail(_:)` with an `NSError`, and `.hang`. `.hang` never ends. Use it to test timeouts and cancellation.
- ``FakePeripheral/scriptedReadValues`` sets the `Data` that `readValue(for:)` returns for each characteristic. `Peripheral.read(from:)` decodes this data.
- ``FakePeripheral/availableServices`` sets the GATT table of the peripheral. Use it when discovery must omit something. A service or characteristic that is requested and absent then causes `BLESwiftError.missingService(_:)` or `BLESwiftError.missingCharacteristic(_:)`. A real peripheral does the same.
- ``FakePeripheral/holdReadCompletions`` and ``FakePeripheral/simulateNextHeldReadCompletion()`` hold back the completion of a read. Use them to observe the order of the read against other queued work.
- ``FakePeripheral/onWrite`` is a closure that runs synchronously inside `writeValue(_:for:type:)`, before the completion of the write is queued. Use it to script a device that replies at once, for example with `simulateNotification(for:value:)`.
- **Write-without-response back pressure.** ``FakePeripheral/simulateWriteWithoutResponseBackPressure()`` makes the peripheral unable to accept a `.withoutResponse` write. ``FakePeripheral/simulateReadyToSendWriteWithoutResponse()`` clears this state and delivers the event.
- ``FakePeripheral/simulateGATTCacheReset()`` clears all discovered services, characteristics, and descriptors, and the notifying set. CoreBluetooth does the same on disconnect. The call keeps ``FakePeripheral/availableServices`` and all scripted values. To model a GATT table that changed across a reconnect, also set a new `availableServices`.
- **Restoration (iOS only).** `FakeCentral.simulateRestoration(_:)` delivers a `willRestoreState` event. Build the `RestoredState` value with the public memberwise initializers of BLESwiftCore. Call it before the `.poweredOn` state change, as CoreBluetooth does.

### Testing timeouts

A timeout of tens of seconds is too slow for a test, and a shorter timeout changes the thing under test. Use a ``ManualClock`` instead. Give it to `Configuration(clock:)`, and then advance it by hand. In the example, `fakeCentral.connectBehavior` is `.hang`, so the connect never completes.

1. Create the clock and give it to `Configuration`.
2. Start the operation in a `Task`.
3. Call `await clock.waitForSleepers(_:)`. It returns when the timer of the code under test sleeps.
4. Call `clock.advance(by:)`.
5. For a connect timeout, confirm the cancel. `Central` throws only after CoreBluetooth confirms
   the cancel, so call `simulateDisconnect(_:error:)` on the fake.
6. Await the result of the `Task`.

```swift
let clock = ManualClock()
let central = Central(backend: fakeCentral, queue: queue, configuration: Configuration(clock: clock))
let attempt = Task { try await central.connect(fakePeripheral.peripheralIdentifier, timeout: .seconds(30)) }
await clock.waitForSleepers(1)      // The timeout timer sleeps.
clock.advance(by: .seconds(30))     // The timeout fires, and Central cancels the connect.
await fakeCentral.onQueue {}
fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
await #expect(throws: BLESwiftError.connectionTimedOut) { try await attempt.value }
```

`advance(by:)` resumes only the sleepers that are already suspended. If you advance before the code reaches its sleep, nothing wakes. The registration of a sleeper wakes `waitForSleepers(_:)`. It does not poll. The code under test sleeps on the clock from the task that runs its timer, and the test advances it from another task. A `Mutex` guards the clock, so no queue confines it. The example works the same way for a scan timeout or a reconnect backoff, with a different operation in the `Task`. The timers that use `Configuration.clock` are the operation timeouts, the scan timeout, the loss timer, and the reconnect backoff. To delay the answers of a virtual device on the same clock, see `VirtualRadio(clock:)` in `BLESwiftVirtualRadio`.

## What is not supported

BLESwiftTestSupport has two backend conformances besides the CoreBluetooth conformance: these fakes. You can conform your own type to `CentralManaging` and `PeripheralRemote` because the protocols are public. This is not supported. The semantic contract (event order, queue confinement, delivery asynchrony) is documented only on a best-effort basis. Any release can add requirements.

If you need a scriptable backend, script ``FakeCentral`` and ``FakePeripheral``. Do not write a new conformance.

