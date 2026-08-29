//
//  SimulatorLinkInstallTests.swift
//  BLESwiftLinkTests
//

import BLESwiftCore
import BLESwiftLink
import BLESwiftSimulatorLink
import Foundation
import Testing

#if os(macOS)
import BLESwift
import BLESwiftProvider
#endif

/// `SimulatorLink` mutates the process-wide `BackendRegistry`, so this suite is serialized
/// and every test restores an uninstalled state afterwards.
@Suite("SimulatorLink.install()", .serialized)
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

    private func makeProvider() async throws -> Provider {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
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

        let central = Central()
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        #expect(central.state == .poweredOn)

        let host = PeripheralHost()
        await waitFor(timeout: .seconds(5)) { host.state == .poweredOn }
        #expect(host.state == .poweredOn)

        await provider.stop()
    }

    @Test("isProviderReachable is true against a running provider and false against a closed port")
    func isProviderReachable() async throws {
        let provider = try await makeProvider()
        let reachable = await SimulatorLink.isProviderReachable(
            LinkEndpoint(host: "127.0.0.1", port: await provider.port)
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

    @Test("isProviderReachable returns false at once when its task is already cancelled")
    func isProviderReachableFromCancelledTask() async throws {
        let queue = DispatchQueue(label: "reachable.cancelled.listener")
        let listener = try LinkListener(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: 0),
            codec: .binaryPropertyList,
            queue: queue
        )
        // Silent again, and with a 30-second bound: nothing but the cancellation can end this
        // probe, so a prompt `false` proves the cancelled path resumes at all. It used to be
        // able to deadlock — the cancellation handler cancels the connection before the state
        // handler exists, the terminal state is published to nobody, and the group waits on a
        // continuation no one will ever resume.
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
#endif
}
