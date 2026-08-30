# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `BackendRegistry` (BLESwiftCore): a process-wide pair of optional backend factories that
  `Central(configuration:)` and `PeripheralHost(configuration:)` consult when constructing
  their default backend. Both are `nil` unless something registers one.
- `BLESwiftLink`, `BLESwiftSimulatorLink`, and `BLESwiftProvider` products, plus the
  `bleswift-provider` executable: BLE in the iOS Simulator, where CoreBluetooth is
  non-functional. `SimulatorLink.install()` routes every subsequently-constructed `Central()`
  / `PeripheralHost()` over a localhost TCP link to a `bleswift-provider` process on the host
  Mac, which serves it from the Mac's real radio (`--passthrough`), from an in-process virtual
  radio, or both. `BLESWIFT_LINK` (`host:port`) overrides the default `127.0.0.1:45541`
  endpoint on both ends, and `SimulatorLink.isProviderReachable()` probes for a listening
  provider. See the "Running in the iOS Simulator" DocC article.
- A declarative JSON fixture format (`FixtureDocument`/`FixtureDevice`/`FixtureService`/
  `FixtureCharacteristic` in BLESwiftLink), loaded with `bleswift-provider --fixture`: virtual
  devices with advertisements and GATT databases, base64 values and manufacturer data,
  permissions derived from the declared properties, writes stored, and writes to a notifying
  characteristic pushed to every subscriber.
- `Provider.addVirtualDevice(_:advertising:)` (BLESwiftProvider): host a virtual device
  written in Swift — a `VirtualDeviceDescriptor` plus a `VirtualDeviceHandler` — and drive it
  afterwards through the returned `VirtualDeviceHandle`.
- `BLESwiftExplorer`: an Advertise tab driving `PeripheralHost`, and `--auto-advertise` /
  `--auto-scan` launch arguments for automated runs.
- A two-simulator end-to-end test (`Scripts/sim-to-sim-e2e.sh`) and its CI job: two simulator
  apps meet on the provider's virtual radio — one advertising, one scanning and connecting —
  with no Bluetooth hardware and no entitlements.

### Changed

- `Central(configuration:)` and `PeripheralHost(configuration:)` now consult `BackendRegistry`
  when constructing their default backend. No behavior change when nothing is registered: they
  construct CoreBluetooth exactly as before. The explicit `init(backend:queue:…)` initializers
  ignore the registry.
- Documented a limitation of the `--passthrough` L2CAP path (BLESwiftProvider): the provider
  pairs `didOpenL2CAPChannel` completions to a client's channel opens by arrival order, per
  peripheral, because the callback carries nothing that names the open it answers. A
  completion for an open that was outstanding when the peripheral disconnected is discarded if
  it arrives before the client reconnects, but one arriving after the client has reconnected
  and opened again is taken for the new open's answer — bridging the new channel to the
  previous connection's transport. This cannot be closed at the provider; it is written up in
  `bridgeOpenedChannel` and in the "Where the link diverges from CoreBluetooth" list of the
  "Running in the iOS Simulator" article. Virtual devices are unaffected. (#28)

### Fixed

- `HostSession` (BLESwiftProvider) counted every `addService` request against
  `maximumHostedServices`, including the ones the backend refused as duplicates: a client that
  re-added one service sixty-four times — and was correctly told each time that it was a
  duplicate — lost its link over a database holding one service. A refused `didAddService` now
  gives the slot back. (#26)

- `CentralSession`'s L2CAP pump (BLESwiftProvider) sent inbound bytes onto the link without
  the identity check every other off-queue completion makes: a pump that had cleared its
  cancellation check just before its bridge was torn down could put the dead channel's bytes
  on the wire under a channel id the session had since re-issued. (#27)

- `Provider.addVirtualDevice(_:advertising:)` (BLESwiftProvider) recorded its device after a
  suspension the provider serves `stop()` across, so a stop overlapping the call left the
  device on the radio in neither of the tables `stop()` empties — never removed, and its
  identifier no longer defended. Such a registration is now taken straight back off, including
  when it began inside one stop's window and resumed after a second, overlapping stop had
  returned. (#29)

- `Provider.start()` (BLESwiftProvider) registered its fixtures before binding the listener
  and left them registered when the bind threw — a port already in use, the documented case.
  A retry then registered each fixture a second time under a fresh generation and stranded
  every handle the first attempt had vended. A failed start now rolls its registrations
  back. (#30)

- `CentralSession` (BLESwiftProvider) dropped the whole link — the scan, every peripheral,
  every L2CAP channel — when a client queued more than 256 `.withoutResponse` writes for one
  peripheral, which a few hundred writers released together by a single readiness signal
  reach honestly. Excess writes are now parked per peripheral (1024 writes or 1 MiB,
  whichever comes first) and drained on the backend's readiness; only past that cap does that
  peripheral's queue go — dropped with nothing reported, exactly as CoreBluetooth drops a
  `.withoutResponse` write it cannot send, but acknowledged write by write so the client's
  window is not left holding slots for payloads that were discarded. (#31)
- `VirtualDeviceHandle` (BLESwiftProvider) now holds its `VirtualRadio` weakly. A radio with
  a fixture attached formed a retain cycle — radio → device table → `FixtureDeviceHandler` →
  handle → radio — and never deallocated unless `Provider.stop()` explicitly removed the
  device.
- `CompositeCentral` and `CompositePeripheralManager` (BLESwiftProvider) now reconcile a
  child from the `didUpdateState` payload instead of re-reading its live `radioState`. Two
  transitions that coalesced before the handler drained them read as no change at all, so a
  child that power-cycled was never re-issued the scan and the connection-event registration,
  nor had its services republished and its advertisement restarted.
- Clearing `VirtualPeripheralManagerBackend.eventHandler` (BLESwiftProvider) now detaches the
  handler and nothing more, leaving the hosted device on the radio and re-attaching a working
  backend — as `CompositePeripheralManager` documents for every child it clears and
  re-installs. It used to remove the device and end the backend's work chain permanently, so a
  detach through a composite was terminal. The device is still taken off the radio when the
  backend is deallocated, and when a peripheral-role session closes.
- `LinkCentral.shutdown()` and `LinkPeripheralManager.shutdown()` (BLESwiftSimulatorLink) now
  run the same teardown a dropped link runs before they detach their event handler, so a
  consumer mid-operation is failed rather than stranded: every connected peripheral is
  disconnected, every subscriber reported as departing, and the state dropped to
  `.unsupported` (open L2CAP channels were already failed on shutdown; that teardown moved
  into the shared path). Stopping the session marks it stopped before its connection
  reaches a terminal state, so none of the rest used to happen at all.
- Fixed a lock-order deadlock between event fan-out and stream cancellation. The internal
  `Broadcaster` and `ThrowingBroadcaster` held their `Mutex` across
  `AsyncStream.Continuation.yield`, which takes the consuming task's status lock, while a
  concurrent cancellation of that consumer held the same status lock and re-entered the
  `Mutex` from `onTermination`. Both now snapshot their subscribers under the lock and fan
  out after releasing it, as `finish()` already did. Any consumer cancelling a
  `connectionEvents()`/`stateUpdates()`-style stream mid-burst could hang. (#25)

## [2.0.0] - 2026-08-24

> **Breaking:** GATT read/write/notify now validate a characteristic's advertised
> `CharacteristicProperties` by default and throw `unsupportedCharacteristicOperation` when
> the operation is not advertised. Peripherals that misreport their properties need
> `compatibility: .lenient` (or a targeted `GATTCompatibility` flag) on `connect`. See
> **Changed** below. This is the reason for the major version bump; every other change is additive.

### Added

- `Central.connectionEventRegistration(services:peripherals:)` and `SystemConnectionEvent`
  (BLESwiftCore): a multicast stream of system-level connection events
  (`registerForConnectionEvents(options:)`) — delivered when a matching peripheral connects
  to or disconnects from the system by any app. The CoreBluetooth registration is
  refcounted: registered on the first subscriber, deregistered when the last cancels.
  iOS/tvOS/watchOS/visionOS (not macOS, matching the SDK).
- ANCS support (iOS only): a `requiresANCS: Bool = false` parameter on
  `Central.connect(_:timeout:reconnect:warningOptions:compatibility:requiresANCS:)`
  (`CBConnectPeripheralOptionRequiresANCS`, reused by auto-reconnect attempts), plus
  `Peripheral.ancsAuthorized` and `Peripheral.ancsAuthorizationEvents()` mirroring
  `CBPeripheral.ancsAuthorized`/`didUpdateANCSAuthorizationFor`.
- `FakeCentral.simulateConnectionEvent(_:for:)`/`simulateANCSAuthorization(_:for:)`
  (BLESwiftTestSupport), with `connectionEventRegistrationCount`,
  `connectionEventUnregistrationCount`, `lastConnectionEventServices`,
  `lastConnectionEventPeripherals`, and `lastConnectRequiresANCS` recorders;
  `FakePeripheral.ancsAuthorized` is scriptable. Available on every platform.

- `ScanFilter` (BLESwiftCore): declarative scan match criteria — `services` (radio-level),
  `namePrefix`/`nameExact`, `manufacturerID`/`manufacturerDataPrefix`, per-service
  `serviceData` presence/prefix requirements, `minimumRSSI`, `connectableOnly`, and a
  `custom` closure escape hatch — with a public `matches(_:)`.
- `Central.scan(filter:allowDuplicates:rssiThreshold:lossTimeout:timeout:)`: scanning with a
  `ScanFilter`; non-matching sightings are dropped before any recording. The existing
  `scan(services:)` is now a thin wrapper over it, behaving exactly as before.
- `Central.findFirst(matching:timeout:)`: returns the first `Discovery` matching a
  `ScanFilter` and stops the scan, torn down on every exit path (success, timeout, error,
  cancellation).
- `Central.connect(identifier:fallbackScan:reconnect:timeout:compatibility:)`: the saved-device flow —
  resolves a persisted `UUID` via `knownPeripherals(withIdentifiers:)`, falling back to a
  `findFirst` scan (whose result may carry a different UUID) when given a `fallbackScan`.
- `FakeCentral.lastScanServices` (BLESwiftTestSupport): records the `services` passed to the
  most recent `scanForPeripherals(withServices:options:)` call.

- `Peripheral.notifications(for:policy:survivesReconnect:)`: an optional
  `survivesReconnect` parameter (default `false`, preserving existing behavior) that keeps a
  notification stream parked across an unexpected disconnect an active `ReconnectPolicy`
  will retry, resuming delivery on the same stream once the reconnect re-arms the
  subscription.
- `ConnectionEvent.notificationsRestored(_:restored:failed:)`: emitted once after a
  reconnect re-arms surviving notification subscriptions, listing the characteristics
  restored and mapping any that failed to re-arm to their errors.
- `FakePeripheral.simulateGATTCacheReset()` (BLESwiftTestSupport): clears the fake's
  discovered service graph as a real disconnect would, for testing re-discovery across
  reconnects.
- `Peripheral.writeChunked(_:to:type:chunkSize:timeout:)`: the outbound counterpart to
  `writeAndAssemble`, splitting a payload into `chunkSize`-byte chunks and sending each only
  after the previous completes, holding the characteristic's serialization lane for the whole
  sequence. Comes in two overloads distinguished by return type: a plain `async throws` one
  that awaits full completion, and an `AsyncThrowingStream<WriteProgress, Error>` one that
  reports per-chunk progress (for firmware-update UIs). `timeout` applies per chunk;
  cancelling between chunks throws `operationCancelled`.
- `WriteProgress`: the per-chunk progress value (`bytesSent`, `totalBytes`, `isComplete`)
  emitted by the streaming `writeChunked` overload.
- `GATTCompatibility` (BLESwiftCore): per-connection accommodations for peripherals that
  misreport their GATT database — `allowNotifyWithoutProperty`/`allowReadWithoutProperty`/
  `allowWriteWithoutProperty` bypass the corresponding property check, and
  `discovery: .all` replaces targeted service discovery with a single cached
  `discoverServices(nil)` per connection. `.strict` (the default) enforces everything;
  `.lenient` bypasses everything.
- `Central.connect(...)`: a `compatibility: GATTCompatibility = .strict` parameter on both
  `connect(_:timeout:reconnect:warningOptions:compatibility:)` and
  `connect(identifier:fallbackScan:reconnect:timeout:compatibility:)`. Carried per
  connection (and across that connection's auto-reconnects); one peripheral's setting never
  affects another.
- `BLESwiftError.unsupportedCharacteristicOperation(_:required:)`: thrown when a GATT
  operation targets a characteristic whose advertised properties lack the required
  capability.
- `BLESwiftProfiles` product: typed `Receivable` decoders for Heart Rate Measurement,
  Battery Level, Device Information, Current Time, Body Sensor Location, CSC Measurement,
  Cycling Power Measurement, and Temperature Measurement, plus
  `Peripheral.readDeviceInformation()` / `readBatteryLevel()`.
- `BLESwiftExplorer` (Examples): a SwiftUI sample app for exploring the central role —
  scanning, connecting, and browsing a peripheral's GATT database interactively.

### Changed

- GATT reads, writes, and notification subscriptions now validate the characteristic's
  advertised `CharacteristicProperties` by default — after lazy discovery, before issuing
  the operation — and throw `BLESwiftError.unsupportedCharacteristicOperation(_:required:)`
  when the property is missing (`.read` for reads, `.write` for `.withResponse` writes,
  `.writeWithoutResponse` for `.withoutResponse` writes, `.notify`/`.indicate` for
  notification subscriptions). Previously no property enforcement existed. Pass a
  `compatibility:` to `connect` to bypass per connection for non-compliant peripherals;
  when a bypass skips a check that would have failed, BLESwift logs a warning once per
  (peripheral, characteristic, operation). Descriptor reads/writes are unaffected.
- `FakePeripheral.defaultProperties` (BLESwiftTestSupport) now includes
  `.writeWithoutResponse` (it is `[.read, .write, .writeWithoutResponse, .notify]`), so
  unscripted characteristics keep accepting `.withoutResponse` writes under the new
  enforcement.
- `Examples/HeartRateMonitor` now imports `BLESwiftProfiles` instead of defining its own
  decoder.

### Fixed

## [1.0.2] - 2026-08-17

### Fixed

- Fenced the peripheral role (`PeripheralHost` and its supporting CoreBluetooth bridging)
  behind `#if os(iOS) || os(macOS)`. `CBPeripheralManager` is unavailable on watchOS, tvOS,
  and visionOS, so the package failed to build for those platforms. (#23)

## [1.0.1] - 2026-07-31

### Changed

- Toned down comment verbosity across the codebase.
- Removed the unused `immediate` parameter from `Central.disconnect(_:immediate:)`; it was
  accepted and then ignored.
- Fixed README formatting for the BLESwift description.

### Fixed

- Fixed the package build for Xcode consumers: strict warnings-as-errors now applies only
  when `BLESWIFT_STRICT` is set, because Xcode compiles package dependencies with
  `-suppress-warnings`, which hard-conflicts with `-warnings-as-errors`. (#20)
- Pinned continuation isolation and made responder closures `@Sendable` so the package
  builds against the Swift 6.3 release toolchain, not just newer Xcode betas.
- Added an explicit `Session` initializer for Swift 6.3 compatibility (the compiler does not
  synthesize a usable memberwise init there).
- Cross-role responder tasks now capture the host actor directly.
- Added test coverage for the CoreBluetooth bridging mappers, error descriptions, and host
  cancellation.

## [1.0.0] - 2026-07-19

### Added

- Apache 2.0 license.

### Fixed

- The `CBL2CAPChannel` is now retained for the lifetime of its transport, so an open channel
  is no longer torn down while still in use.

## [0.2.0] - 2026-07-19

### Added

- Bluetooth SIG assigned-numbers lookup (`GATTAssignedNumbers`, plus `.name` on the
  identifier types). (#9)
- Peripheral-role state restoration (`PeripheralRestorationConfiguration`,
  `PeripheralRestorationEvent`, `PeripheralHost.restorationEvents()`). (#10)
- A cross-role end-to-end example driving both the central and peripheral roles over the
  fakes. (#11)
- GATT enumeration API: `discoverServices()`, `discoverCharacteristics(for:)`, and
  `discoverDescriptors(for:)`. (#12)

### Fixed

- Fixed a test-suite deadlock under parallel load. (#13)

## [0.1.0] - 2026-07-19

### Added

- Initial release: `actor Central`, an async/await-first CoreBluetooth wrapper whose
  isolation is tied to the `DispatchSerialQueue` CoreBluetooth delivers callbacks on.
- Split into `BLESwiftCore` (backend-agnostic types and the backend seam) and `BLESwift`
  (the CoreBluetooth-backed implementation).
- Published the backend seam and shipped `BLESwiftTestSupport` with `FakeCentral` and
  `FakePeripheral` for hardware-free unit testing.
- Multiple simultaneous peripheral connections, each with independent connection lifecycle,
  `ReconnectPolicy`, and GATT/notification state; per-peripheral service-change streams.
- Known/system-connected peripheral retrieval (`knownPeripherals(withIdentifiers:)`,
  `systemConnectedPeripherals(withServices:)`).
- Characteristic property introspection (`properties(of:)`). (#3)
- Characteristic descriptor read/write (`DescriptorIdentifier`, `readDescriptor(_:timeout:)`,
  `writeDescriptor(_:value:timeout:)`). (#2)
- L2CAP channel support (`L2CAPChannel`, `L2CAPPSM`, `openL2CAPChannel(psm:timeout:)`). (#1)
- Peripheral role backed by `CBPeripheralManager` (`PeripheralHost`). (#4)

### Fixed

- Fixed a deadlock when connecting to the same peripheral concurrently.
- Restoring multiple peripherals now happens concurrently.

[Unreleased]: https://github.com/kylebrowning/BLESwift/compare/2.0.0...HEAD
[2.0.0]: https://github.com/kylebrowning/BLESwift/compare/1.0.2...2.0.0
[1.0.2]: https://github.com/kylebrowning/BLESwift/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/kylebrowning/BLESwift/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/kylebrowning/BLESwift/compare/0.2.0...1.0.0
[0.2.0]: https://github.com/kylebrowning/BLESwift/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/kylebrowning/BLESwift/releases/tag/0.1.0
