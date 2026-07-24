//
//  StartupBackgroundTask.swift
//  BLESwiftCore
//

/// The seam over iOS's `UIApplication` background-task API protecting the startup
/// restoration window (`Central.init` with restoration enabled until restoration completes
/// or is ruled out) from the app being suspended mid-restoration.
///
/// A protocol rather than direct `UIApplication` calls inside `Central`, since SPM tests
/// run on macOS with no UIKit, and `UIApplication` is MainActor-isolated while `Central` is
/// its own actor — the UIKit conformance (`BLESwift`'s `UIKitStartupBackgroundTask`)
/// contains the main-queue hop so `Central` itself never touches MainActor state.
public protocol StartupBackgroundTaskRunning: Sendable {

    /// Begins the platform background task. `onExpiration` fires if the system's
    /// background time runs out before ``end()``. At most one begin per instance; later
    /// calls are no-ops.
    func begin(onExpiration: @escaping @Sendable () -> Void)

    /// Ends the platform background task. Idempotent.
    func end()
}

/// The no-op conformance used whenever there is no platform background task to manage.
package final class NoOpStartupBackgroundTask: StartupBackgroundTaskRunning {
    package init() {}
    package func begin(onExpiration: @escaping @Sendable () -> Void) {}
    package func end() {}
}
