//
//  ExecutorSelectionTests.swift
//  BLESwiftTests
//

import Dispatch
import Testing
@_spi(Testing) import BLESwiftCompat16
import BLESwiftTestSupport
@testable import BLESwift

/// Pins which executor a `Central` built the ordinary way actually binds to, and reports it.
///
/// The `#expect` checks the selection against `ExecutorPolicy` from inside the process, but it
/// cannot catch the failure that matters most: `BLESWIFT_FORCE_COMPAT16_EXECUTOR` never
/// reaching the test process, in which case both sides read "not forced" and agree. So the
/// test also prints a `BLESwift executor:` line, and CI's forced simulator cell checks that
/// line from outside against what the cell asked for (#47).
@Suite("Executor selection")
struct ExecutorSelectionTests {

    @Test("Central binds the executor ExecutorPolicy selects, and reports which")
    func centralReportsItsExecutor() {
        let queue = DispatchQueue(label: "ExecutorSelectionTests.central")
        let central = Central(backend: FakeCentral(queue: queue), queue: queue)
        let usesCompat16 = central.executor.usesCompat16Executor
        print("BLESwift executor: [\(usesCompat16 ? "compat16" : "default")]")

        if #available(iOS 17, macOS 14, watchOS 10, tvOS 17, visionOS 1, *) {
            #expect(usesCompat16 == ExecutorPolicy.forceCompat16)
        } else {
            #expect(usesCompat16)
        }
    }
}
