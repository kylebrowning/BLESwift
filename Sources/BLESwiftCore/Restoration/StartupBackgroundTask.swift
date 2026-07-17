//
//  StartupBackgroundTask.swift
//  BLESwiftCore
//

/// The seam over iOS's `UIApplication` background-task API protecting the **startup
/// restoration window** — the span from `Central.init` (restoration enabled) until
/// restoration completes or is ruled out — from the app being suspended mid-restoration.
///
/// A protocol (rather than direct `UIApplication` calls inside `Central`) for two reasons:
/// - **Testability**: SPM tests run on macOS with no UIKit/`UIApplication`; a fake
///   conformance lets tests drive `begin`/`end`/expiration and observe `Central`'s
///   reaction.
/// - **Isolation**: `UIApplication` is MainActor-isolated while `Central` is its own
///   actor; the UIKit conformance (`BLESwift`'s `UIKitStartupBackgroundTask`) contains the
///   documented main-queue hop so `Central` itself never touches MainActor state.
///
/// `package`, not `public`, this phase — see ``CentralManaging``. `UIKitStartupBackgroundTask`
/// (the real, UIKit-backed conformance) stays in the `BLESwift` module, since it imports
/// `UIKit`; only the CB-free seam and the no-op conformance live here.
package protocol StartupBackgroundTaskRunning: Sendable {

    /// Begins the platform background task. `onExpiration` fires (on an arbitrary
    /// thread/actor) if the system's background time runs out before ``end()`` — the
    /// conformance itself is responsible for also ending the underlying platform task on
    /// expiration, as UIKit requires. At most one begin per instance; later calls are
    /// no-ops.
    func begin(onExpiration: @escaping @Sendable () -> Void)

    /// Ends the platform background task. Idempotent; safe to call before ``begin(onExpiration:)``'s
    /// asynchronous platform work has completed (the conformance must resolve that race).
    func end()
}

/// The no-op conformance used whenever there is no platform background task to manage:
/// non-iOS platforms, iOS `Central`s created without restoration, adopted managers
/// (`Central(adopting:)` — the restoration window, if any, belonged to the manager's
/// previous owner), and test-backed `Central`s that don't inject a fake.
package final class NoOpStartupBackgroundTask: StartupBackgroundTaskRunning {
    package init() {}
    package func begin(onExpiration: @escaping @Sendable () -> Void) {}
    package func end() {}
}
