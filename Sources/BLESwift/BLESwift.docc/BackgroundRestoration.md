# Background Restoration

Recover an in-progress connection or scan after iOS relaunches your app in the background,
surfaced as buffered event replay.

## Overview

iOS can terminate a backgrounded app and later relaunch it in the background to handle a
Bluetooth event (e.g. a peripheral reconnecting) on its behalf. CoreBluetooth's state
restoration is how your app recovers what it was doing before termination. BLESwift surfaces this
as a single buffered stream of `RestorationEvent`s, rather than a pair of delegate protocols.

- iOS only. Restoration is enabled by setting `Configuration`'s
  `restoration: RestorationConfiguration?` field (iOS-only API), supplying a stable
  restoration identifier:

  ```swift
  let configuration = Configuration(
      restoration: RestorationConfiguration(identifier: "com.example.myapp.central")
  )
  let central = Central(configuration: configuration)
  ```

- `central.restorationEvents()` returns an `AsyncStream<RestorationEvent>` that **replays every
  event buffered since `Central` was created** to its first subscriber — not just the latest
  one. CoreBluetooth can deliver `willRestoreState` synchronously during `CBCentralManager`
  initialization, potentially before your code has had a chance to start consuming anything, so
  nothing is lost to that race.

### Launch-time discipline

State restoration only works if `Central` exists *before* CoreBluetooth needs to deliver a
restoration callback — which can happen extremely early in a background relaunch. This means:

- Create your `Central` **synchronously**, as early as possible — in your `App`'s
  initializer (SwiftUI) or `application(_:didFinishLaunchingWithOptions:)` (UIKit app delegate).
  Do not defer creation behind a view appearing, a user action, or any other lazy trigger: by
  the time those fire, the restoration window may already have closed.
- Start consuming `central.restorationEvents()` immediately after creating `Central`, in the
  same launch path. Because the stream replays everything buffered since `init`, it's safe to
  start that consumer a little later than `Central` itself — but do it as part of the same
  synchronous launch sequence, not lazily.

```swift
@main
struct MyApp: App {
    let central: Central

    init() {
        central = Central(configuration: Configuration(
            restoration: RestorationConfiguration(identifier: "com.example.myapp.central")
        ))
        Task {
            for await event in await central.restorationEvents() {
                switch event {
                case .willRestore(let restoredState):
                    // peripherals + scan services/options snapshot from before termination
                    break
                case .restoredConnection(let peripheral):
                    // a previously-connected peripheral is connected again — resubscribe to
                    // whatever notifications you need, as you would after any reconnect
                    break
                case .failedToRestoreConnection(let peripheral, let error):
                    break
                case .unhandledNotification(let peripheral, let characteristic, let data):
                    // a notification arrived for a characteristic nothing had (yet)
                    // resubscribed to during restoration
                    break
                }
            }
        }
    }

    var body: some Scene { WindowGroup { ContentView() } }
}
```

### Force-quit caveat

State restoration **never fires if the user force-quits your app** (swiping it away from the
app switcher) — this is an iOS system policy, not something any library can work around. Design
around it: don't rely on restoration alone to guarantee reconnection; treat it as a best-effort
recovery for ordinary background termination (memory pressure, expiry), not a substitute for
your own reconnection logic (see <doc:ConnectionsAndReconnection>) for the force-quit case.

### Required capability

Restoration (and any Bluetooth work while backgrounded at all) requires the `bluetooth-central`
background mode. Add it to your app's `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

Without it, iOS does not relaunch your app for Bluetooth events in the background, and no
restoration events will ever arrive regardless of how `Central` is configured.

### Fallback: reconnecting without restoration

If you'd rather not depend on state restoration — or you're on a platform/configuration where
it isn't available — you can get most of the same practical benefit with
``Central/knownPeripherals(withIdentifiers:)``: persist the `uuid`s of the peripherals you
care about yourself (e.g. in `UserDefaults` or your own storage), then on your next ordinary
launch re-resolve them with `knownPeripherals(withIdentifiers:)` and call
``Central/connect(_:timeout:reconnect:warningOptions:)`` on each result. CoreBluetooth can
still resolve a previously-seen peripheral's identifier back to a connectable object without a
fresh scan, so this works even though it isn't triggered by a background relaunch the way
restoration is — it simply requires your app to actually be launched (by the user, or some
other mechanism) rather than iOS launching it for you. This is the deliberate fallback for
force-quit specifically: as above, restoration never fires there, but the app's ordinary launch
path still runs, and that's exactly where this call belongs.

If the system might still be holding the link (the peripheral never actually disconnected),
``Central/systemConnectedPeripherals(withServices:)`` is worth trying first — it only returns
peripherals the OS is *currently* connected to (by any app), and connecting one of those
typically completes faster than connecting a merely-known one.

```swift
let saved = loadSavedPeripheralUUIDs() // your own persistence
let known = try await central.knownPeripherals(withIdentifiers: saved)
for identifier in known {
    _ = try await central.connect(identifier)
}
```

## See Also

- <doc:ConnectionsAndReconnection>
- <doc:GettingStarted>
