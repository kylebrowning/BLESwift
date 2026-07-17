//
//  FakeStartupBackgroundTask.swift
//  BLESwiftTests
//

import Synchronization
@testable import BLESwift

/// A scriptable stand-in for the UIKit-backed startup background task (the
/// `StartupBackgroundTaskRunning` seam): SPM tests run on macOS with no
/// `UIApplication`, so this fake records the `begin`/`end` lifecycle and lets a test
/// fire the captured expiration handler exactly as UIKit would when background time
/// runs out.
///
/// `Mutex`-guarded (not queue-confined like `FakeCentral`/`FakePeripheral`): the real
/// UIKit conformance is callable from any thread/actor — `begin` from `Central.init`,
/// `end` from the actor, expiration from the main thread — and this fake mirrors that
/// contract.
final class FakeStartupBackgroundTask: StartupBackgroundTaskRunning {

    private struct State {
        var beginCount = 0
        var endCount = 0
        var onExpiration: (@Sendable () -> Void)?
    }

    private let state = Mutex<State>(State())

    /// How many times ``begin(onExpiration:)`` has been called.
    var beginCount: Int {
        state.withLock { $0.beginCount }
    }

    /// How many times ``end()`` has been called.
    var endCount: Int {
        state.withLock { $0.endCount }
    }

    func begin(onExpiration: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.beginCount += 1
            $0.onExpiration = onExpiration
        }
    }

    func end() {
        state.withLock { $0.endCount += 1 }
    }

    /// Fires the expiration handler captured by ``begin(onExpiration:)``, as UIKit would
    /// when the app's background time runs out. A no-op if `begin` was never called.
    func fireExpiration() {
        let handler = state.withLock { $0.onExpiration }
        handler?()
    }
}
