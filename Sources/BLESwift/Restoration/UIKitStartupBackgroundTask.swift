//
//  UIKitStartupBackgroundTask.swift
//  BLESwift
//

import Dispatch
import BLESwiftCompat17
import BLESwiftCore
#if os(iOS)
import UIKit
#endif

#if os(iOS)

/// The real conformance. It uses `UIApplication.beginBackgroundTask(withName:expirationHandler:)`
/// and `endBackgroundTask(_:)`. These are `NS_SWIFT_NONISOLATED`, but `UIApplication.shared`
/// itself is MainActor-isolated.
///
/// **MainActor access pattern:** A grep check bans `@MainActor` in `Sources/`, and `Central`
/// must never block on the main thread. So each `UIApplication.shared` access hops to the main
/// **queue** with `DispatchQueue.main.async` and enters MainActor isolation with
/// `MainActor.assumeIsolated`. This is safe, because the main queue *is* the MainActor's
/// executor.
///
/// `end()` can arrive before the asynchronous main-queue hop of `begin` runs. A `Mutex`-guarded
/// state machine resolves this race. `end()` marks the task `.ended`. The deferred block of
/// `begin` sees that state and ends the platform task that it just created, without storing it.
final class UIKitStartupBackgroundTask: StartupBackgroundTaskRunning {

    /// The lifecycle of the task, guarded as one unit by ``state``.
    private enum TaskState {
        /// `begin(onExpiration:)` did not run yet.
        case idle
        /// `begin(onExpiration:)` ran. The main-queue hop did not create the platform task yet.
        case beginning
        /// The platform task is live.
        case active(UIBackgroundTaskIdentifier)
        /// `end()` ran, or the expiration ended the task. This state is terminal.
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
            // Safe. The main queue is the MainActor's executor. See the type doc comment.
            MainActor.assumeIsolated {
                let identifier = UIApplication.shared.beginBackgroundTask(
                    withName: "BLESwift.BackgroundRestoration"
                ) {
                    // UIKit requires that the expiration handler ends the task. `end()` does that
                    // idempotently. `self` is captured strongly on purpose: UIKit holds the
                    // closure, so there is no cycle, and the runner must stay alive until the
                    // expiration or `end()`.
                    onExpiration()
                    self.end()
                }

                let orphaned: UIBackgroundTaskIdentifier? = self.state.withLock { current in
                    if case .ended = current {
                        // `end()` ran before this deferred block, so nobody wants the platform
                        // task that we just created.
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
            // Safe. The main queue is the MainActor's executor. See the type doc comment.
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
    }
}

#endif
