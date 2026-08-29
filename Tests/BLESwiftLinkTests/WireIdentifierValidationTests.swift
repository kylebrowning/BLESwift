//
//  WireIdentifierValidationTests.swift
//  BLESwiftLinkTests
//

import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftSimulatorLink
import Dispatch
import Foundation
import Synchronization
import Testing

#if os(macOS)
import BLESwiftProvider
#endif

/// The wire boundary's UUID rule: what it accepts, what it refuses, and what each end does
/// with a peer that sends a string BLESwift's identifiers could not hold.
@Suite("Wire identifier validation")
struct WireIdentifierValidationTests {

    /// Strings BLESwift's identifiers accept — 16-bit, 32-bit and 128-bit forms, either case.
    private static let valid = [
        "180D", "180d", "abcd", "ABCD", "0000",
        "0000180D", "0000180d", "DEADBEEF", "deadbeef",
        "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        "00000000-0000-0000-0000-000000000000",
    ]

    /// Strings they do not — and which would therefore trap if handed straight to one.
    private static let invalid = [
        "", "z", "zz", "not-a-uuid", "180",
        "180DD", "180G", "18 0D", "0000180", "0000180DD", "0000180G",
        "6BA7B810-9DAD-11D1-80B4-00C04FD430C",       // 35 characters
        "6BA7B810-9DAD-11D1-80B4-00C04FD430C88",     // 37 characters
        "6BA7B8109DAD-11D1-80B4-00C04FD430C8-",      // dashes in the wrong places
        "6BA7B810-9DAD-11D1-80B4-00C04FD430CG",      // a non-hex digit
        "6BA7B810_9DAD_11D1_80B4_00C04FD430C8",      // underscores, not dashes
        "０１８０",                                     // fullwidth digits: hex to Unicode, not to us
    ]

    @Test("The validator accepts exactly the strings BLESwift's identifiers accept")
    func validatorAgreesWithTheIdentifiers() throws {
        for uuid in Self.valid {
            #expect(WireIdentifierValidation.isValid(uuid), "\(uuid) should be valid")
            #expect(try WireIdentifierValidation.validated(uuid) == uuid)
            // The point of the whole exercise: a string the validator passes is one the
            // identifiers themselves normalize rather than trap on.
            #expect(ServiceIdentifier(uuid: uuid).uuidString == uuid.uppercased())
        }
    }

    @Test("The validator refuses every string an identifier would trap on")
    func validatorRefusesMalformedStrings() {
        for uuid in Self.invalid {
            #expect(!WireIdentifierValidation.isValid(uuid), "\(uuid) should be invalid")
            // Deliberately *not* passed to `ServiceIdentifier(uuid:)`: that call is what this
            // validator exists to keep from happening, and it would take the process down.
            #expect(throws: WireDecodingError.invalidIdentifier(uuid)) {
                try WireIdentifierValidation.validated(uuid)
            }
        }
    }

    @Test("Every wire conversion throws rather than trapping on a malformed identifier")
    func conversionsThrow() {
        #expect(throws: WireDecodingError.self) {
            try WireCharacteristicRef(service: "zz", uuid: "2A37").identifier
        }
        #expect(throws: WireDecodingError.self) {
            try WireCharacteristicRef(service: "180D", uuid: "zz").identifier
        }
        #expect(throws: WireDecodingError.self) {
            try WireDescriptorRef(service: "180D", characteristic: "2A37", uuid: "zz").identifier
        }
        #expect(throws: WireDecodingError.self) {
            try WireGATTService(uuid: "zz", isPrimary: true, characteristics: []).gattService
        }
        #expect(throws: WireDecodingError.self) {
            try WireGATTService(
                uuid: "180D",
                isPrimary: true,
                characteristics: [WireGATTCharacteristic(uuid: "zz", properties: 0, permissions: 0, value: nil)]
            ).gattService
        }
        #expect(throws: WireDecodingError.self) {
            try WireAdvertisement(
                localName: nil,
                serviceUUIDs: ["zz"],
                manufacturerData: nil,
                serviceData: nil,
                txPowerLevel: nil,
                isConnectable: nil,
                overflowServiceUUIDs: nil,
                solicitedServiceUUIDs: nil
            ).advertisementData
        }
        let central = WireSubscriber(id: UUID(), maximumUpdateValueLength: 180)
        let badRef = WireCharacteristicRef(service: "180D", uuid: "zz")
        #expect(throws: WireDecodingError.self) {
            try WireReadRequest(token: UUID(), central: central, characteristic: badRef, offset: 0).readRequest
        }
        #expect(throws: WireDecodingError.self) {
            try WireWriteRequest(
                token: UUID(),
                entries: [WireWriteEntry(central: central, characteristic: badRef, offset: 0, value: Data())]
            ).writeRequest
        }
    }

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are unreliable; the simulator-side path is covered by the
    // two-simulator E2E on real simulators.

    @Test("A provider that sends a malformed identifier loses its client's session")
    func clientDropsAProviderThatSendsAMalformedIdentifier() async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "wireidvalidation.client")
        let link = LinkCentral(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "test",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: link, queue: queue)
        await waitFor { central.state == .poweredOn }
        #expect(central.state == .poweredOn)
        #expect(provider.helloCount.withLock { $0 } == 1)

        // A discovery completion naming a service no `ServiceIdentifier` could hold. Before
        // the wire boundary validated it this took the *client* process down.
        provider.emit(.didDiscoverServices(peripheral: UUID(), services: ["not-a-uuid"], error: nil))

        // The client treats it as a provider fault: the session is dropped and redialed, so a
        // second hello reaches the provider.
        await waitFor(timeout: .seconds(5)) { provider.helloCount.withLock { $0 } >= 2 }
        #expect(provider.helloCount.withLock { $0 } >= 2)

        link.shutdown()
        provider.stop()
    }

#if os(macOS)
    @Test("A client that sends a malformed identifier loses its session, and no other")
    func providerClosesTheSessionThatSentAMalformedIdentifier() async throws {
        var configuration = ProviderConfiguration()
        configuration.endpoint = LinkEndpoint(host: "127.0.0.1", port: 0)
        let provider = Provider(configuration: configuration)
        try await provider.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: await provider.port)

        // An innocent bystander, to prove the provider closes one session and not the link.
        let bystanderQueue = DispatchSerialQueue(label: "wireidvalidation.bystander")
        let bystander = LinkCentral(
            endpoint: endpoint,
            queue: bystanderQueue,
            clientName: "bystander",
            retryInterval: .milliseconds(50)
        )
        let bystanderCentral = Central(backend: bystander, queue: bystanderQueue)
        await waitFor(timeout: .seconds(5)) { bystanderCentral.state == .poweredOn }
        #expect(bystanderCentral.state == .poweredOn)

        let connection = LinkConnection.connect(
            to: endpoint,
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "wireidvalidation.offender")
        )
        let accepted = Mutex(false)
        connection.onStateChange = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.send(.clientHello(ClientHello(
                protocolVersion: LinkProtocol.version,
                role: .central,
                clientName: "offender"
            )))
        }
        connection.onMessage = { message in
            guard case .serverHello(let hello) = message, hello.accepted else { return }
            accepted.withLock { $0 = true }
        }
        connection.start()
        await waitFor(timeout: .seconds(5)) { accepted.withLock { $0 } }
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 2 }
        #expect(await provider.sessionCount == 2)

        connection.send(.centralRequest(.discoverServices(peripheral: UUID(), services: ["zz"])))

        // The offender's session goes; the bystander's stays.
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 1 }
        #expect(await provider.sessionCount == 1)
        #expect(bystanderCentral.state == .poweredOn)

        connection.onStateChange = nil
        connection.onMessage = nil
        connection.cancel()
        bystander.shutdown()
        await waitFor(timeout: .seconds(5)) { await provider.sessionCount == 0 }
        #expect(await provider.sessionCount == 0)
        await provider.stop()
    }
#endif
#endif
}
