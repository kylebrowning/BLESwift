//
//  BackendRegistrySerializedTests.swift
//  BLESwiftLinkTests
//

import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftSimulatorLink
import BLESwiftTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

#if os(macOS)
import BLESwiftProvider
#endif

/// Every suite that touches the process-global `BackendRegistry` — or the default
/// `Central()` / `PeripheralHost()` initializers that consult it — lives here, nested inside
/// one serialized parent.
///
/// `.serialized` is **per-suite**, not per-process, and SwiftPM builds one test bundle for
/// every test target in the package, so two separate top-level serialized suites would still
/// run *each other's* tests in parallel and trample the registry between them. Nested suites
/// inherit their parent's serialization, so nesting both inside this one is what actually
/// serializes them against one another. Nothing else in either bundle may touch
/// `BackendRegistry` or those initializers.
@Suite("Backend registry", .serialized)
struct BackendRegistrySerializedTests {

    /// `BackendRegistry` is process-global, so this suite restores a nil registry after every
    /// test — and runs serialized with its sibling, by way of the parent above.
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
            #expect(BackendRegistry.centralFactory != nil)
            BackendRegistry.centralFactory = nil
            #expect(BackendRegistry.centralFactory == nil)
            BackendRegistry.peripheralManagerFactory = nil
            #expect(BackendRegistry.peripheralManagerFactory == nil)
        }
    }

    /// `SimulatorLink` mutates the process-wide `BackendRegistry`, so every test here restores
    /// an uninstalled state afterwards — and runs serialized with its sibling, by way of the
    /// parent above.
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

            // Twenty seconds, not the usual five: these backends are built by
            // `SimulatorLink.install` with the *production* retry interval of two seconds. The
            // session's opening burst absorbs the dials a loaded machine refuses outright
            // (`EADDRINUSE` from the local stack), but once that burst is spent every further
            // refusal costs a full two seconds. Widen the wait rather than add API to shorten the
            // interval: the interval is what ships, and it belongs in what is tested.
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
            // A budget, not a deadline for one dial: on a machine running several test bundles at
            // once a loopback dial can fail outright (`EADDRINUSE` from the local stack), which
            // says nothing about the provider — the probe retries inside this window.
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
            let queue = DispatchSerialQueue(label: "silent-listener")
            let listener = try LinkListener(
                endpoint: LinkEndpoint(host: "127.0.0.1", port: 0),
                codec: .binaryPropertyList,
                queue: queue
            )
            // Deliberately no `onConnection` handler: every accepted connection is started (so the
            // TCP handshake completes and the client sees `.ready`) but nothing is ever sent back —
            // the "connected but silent" case a refused or black-holed port doesn't exercise.
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
            // The port is taken and released, so the first dials have nowhere to land; the
            // provider binds it a moment later. A probe that gave up on its first failed dial
            // would report false here.
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
            // Silent again, and with a 30-second bound: nothing but the cancellation can end this
            // probe, so a prompt `false` proves the cancelled path resumes at all. Cancelled
            // before the probe has run a line, which is its own case — the loop must notice the
            // flag rather than dial once and wait out the timeout.
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
            // The path the cancellation handler exists for: the probe is *inside* its dial, on a
            // connection that reached `.ready` and is waiting on a hello that will never come.
            // Cancelling then used to be able to deadlock — the handler cancels the connection
            // before the state handler exists, the terminal state is published to nobody, and the
            // group waits on a continuation no one will ever resume. The connections are held
            // (the listener does not retain what it accepts) so the probe keeps waiting on a live,
            // silent socket rather than one that died under it.
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
            // Gate on the listener actually accepting: the probe has reached `.ready` and sent its
            // hello, so the cancellation lands mid-dial rather than before the probe started.
            await waitFor(timeout: .seconds(5)) { accepted.withLock { !$0.isEmpty } }
            #expect(accepted.withLock { !$0.isEmpty })

            let start = ContinuousClock.now
            probe.cancel()
            #expect(try await bounded(seconds: 1) { await probe.value } == false)
            #expect(ContinuousClock.now - start < .seconds(1))
        }
#endif
    }
}
