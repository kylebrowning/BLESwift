//
//  ExecutorPolicy.swift
//  BLESwiftCompat16
//

import Foundation

/// Test-only knob that forces ``SerialQueueExecutor`` on every OS so the full suite can run
/// against the 16-tier code path on a newer simulator. Read once from the environment.
public enum ExecutorPolicy {
    /// `true` when the process environment has `BLESWIFT_FORCE_COMPAT16_EXECUTOR=1`.
    /// CI sets it for one simulator matrix cell and the Thread Sanitizer run.
    @_spi(Testing)
    public static let forceCompat16: Bool =
        ProcessInfo.processInfo.environment["BLESWIFT_FORCE_COMPAT16_EXECUTOR"] == "1"
}
