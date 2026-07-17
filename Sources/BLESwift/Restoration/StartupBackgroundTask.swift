//
//  StartupBackgroundTask.swift
//  BLESwift
//

import Dispatch
import Synchronization
#if os(iOS)
import UIKit
#endif

/// The seam over iOS's `UIApplication` background-task API protecting the **startup
/// restoration window** — the span from `Central.init` (restoration enabled) until
/// restoration completes or is ruled out — from the app being suspended mid-restoration.
///
/// A protocol (rather than direct `UIApplication` calls inside `Central`) for two reasons:
/// - **Testability**: SPM tests run on macOS with no UIKit/`UIApplication`; a fake
///   conformance lets tests drive `begin`/`end`/expiration and observe `Central`'s
///   reaction (the orchestrator-directed seam).
/// - **Isolation**: `UIApplication` is MainActor-isolated while `Central` is its own
///   actor; the UIKit conformance below contains the (documented) main-queue hop so
///   `Central` itself never touches MainActor state.
protocol StartupBackgroundTaskRunning: Sendable {

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
final class NoOpStartupBackgroundTask: StartupBackgroundTaskRunning {
    func begin(onExpiration: @escaping @Sendable () -> Void) {}
    func end() {}
}

#if os(iOS)

/// The real conformance, backed by `UIApplication.beginBackgroundTask(withName:expirationHandler:)`
/// / `endBackgroundTask(_:)` (verified current, non-deprecated API in the iOS 27 SDK; both
/// are `NS_SWIFT_NONISOLATED`, but `UIApplication.shared` itself is MainActor-isolated).
///
/// **MainActor access pattern (documented per the plan's isolation note):** `@MainActor`
/// annotations are grep-banned in `Sources/`, and `Central` must never block on the main
/// thread — so every `UIApplication.shared` access here hops onto the main **queue** via
/// `DispatchQueue.main.async` and then re-enters MainActor isolation with
/// `MainActor.assumeIsolated`, which is sound because the main queue *is* the MainActor's
/// executor (the exact same queue-identity argument `CentralDelegateProxy` makes for
/// `Central`'s own executor). The begin therefore lands asynchronously — microseconds
/// after `Central.init` — which is safe in practice:
/// the app is executing its launch sequence on the main thread at that moment and cannot
/// be suspended mid-launch.
///
/// The `begin`/`end` race (an `end()` arriving before `begin`'s asynchronous main-queue
/// hop has run) is resolved by the `Mutex`-guarded state machine below: `end()` marks the
/// task `.ended`, and `begin`'s deferred main-queue block observes that and immediately
/// ends the just-created platform task instead of storing it.
final class UIKitStartupBackgroundTask: StartupBackgroundTaskRunning {

    /// The task's lifecycle, guarded as one unit by ``state``.
    private enum TaskState {
        /// `begin(onExpiration:)` not yet called.
        case idle
        /// `begin(onExpiration:)` called; the main-queue hop hasn't created the platform
        /// task yet.
        case beginning
        /// The platform task is live.
        case active(UIBackgroundTaskIdentifier)
        /// `end()` was called (or expiration self-ended). Terminal.
        case ended
    }

    private let state = Mutex<TaskState>(.idle)

    func begin(onExpiration: @escaping @Sendable () -> Void) {
        let shouldBegin = state.withLock { current -> Bool in
            guard case .idle = current else { return false }
            current = .beginning
            return true
        }
        guard shouldBegin else { return }

        DispatchQueue.main.async {
            // Sound: the main queue is the MainActor's executor — see the type doc comment.
            MainActor.assumeIsolated {
                let identifier = UIApplication.shared.beginBackgroundTask(
                    withName: "BLESwift.BackgroundRestoration"
                ) {
                    // UIKit calls this on the main thread when background time runs out.
                    // UIKit requires the task to be ended from its expiration handler;
                    // `end()` below does that (idempotently), after the caller's own
                    // reaction has been kicked off. `self` is captured strongly —
                    // deliberately: the expiration handler is held by UIKit (not by this
                    // instance, so no cycle), and the runner must stay alive until
                    // expiration or `end()` so the platform task can always be ended.
                    onExpiration()
                    self.end()
                }

                let orphaned: UIBackgroundTaskIdentifier? = self.state.withLock { current in
                    if case .ended = current {
                        // `end()` raced ahead of this deferred block — the platform task
                        // just created is already unwanted.
                        return identifier
                    }
                    current = .active(identifier)
                    return nil
                }
                if let orphaned, orphaned != .invalid {
                    UIApplication.shared.endBackgroundTask(orphaned)
                }
            }
        }
    }

    func end() {
        let identifier: UIBackgroundTaskIdentifier? = state.withLock { current in
            defer { current = .ended }
            if case .active(let identifier) = current {
                return identifier
            }
            return nil
        }
        guard let identifier, identifier != .invalid else { return }

        DispatchQueue.main.async {
            // Sound: the main queue is the MainActor's executor — see the type doc comment.
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
    }
}

#endif
