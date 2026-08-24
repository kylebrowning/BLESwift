# Contributing to BLESwift

Thanks for your interest in BLESwift. This document covers how to build and test the package,
the rules the codebase holds itself to, and what's expected of a pull request.

## Building and testing

BLESwift builds warning-clean. Strict warnings are opt-in via the `BLESWIFT_STRICT`
environment variable, because Xcode compiles package dependencies with `-suppress-warnings`,
which hard-conflicts with `-warnings-as-errors` and would make the package unbuildable for
consumers.

```sh
# Build with warnings as errors.
BLESWIFT_STRICT=1 swift build

# Full test suite (Swift Testing).
BLESWIFT_STRICT=1 swift test

# Consumer simulation: this is how Xcode builds the package as a dependency.
# It fails if strict warnings ever leak back into the default settings.
swift build -Xswiftc -suppress-warnings
```

The manifest declares watchOS, tvOS, and visionOS, where CoreBluetooth's peripheral-role APIs
do not exist and must stay fenced out. Build the platform matrix before opening a PR if you
touched anything under `Sources/`:

```sh
for platform in watchOS tvOS visionOS; do
  xcodebuild build -scheme BLESwift -destination "generic/platform=$platform"
  xcodebuild build -scheme BLESwiftTestSupport -destination "generic/platform=$platform"
done
```

CI runs all of the above on every pull request.

### Swift 6.3 verification

CI verifies the package against the Swift 6.3 release toolchain — the toolchain consumers
actually build with. This matters: an Xcode beta's newer compiler is *more* lenient than the
6.3 release, and has masked real failures here (private memberwise inits, `@Sendable`
inference for `Mutex`-capturing closures, isolation lost through
`withTaskCancellationHandler`). A change that compiles locally can still fail on 6.3, so treat
the CI toolchain result as authoritative rather than your local build. Follow the existing
`#if compiler(>=6.4)` / `withCheckedThrowingContinuation(isolation: self, ...)` pattern in
`Central.swift` when adding new continuations.

## Codebase rules

### Actor isolation

`Central` is an actor whose isolation is tied to the `DispatchSerialQueue` that
`CBCentralManager` delivers callbacks on. Every new feature preserves that: **no thread hops,
no detached tasks touching peripheral state from outside the actor.** Arbitrary-thread entry
points hop in via `central.queue.async { central.assumeIsolated { ... } }` (see
`Peripheral+Notifications.swift`), never `Task { }` from outside. Actor-spawned
`Task { [weak self] in ... }` is allowed only when the task is stored somewhere cancellable (a
"ledgered site" — see `scheduleReconnect`, `startNotificationPump`).

`@unchecked Sendable` is forbidden; use `nonisolated(unsafe)` narrowly, as the codebase does.

### Every public API needs three things

1. **A DocC comment** on the declaration.
2. **A fake-backed unit test** against `FakeCentral`/`FakePeripheral`/`FakePeripheralManager`
   in `BLESwiftTestSupport` — Swift Testing, in `Tests/BLESwiftTests/`, using the helpers in
   `TestHelpers.swift`. No hardware, no third-party mocking library.
3. **A DocC catalog entry**: a mention in the article covering its area
   (`Sources/BLESwift/BLESwift.docc/*.md`) plus a `Topics` link in `BLESwift.md` for any new
   public type (or `BLESwiftCore.md` for a Core-only type).

### Error vocabulary

`Sources/BLESwiftCore/Errors/BLESwiftError.swift` is the single place errors are defined. Add
new cases there only, each with an `errorDescription` string, and add a line to
`Tests/BLESwiftTests/BLESwiftErrorTests.swift` if that file enumerates descriptions. Do not
introduce a second error type or throw a `NSError`/`CBError` through the public API.

### Logging

`import os` is forbidden in `Sources/`. Logging goes through the injected swift-log `Logger`
via `log(_:level:category:)` on `Central`.

### Comments

Keep comment style terse, matching the codebase.

## Pull requests

- **One topic per PR.** A bug fix, a feature, or a refactor — not a mix.
- **Add a `CHANGELOG.md` entry** under `## [Unreleased]`: new APIs under `### Added`, any
  change to the semantics of an existing public API under `### Changed`, bug fixes under
  `### Fixed`.
- **CI must be green** before review is requested, and stay green.
- **No force-pushes once review has started.** Push follow-up commits so reviewers can see
  what changed; squashing happens at merge.
- Don't delete, skip, or weaken an existing test to make a change pass. If a test fails
  because of your change, say so in the PR and explain why the new behavior is correct.

## License

By contributing, you agree that your contributions are licensed under the Apache License 2.0,
the same license that covers this project.
