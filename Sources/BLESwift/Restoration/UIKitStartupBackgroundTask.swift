//
//  UIKitStartupBackgroundTask.swift
//  BLESwift
//

import Dispatch
import Synchronization
import BLESwiftCore
#if os(iOS)
import UIKit
#endif

#if os(iOS)

/// The real conformance, backed by `UIApplication.beginBackgroundTask(withName:expirationHandler:)`
/// / `endBackgroundTask(_:)` (`NS_SWIFT_NONISOLATED`, but `UIApplication.shared` itself is
/// MainActor-isolated).
///
/// **MainActor access pattern:** `@MainActor` is grep-banned in `Sources/`, and `Central`
/// must never block on the main thread — so every `UIApplication.shared` access here hops
/// onto the main **queue** via `DispatchQueue.main.async` and re-enters MainActor isolation
/// with `MainActor.assumeIsolated`, sound because the main queue *is* the MainActor's
/// executor.
///
/// The `begin`/`end` race (an `end()` arriving before `begin`'s asynchronous main-queue hop
/// has run) is resolved by the `Mutex`-guarded state machine below: `end()` marks the task
/// `.ended`, and `begin`'s deferred main-queue block observes that and immediately ends the
/// just-created platform task instead of storing it.
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
                    // UIKit requires the task to be ended from its expiration handler;
                    // `end()` does that idempotently. `self` is captured strongly,
                    // deliberately: no cycle (UIKit holds the closure), and the runner
                    // must stay alive until expiration or `end()`.
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
