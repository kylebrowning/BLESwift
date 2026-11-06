//
//  StartupBackgroundTask.swift
//  BLESwiftCore
//

/// The seam over `UIApplication`'s background-task API on iOS. It keeps the app from suspending
/// during the startup restoration window. The window starts at `Central.init` with restoration
/// enabled. It ends when restoration completes or when BLESwift rules restoration out.
///
/// This is a protocol and not direct `UIApplication` calls inside `Central`, for two reasons:
/// - SPM tests run on macOS with no UIKit.
/// - `UIApplication` is MainActor-isolated, and `Central` is its own actor.
///
/// The UIKit conformance (`UIKitStartupBackgroundTask` in `BLESwift`) hops to the main queue, so
/// `Central` itself never touches MainActor state.
public protocol StartupBackgroundTaskRunning: Sendable {

    /// Begins the platform background task. `onExpiration` fires if the system's background time
    /// ends before ``end()``. An instance can begin at most once. Later calls do nothing.
    func begin(onExpiration: @escaping @Sendable () -> Void)

    /// Ends the platform background task. Idempotent.
    func end()
}

/// The conformance that does nothing. BLESwift uses it when there is no platform background task to
/// manage.
package final class NoOpStartupBackgroundTask: StartupBackgroundTaskRunning {
    package init() {}
    package func begin(onExpiration: @escaping @Sendable () -> Void) {}
    package func end() {}
}
