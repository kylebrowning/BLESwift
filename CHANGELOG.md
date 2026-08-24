# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

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

[Unreleased]: https://github.com/kylebrowning/BLESwift/compare/1.0.2...HEAD
[1.0.2]: https://github.com/kylebrowning/BLESwift/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/kylebrowning/BLESwift/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/kylebrowning/BLESwift/compare/0.2.0...1.0.0
[0.2.0]: https://github.com/kylebrowning/BLESwift/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/kylebrowning/BLESwift/releases/tag/0.1.0
