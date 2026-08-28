//
//  LinkTestHelpers.swift
//  BLESwiftLinkTests
//

import Foundation

/// Polls `condition` every 5 ms until it is `true` or `timeout` elapses. Never throws —
/// callers assert on the observable state afterwards, so a timeout surfaces as a normal
/// `#expect` failure with the real values in it.
func waitFor(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
