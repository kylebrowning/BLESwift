//
//  FakeStartupBackgroundTask.swift
//  BLESwiftTestSupport
//

import BLESwiftCore
import BLESwiftCompat17

/// A scriptable stand-in for `StartupBackgroundTaskRunning`. It records the `begin` and `end` calls
/// and lets you fire the captured expiration handler, as UIKit does.
///
/// A `Mutex` guards it. Unlike `FakeCentral` and `FakePeripheral`, no queue confines it. The real
/// conformance can be called from any thread or actor, and this fake mirrors that.
public final class FakeStartupBackgroundTask: StartupBackgroundTaskRunning {

    private struct State {
        var beginCount = 0
        var endCount = 0
        var onExpiration: (@Sendable () -> Void)?
    }

    private let state = Mutex<State>(State())

    /// Creates a `FakeStartupBackgroundTask`.
    public init() {}

    /// The number of calls to ``begin(onExpiration:)``.
    public var beginCount: Int {
        state.withLock { $0.beginCount }
    }

    /// The number of calls to ``end()``.
    public var endCount: Int {
        state.withLock { $0.endCount }
    }

    /// Records the call and captures `onExpiration`. It increments ``beginCount``.
    public func begin(onExpiration: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.beginCount += 1
            $0.onExpiration = onExpiration
        }
    }

    /// Records the call. It increments ``endCount``.
    public func end() {
        state.withLock { $0.endCount += 1 }
    }

    /// Fires the expiration handler that ``begin(onExpiration:)`` captured, as UIKit does when the
    /// app's background time ends. If `begin` was never called, it does nothing.
    public func fireExpiration() {
        let handler = state.withLock { $0.onExpiration }
        handler?()
    }
}
