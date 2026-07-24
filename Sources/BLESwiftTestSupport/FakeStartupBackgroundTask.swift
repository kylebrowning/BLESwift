//
//  FakeStartupBackgroundTask.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import Synchronization

/// A scriptable stand-in for `StartupBackgroundTaskRunning`; records the `begin`/`end`
/// lifecycle and lets you fire the captured expiration handler as UIKit would.
///
/// `Mutex`-guarded, not queue-confined like `FakeCentral`/`FakePeripheral`: the real
/// conformance is callable from any thread/actor, and this fake mirrors that.
public final class FakeStartupBackgroundTask: StartupBackgroundTaskRunning {

    private struct State {
        var beginCount = 0
        var endCount = 0
        var onExpiration: (@Sendable () -> Void)?
    }

    private let state = Mutex<State>(State())

    /// Creates a `FakeStartupBackgroundTask`.
    public init() {}

    /// How many times ``begin(onExpiration:)`` has been called.
    public var beginCount: Int {
        state.withLock { $0.beginCount }
    }

    /// How many times ``end()`` has been called.
    public var endCount: Int {
        state.withLock { $0.endCount }
    }

    /// Records the call and captures `onExpiration`, incrementing ``beginCount``.
    public func begin(onExpiration: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.beginCount += 1
            $0.onExpiration = onExpiration
        }
    }

    /// Records the call, incrementing ``endCount``.
    public func end() {
        state.withLock { $0.endCount += 1 }
    }

    /// Fires the expiration handler captured by ``begin(onExpiration:)``, as UIKit would
    /// when the app's background time runs out. A no-op if `begin` was never called.
    public func fireExpiration() {
        let handler = state.withLock { $0.onExpiration }
        handler?()
    }
}
