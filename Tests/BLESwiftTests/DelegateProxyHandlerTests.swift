//
//  DelegateProxyHandlerTests.swift
//  BLESwiftTests
//

import CoreBluetooth
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing
import BLESwiftCore
@testable import BLESwift

/// Regression tests for #53. Each delegate proxy kept its handler as a function-typed `Mutex`
/// value, and every read wrapped the stored closure in two more reabstraction thunks
/// (swiftlang/swift#91348). A long-running scan with `allowDuplicates` reads it on every
/// event, so after some thousands of events delivering one overflowed the stack (SIGBUS).
/// Before the fix each test here crashed well inside its read or event count.
@Suite("Delegate proxy handlers")
struct DelegateProxyHandlerTests {

    @Test("CentralDelegateProxy.handler does not nest deeper per read")
    func centralProxyHandler() {
        let proxy = CentralDelegateProxy()
        let delivered = Mutex(0)
        proxy.handler = { _ in delivered.withLock { $0 += 1 } }
        for _ in 0..<200_000 { _ = proxy.handler }
        proxy.handler?(.didUpdateState(.poweredOn))
        #expect(delivered.withLock { $0 } == 1)
    }

    @Test("PeripheralDelegateProxy.handler does not nest deeper per read")
    func peripheralProxyHandler() {
        let proxy = PeripheralDelegateProxy()
        let delivered = Mutex(0)
        proxy.handler = { _ in delivered.withLock { $0 += 1 } }
        for _ in 0..<200_000 { _ = proxy.handler }
        proxy.handler?(.didReadRSSI(-40, error: nil))
        #expect(delivered.withLock { $0 } == 1)
    }

    #if os(iOS) || os(macOS)
    @Test("PeripheralManagerDelegateProxy.handler does not nest deeper per read")
    func peripheralManagerProxyHandler() {
        let proxy = PeripheralManagerDelegateProxy()
        let delivered = Mutex(0)
        proxy.handler = { _ in delivered.withLock { $0 += 1 } }
        for _ in 0..<200_000 { _ = proxy.handler }
        proxy.handler?(.didUpdateState(.poweredOn))
        #expect(delivered.withLock { $0 } == 1)
    }
    #endif

    /// The reporter's reproduction: a real `CBCentralManager` adopted by `Central`, with
    /// twenty thousand events pushed through its `eventHandler` on the callback queue.
    @Test("an adopted CBCentralManager delivers 20,000 events without overflowing")
    func adoptedManagerSurvivesManyEvents() async {
        let queue = DispatchQueue(label: "DelegateProxyHandlerTests.adopted")
        nonisolated(unsafe) let manager = CBCentralManager(delegate: nil, queue: queue)
        let central = Central(adopting: manager, callbackQueue: queue)
        let id = PeripheralIdentifier(uuid: UUID(), name: "issue-53")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                withExtendedLifetime(central) {
                    for _ in 0..<20_000 {
                        manager.eventHandler?(.didDisconnect(id, error: nil))
                    }
                }
                continuation.resume()
            }
        }
    }
}
