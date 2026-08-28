//
//  BackendRegistryTests.swift
//  BLESwiftTests
//

import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

/// `BackendRegistry` is process-global, so this suite is serialized and restores a nil
/// registry after every test.
@Suite("BackendRegistry", .serialized)
struct BackendRegistryTests {

    @Test("A registered central factory is consulted by Central(configuration:)")
    func centralUsesRegisteredFactory() async {
        let box = Mutex<FakeCentral?>(nil)
        BackendRegistry.centralFactory = { queue in
            let fake = FakeCentral(queue: queue, state: .poweredOn)
            box.withLock { $0 = fake }
            return fake
        }
        defer { BackendRegistry.centralFactory = nil }

        let central = Central()
        let fake = box.withLock { $0 }
        #expect(fake != nil)

        // The factory's fake is what the actor drives: a scripted state change reaches it.
        fake?.simulateStateChange(.poweredOff)
        await waitFor { central.state == .poweredOff }
        #expect(central.state == .poweredOff)
    }

    @Test("A registered peripheral-manager factory is consulted by PeripheralHost(configuration:)")
    func hostUsesRegisteredFactory() async {
        let box = Mutex<FakePeripheralManager?>(nil)
        BackendRegistry.peripheralManagerFactory = { queue in
            let fake = FakePeripheralManager(queue: queue, state: .poweredOn)
            box.withLock { $0 = fake }
            return fake
        }
        defer { BackendRegistry.peripheralManagerFactory = nil }

        let host = PeripheralHost()
        let fake = box.withLock { $0 }
        #expect(fake != nil)
        fake?.simulateStateChange(.poweredOff)
        await waitFor { host.state == .poweredOff }
        #expect(host.state == .poweredOff)
    }

    @Test("Clearing the registry returns nil factories")
    func clearing() {
        BackendRegistry.centralFactory = { queue in FakeCentral(queue: queue) }
        BackendRegistry.centralFactory = nil
        #expect(BackendRegistry.centralFactory == nil)
        BackendRegistry.peripheralManagerFactory = nil
        #expect(BackendRegistry.peripheralManagerFactory == nil)
    }
}
