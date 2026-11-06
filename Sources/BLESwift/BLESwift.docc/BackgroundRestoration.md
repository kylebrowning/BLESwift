# Background Restoration

Recover a connection or scan after iOS relaunches your app in the background.

## Overview

iOS can terminate a backgrounded app. Later, it can relaunch the app in the background to handle a Bluetooth event, for example a peripheral that reconnects. CoreBluetooth state restoration lets your app recover what it was doing before termination. BLESwift delivers restoration as one buffered stream of ``RestorationEvent`` values.

Restoration is available on iOS only. To enable it, set the `restoration` field of ``Configuration`` to a ``RestorationConfiguration`` with a stable identifier:

```swift
let configuration = Configuration(
    restoration: RestorationConfiguration(identifier: "com.example.myapp.central")
)
let central = Central(configuration: configuration)
```

`central.restorationEvents()` returns an `AsyncStream<RestorationEvent>`. It replays **every event buffered since `Central` was created** to its first subscriber. CoreBluetooth can deliver `willRestoreState` during `CBCentralManager` initialization, before your code consumes anything. The buffer prevents loss of that event.

Restoration can include more than one peripheral. `RestoredState.peripherals` has every peripheral that CoreBluetooth preserved, and `Central` handles all of them:

- `Central` adopts each restored peripheral that is *connected* as a live session.
- `Central` makes a manual reconnect attempt for each restored peripheral that is *connecting*.
- Each peripheral produces its own `.restoredConnection` or `.failedToRestoreConnection` event with its `PeripheralIdentifier`.

Loop over these events. Do not handle only the first one.

### Launch-time rules

Restoration works only if `Central` exists before CoreBluetooth delivers the restoration callback. This can happen early in a background relaunch.

1. Create `Central` synchronously and as early as possible. Use your `App` initializer (SwiftUI) or `application(_:didFinishLaunchingWithOptions:)` (UIKit). Do not wait for a view, a user action, or any lazy trigger.
2. Start to consume `central.restorationEvents()` in the same launch path. The stream replays buffered events, so the consumer can start after `Central`. Do not start it lazily.

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

### Required capability

Add the `bluetooth-central` background mode to your app's `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

Without this mode, iOS does not relaunch your app for Bluetooth events. No restoration event arrives, whatever the `Central` configuration is.

### Force-quit limit

State restoration does not run if the user force-quits your app from the app switcher. This is an iOS rule. No library can change it. Use restoration as best-effort recovery after ordinary background termination, for example memory pressure. Do not use it as your only reconnection logic. For the force-quit case, use the fallback below.

### Fallback: reconnect without restoration

A force-quit app still runs your ordinary launch path. In that path, you can reconnect to saved peripherals without restoration.

1. Save the `uuid` of each peripheral that you care about in your own storage, for example `UserDefaults`.
2. On the next launch, call ``Central/knownPeripherals(withIdentifiers:)`` with the saved values.
3. Call ``Central/connect(_:timeout:reconnect:warningOptions:compatibility:)`` on each result.

CoreBluetooth can resolve a known identifier to a connectable peripheral without a scan.

```swift
let saved = loadSavedPeripheralUUIDs() // your own persistence
let known = try await central.knownPeripherals(withIdentifiers: saved)
for identifier in known {
    _ = try await central.connect(identifier)
}
```

If the system can still hold the connection, try ``Central/systemConnectedPeripherals(withServices:)`` first. It returns only the peripherals that the OS is connected to now, for any app. A connect to one of these is usually faster.

## See Also

- <doc:ConnectionsAndReconnection>
- <doc:GettingStarted>
