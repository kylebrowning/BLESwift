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

    @Test("Advertisement service data keys that collide once normalized are refused")
    func duplicateServiceDataKeysThrow() throws {
        // `"180d"` and `"180D"` are two keys on the wire and one `ServiceIdentifier` here.
        // Before this was refused, building the converted dictionary trapped.
        #expect(throws: WireDecodingError.duplicateIdentifier("180D")) {
            try Self.advertisement(serviceData: ["180d": Data([1]), "180D": Data([2])]).advertisementData
        }

        // Keys that are genuinely distinct still convert, in either case.
        let data = try Self.advertisement(serviceData: ["180d": Data([1]), "181A": Data([2])]).advertisementData
        #expect(data.serviceData?.count == 2)
        #expect(data.serviceData?[ServiceIdentifier(uuid: "180D")] == Data([1]))
        #expect(data.serviceData?[ServiceIdentifier(uuid: "181A")] == Data([2]))

        // A malformed key is still the invalid-identifier violation, not the duplicate one.
        #expect(throws: WireDecodingError.invalidIdentifier("zz")) {
            try Self.advertisement(serviceData: ["zz": Data()]).advertisementData
        }
    }

    /// An otherwise-empty advertisement carrying only `serviceData`.
    private static func advertisement(serviceData: [String: Data]) -> WireAdvertisement {
        WireAdvertisement(
            localName: nil,
            serviceUUIDs: nil,
            manufacturerData: nil,
            serviceData: serviceData,
            txPowerLevel: nil,
            isConnectable: nil,
            overflowServiceUUIDs: nil,
            solicitedServiceUUIDs: nil
        )
    }

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are unreliable; the simulator-side path is covered by the
    // two-simulator E2E on real simulators.

    @Test("Case-variant duplicates in a discovered-characteristics event collapse to one")
    func duplicateDiscoveredCharacteristicsCollapse() async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "wireidvalidation.duplicates")
        let link = LinkCentral(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "test",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: link, queue: queue)
        defer { provider.stop(); link.shutdown() }
        await waitFor { central.state == .poweredOn }

        let identifier = UUID()
        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: identifier, name: nil)) }
        await waitFor { !provider.requests.withLock { $0 }.isEmpty }
        provider.emit(.didConnect(
            peripheral: identifier,
            name: nil,
            maximumWriteWithResponse: 512,
            maximumWriteWithoutResponse: 20
        ))
        let peripheral = try await bounded { try await connectTask.value }

        let servicesTask = Task { try await peripheral.discoverServices() }
        await waitFor { provider.requests.withLock { $0 }.contains(.discoverServices(peripheral: identifier, services: nil)) }
        provider.emit(.didDiscoverServices(peripheral: identifier, services: ["180D"], error: nil))
        #expect(try await bounded { try await servicesTask.value } == [ServiceIdentifier(uuid: "180D")])

        // The provider reports the same characteristic twice, differing only in case. The
        // mirror cache is keyed by `CharacteristicIdentifier`, which normalizes both to one:
        // the client must fold them together rather than trap building the cache.
        let characteristicsTask = Task { try await peripheral.discoverCharacteristics(for: ServiceIdentifier(uuid: "180D")) }
        await waitFor {
            provider.requests.withLock { $0 }.contains(
                .discoverCharacteristics(peripheral: identifier, service: "180D", characteristics: nil)
            )
        }
        provider.emit(.didDiscoverCharacteristics(
            peripheral: identifier,
            service: "180D",
            characteristics: [
                WireDiscoveredCharacteristic(uuid: "2a37", properties: CharacteristicProperties([.read]).rawValue),
                WireDiscoveredCharacteristic(uuid: "2A37", properties: CharacteristicProperties([.read, .notify]).rawValue),
            ],
            error: nil
        ))
        let characteristics = try await bounded { try await characteristicsTask.value }
        #expect(characteristics == [CharacteristicIdentifier(uuid: "2A37", service: ServiceIdentifier(uuid: "180D"))])

        // The link is still up: the collision was folded, not fatal, and not a session drop.
        #expect(central.state == .poweredOn)
        #expect(provider.helloCount.withLock { $0 } == 1)
    }

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
