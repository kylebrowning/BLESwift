//
//  BackendRegistrySerializedTests.swift
//  BLESwiftLinkTests
//

import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftSimulatorLink
import BLESwiftTestSupport
import BLESwiftVirtualRadio
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

#if os(macOS)
import BLESwiftProvider
#endif

/// Every suite that touches the process-global `BackendRegistry` lives here, including those that
/// use the default `Central()` and `PeripheralHost()` initializers.
///
/// `.serialized` applies to one suite, not to the process, and SwiftPM runs all test targets in one
/// bundle. Nesting both suites here lets the parent serialize them against each other. No other
/// test may touch `BackendRegistry`.
@Suite("Backend registry", .serialized)
struct BackendRegistrySerializedTests {

    /// `BackendRegistry` is process-global, so this suite restores a nil registry after every test.
    @Suite("BackendRegistry")
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

        @Test("setFactories replaces both factories in one call, each independently (#70)")
        func setFactoriesReplacesBoth() {
            defer { BackendRegistry.setFactories(central: nil, peripheralManager: nil) }
            let queue = DispatchQueue(label: "BackendRegistryTests.setFactories")

            BackendRegistry.setFactories(
                central: { queue in FakeCentral(queue: queue) },
                peripheralManager: { queue in FakePeripheralManager(queue: queue) }
            )
            #expect(BackendRegistry.centralFactory?(queue) is FakeCentral)
            #expect(BackendRegistry.peripheralManagerFactory?(queue) is FakePeripheralManager)

            // Each slot takes exactly what the call names: `nil` clears it, and a factory replaces
            // it.
            BackendRegistry.setFactories(central: nil, peripheralManager: { queue in FakePeripheralManager(queue: queue) })
            #expect(BackendRegistry.centralFactory == nil)
            #expect(BackendRegistry.peripheralManagerFactory != nil)

            BackendRegistry.setFactories(central: { queue in FakeCentral(queue: queue) }, peripheralManager: nil)
            #expect(BackendRegistry.centralFactory != nil)
            #expect(BackendRegistry.peripheralManagerFactory == nil)

            BackendRegistry.setFactories(central: nil, peripheralManager: nil)
            #expect(BackendRegistry.centralFactory == nil)
            #expect(BackendRegistry.peripheralManagerFactory == nil)
        }

        @Test("Clearing the registry returns nil factories")
        func clearing() {
            BackendRegistry.centralFactory = { queue in FakeCentral(queue: queue) }
            #expect(BackendRegistry.centralFactory != nil)
            BackendRegistry.centralFactory = nil
            #expect(BackendRegistry.centralFactory == nil)
            BackendRegistry.peripheralManagerFactory = nil
            #expect(BackendRegistry.peripheralManagerFactory == nil)
        }

        /// Regression test for #53: each read of a function-typed `Mutex` value added two
        /// reabstraction thunks, so a factory read many times overflowed the stack.
        @Test("Reading the factories repeatedly does not nest them deeper (#53)")
        func repeatedReadsDoNotNest() {
            BackendRegistry.centralFactory = { queue in FakeCentral(queue: queue) }
            BackendRegistry.peripheralManagerFactory = { queue in FakePeripheralManager(queue: queue) }
            defer {
                BackendRegistry.centralFactory = nil
                BackendRegistry.peripheralManagerFactory = nil
            }
            for _ in 0..<200_000 {
                _ = BackendRegistry.centralFactory
                _ = BackendRegistry.peripheralManagerFactory
            }
            let queue = DispatchQueue(label: "BackendRegistryTests.repeatedReadsDoNotNest")
            #expect(BackendRegistry.centralFactory?(queue) is FakeCentral)
            #expect(BackendRegistry.peripheralManagerFactory?(queue) is FakePeripheralManager)
        }
    }

    /// `SimulatorLink` changes the process-wide `BackendRegistry`, so every test here restores the
    /// uninstalled state afterwards.
    @Suite("SimulatorLink.install()")
    struct SimulatorLinkInstallTests {

        @Test("install(endpoint:) registers both factories and reports the given endpoint")
        func installRegistersFactories() {
            let endpoint = LinkEndpoint(host: "127.0.0.1", port: 12345)
            SimulatorLink.install(endpoint: endpoint)
            defer { SimulatorLink.uninstall() }

            #expect(SimulatorLink.isInstalled)
            #expect(SimulatorLink.endpoint == endpoint)
            #expect(BackendRegistry.centralFactory != nil)
            #expect(BackendRegistry.peripheralManagerFactory != nil)
        }

        @Test("uninstall() clears both factories and the resolved endpoint")
        func uninstallClearsFactories() {
            SimulatorLink.install(endpoint: LinkEndpoint(host: "127.0.0.1", port: 12345))
            SimulatorLink.uninstall()

            #expect(!SimulatorLink.isInstalled)
            #expect(SimulatorLink.endpoint == nil)
            #expect(BackendRegistry.centralFactory == nil)
            #expect(BackendRegistry.peripheralManagerFactory == nil)
        }

        @Test("install() with no endpoint resolves from the environment, or .default")
        func installResolvesDefaultEndpoint() {
            SimulatorLink.install()
            defer { SimulatorLink.uninstall() }

            let expected = LinkEndpoint.fromEnvironment() ?? .default
            #expect(SimulatorLink.endpoint == expected)
        }

        @Test("A second install replaces the first with the new endpoint")
        func secondInstallReplacesFirst() {
            SimulatorLink.install(endpoint: LinkEndpoint(host: "127.0.0.1", port: 1))
            defer { SimulatorLink.uninstall() }

            let secondEndpoint = LinkEndpoint(host: "127.0.0.1", port: 2)
            SimulatorLink.install(endpoint: secondEndpoint)

            #expect(SimulatorLink.endpoint == secondEndpoint)
        }

#if os(macOS)
        // Everything below dials a provider over loopback, so `#if os(macOS)` excludes it from the
        // iOS-simulator run.
        private static let fixtureJSON = """
        { "devices": [] }
        """

        private func makeProvider(port: UInt16 = 0) async throws -> Provider {
            var configuration = ProviderConfiguration()
            configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: port)
            configuration.fixtures = try FixtureDocument.parse(Data(Self.fixtureJSON.utf8)).devices
            let provider = Provider(configuration: configuration)
            try await provider.start()
            return provider
        }

        @Test("A default-initialized Central/PeripheralHost reaches poweredOn through an installed link")
        func defaultInitializersUseInstalledLink() async throws {
            let provider = try await makeProvider()
            SimulatorLink.install(endpoint: LinkEndpoint(host: "127.0.0.1", port: await provider.port))
            defer { SimulatorLink.uninstall() }

            // The wait is twenty seconds, not five. The backends use the production two-second
            // retry interval, and each dial that a loaded machine refuses (`EADDRINUSE`) costs one
            // interval. The test must include the shipped interval.
            let central = Central()
            await waitFor(timeout: .seconds(20)) { central.state == .poweredOn }
            #expect(central.state == .poweredOn)

            let host = PeripheralHost()
            await waitFor(timeout: .seconds(20)) { host.state == .poweredOn }
            #expect(host.state == .poweredOn)

            await provider.stop()
        }

        @Test("isProviderReachable is true against a running provider and false against a closed port")
        func isProviderReachable() async throws {
            let provider = try await makeProvider()
            // A budget, not a deadline for one dial. A loopback dial can fail outright
            // (`EADDRINUSE`) on a loaded machine, so the probe retries inside this window.
            let reachable = await SimulatorLink.isProviderReachable(
                LinkEndpoint(host: "127.0.0.1", port: await provider.port),
                timeout: .seconds(10)
            )
            #expect(reachable)

            let start = ContinuousClock.now
            let unreachable = await SimulatorLink.isProviderReachable(
                LinkEndpoint(host: "127.0.0.1", port: 1),
                timeout: .milliseconds(500)
            )
            #expect(!unreachable)
            #expect(ContinuousClock.now - start < .seconds(1))

            await provider.stop()
        }

        @Test("isProviderReachable times out promptly against a listener that accepts but never replies")
        func isProviderReachableTimesOutOnSilentListener() async throws {
            let queue = DispatchQueue(label: "silent-listener")
            let listener = try LinkListener(
                endpoint: LinkEndpoint(host: "127.0.0.1", port: 0),
                codec: .binaryPropertyList,
                queue: queue
            )
            // No `onConnection` handler: the TCP handshake completes and the client sees `.ready`,
            // but the provider never replies. This is the "connected but silent" case.
            try await listener.start()
            defer { listener.cancel() }

            let start = ContinuousClock.now
            let reachable = await SimulatorLink.isProviderReachable(
                LinkEndpoint(host: "127.0.0.1", port: listener.port),
                timeout: .milliseconds(300)
            )
            let elapsed = ContinuousClock.now - start

            #expect(!reachable)
            #expect(elapsed < .seconds(1))
        }

        @Test("isProviderReachable keeps trying until a provider appears within its timeout")
        func isProviderReachableWaitsForALateProvider() async throws {
            // The test releases the port, so the first dials have nowhere to land. The provider
            // binds it later. A probe that gave up after one failed dial would report false.
            let port = try closedPort()
            let appearing = Task {
                try await Task.sleep(for: .milliseconds(300))
                return try await makeProvider(port: port)
            }
            let reachable = await SimulatorLink.isProviderReachable(
                LinkEndpoint(host: "127.0.0.1", port: port),
                timeout: .seconds(10)
            )
            let provider = try await bounded(seconds: 10) { try await appearing.value }
            #expect(reachable)
            await provider.stop()
        }

        @Test("isProviderReachable returns false at once when its task is already cancelled")
        func isProviderReachableFromCancelledTask() async throws {
            let queue = DispatchQueue(label: "reachable.cancelled.listener")
            let listener = try LinkListener(
                endpoint: LinkEndpoint(host: "127.0.0.1", port: 0),
                codec: .binaryPropertyList,
                queue: queue
            )
            // The listener is silent and the bound is 30 seconds, so only cancellation can end the
            // probe. Cancelling before the probe runs a line is its own case: the loop must notice
            // the flag instead of dialing once.
            try await listener.start()
            defer { listener.cancel() }

            let probe = Task {
                await SimulatorLink.isProviderReachable(
                    LinkEndpoint(host: "127.0.0.1", port: listener.port),
                    timeout: .seconds(30)
                )
            }
            probe.cancel()

            #expect(try await bounded(seconds: 1) { await probe.value } == false)
        }

        @Test("isProviderReachable returns false promptly when cancelled mid-probe")
        func isProviderReachableCancelledMidProbe() async throws {
            let queue = DispatchQueue(label: "reachable.cancelled.midprobe")
            let listener = try LinkListener(
                endpoint: LinkEndpoint(host: "127.0.0.1", port: 0),
                codec: .binaryPropertyList,
                queue: queue
            )
            // The probe is inside its dial, on a connection that reached `.ready` and waits for a
            // hello that never comes. Cancellation could deadlock here if the handler cancelled the
            // connection before the state handler existed, so the terminal state would go to
            // nobody. The test holds the connections because the listener does not retain them.
            let accepted = Mutex<[LinkConnection]>([])
            listener.onConnection = { connection in
                accepted.withLock { $0.append(connection) }
            }
            try await listener.start()
            defer {
                listener.cancel()
                for connection in accepted.withLock({ $0 }) { connection.cancel() }
            }

            let probe = Task {
                await SimulatorLink.isProviderReachable(
                    LinkEndpoint(host: "127.0.0.1", port: listener.port),
                    timeout: .seconds(30)
                )
            }
            // Wait until the listener accepts, so the cancellation lands mid-dial. This gate is
            // setup and is generous under load. The sub-second bound below is the assertion.
            await waitFor(timeout: .seconds(30)) { accepted.withLock { !$0.isEmpty } }
            #expect(accepted.withLock { !$0.isEmpty })

            let start = ContinuousClock.now
            probe.cancel()
            #expect(try await bounded(seconds: 1) { await probe.value } == false)
            #expect(ContinuousClock.now - start < .seconds(1))
        }
#endif
    }

    /// `VirtualRadio.install(_:)` also changes the process-wide `BackendRegistry`, so every test
    /// restores the uninstalled state. No test here dials a socket, so this suite runs on every
    /// platform.
    @Suite("VirtualRadio.install(_:)")
    struct VirtualRadioInstallTests {

        private static let service = ServiceIdentifier(uuid: "180D")
        private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)

        /// A device that answers no dynamic GATT traffic. Its one characteristic has a static value
        /// that the radio serves itself.
        private struct StaticHandler: VirtualDeviceHandler {
            func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
                .failure(.unlikelyError)
            }

            func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
                .failure(.unlikelyError)
            }

            func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
        }

        private static func device(name: String) -> VirtualDevice {
            VirtualDevice(
                descriptor: VirtualDeviceDescriptor(
                    name: name,
                    advertisement: AdvertisementData(localName: name, serviceUUIDs: [service], isConnectable: true),
                    services: [
                        GATTService(identifier: service, characteristics: [
                            GATTCharacteristic(
                                identifier: measurement,
                                properties: [.read],
                                permissions: [.readable],
                                value: Data([0, 72])
                            )
                        ])
                    ]
                ),
                handler: StaticHandler()
            )
        }

        @Test("After install, Central() scans, connects to, and reads a device registered on the radio")
        func centralUsesInstalledRadio() async throws {
            let radio = VirtualRadio()
            _ = await radio.register(Self.device(name: "Installed HRM"))
            VirtualRadio.install(radio)
            defer { VirtualRadio.uninstall() }
            #expect(VirtualRadio.installed === radio)

            let central = Central()
            await waitFor { central.state == .poweredOn }
            #expect(central.state == .poweredOn)

            var found: Discovery?
            for try await event in await central.scan(services: [Self.service], timeout: .seconds(5)) {
                if case .discovered(let discovery) = event { found = discovery; break }
            }
            let discovery = try #require(found)
            #expect(discovery.advertisement.localName == "Installed HRM")

            let peripheral = try await central.connect(discovery.peripheral)
            let value: Data = try await peripheral.read(from: Self.measurement)
            #expect(value == Data([0, 72]))
            try await central.disconnect(peripheral.id)
        }

        @Test("After install, PeripheralHost() publishes and advertises, and a central on the radio discovers it")
        func hostUsesInstalledRadio() async throws {
            let radio = VirtualRadio()
            VirtualRadio.install(radio)
            defer { VirtualRadio.uninstall() }

            let host = PeripheralHost()
            await waitFor { host.state == .poweredOn }
            #expect(host.state == .poweredOn)
            try await host.add(GATTService(identifier: Self.service, characteristics: [
                GATTCharacteristic(identifier: Self.measurement, properties: [.read], permissions: [.readable])
            ]))
            try await host.startAdvertising(
                PeripheralAdvertisement(localName: "Installed Host", serviceUUIDs: [Self.service])
            )
            #expect(host.isAdvertising)

            let queue = DispatchQueue(label: "VirtualRadioInstallTests.central")
            let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
            await waitFor { central.state == .poweredOn }

            var found: Discovery?
            for try await event in await central.scan(services: [Self.service], timeout: .seconds(5)) {
                if case .discovered(let discovery) = event { found = discovery; break }
            }
            #expect(found?.advertisement.localName == "Installed Host")
        }

        @Test("install/uninstall leave the registry and installed agreeing (#70)")
        func installIsConsistent() {
            let radio = VirtualRadio()
            VirtualRadio.install(radio)
            defer { VirtualRadio.uninstall() }

            let queue = DispatchQueue(label: "VirtualRadioInstallTests.consistent")
            #expect(VirtualRadio.installed === radio)
            #expect(BackendRegistry.centralFactory?(queue) is VirtualCentralBackend)
            #expect(BackendRegistry.peripheralManagerFactory?(queue) is VirtualPeripheralManagerBackend)

            let replacement = VirtualRadio()
            VirtualRadio.install(replacement)
            #expect(VirtualRadio.installed === replacement)
            #expect(BackendRegistry.centralFactory?(queue) is VirtualCentralBackend)
            #expect(BackendRegistry.peripheralManagerFactory?(queue) is VirtualPeripheralManagerBackend)

            VirtualRadio.uninstall()
            #expect(VirtualRadio.installed == nil)
            #expect(BackendRegistry.centralFactory == nil)
            #expect(BackendRegistry.peripheralManagerFactory == nil)
        }

        @Test("uninstall() clears both factories and installed, and is safe to call twice")
        func uninstallClears() {
            let radio = VirtualRadio()
            VirtualRadio.install(radio)
            #expect(VirtualRadio.installed === radio)
            #expect(BackendRegistry.centralFactory != nil)
            #expect(BackendRegistry.peripheralManagerFactory != nil)

            VirtualRadio.uninstall()
            VirtualRadio.uninstall()
            #expect(VirtualRadio.installed == nil)
            #expect(BackendRegistry.centralFactory == nil)
            #expect(BackendRegistry.peripheralManagerFactory == nil)
        }
    }
}
