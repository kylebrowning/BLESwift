//
//  WireLengthValidationTests.swift
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

/// The wire boundary's rule for a negotiated maximum payload length: what it refuses, what it
/// clamps, and what a client does with a provider that reports one no caller could use.
@Suite("Wire length validation")
struct WireLengthValidationTests {

    @Test("A maximum of zero or less is refused")
    func nonPositiveMaximaThrow() {
        #expect(throws: WireDecodingError.invalidMaximumLength(0)) {
            try WireLengthValidation.validated(0)
        }
        #expect(throws: WireDecodingError.invalidMaximumLength(-1)) {
            try WireLengthValidation.validated(-1)
        }
        #expect(throws: WireDecodingError.invalidMaximumLength(Int.min)) {
            try WireLengthValidation.validated(Int.min)
        }
    }

    @Test("A plausible maximum passes through and an absurd one is clamped")
    func plausibleMaximaSurviveAndAbsurdOnesClamp() throws {
        #expect(try WireLengthValidation.validated(1) == 1)
        #expect(try WireLengthValidation.validated(20) == 20)
        #expect(try WireLengthValidation.validated(512) == 512)
        #expect(try WireLengthValidation.validated(WireLengthValidation.maximumLength) == WireLengthValidation.maximumLength)
        #expect(try WireLengthValidation.validated(WireLengthValidation.maximumLength + 1) == WireLengthValidation.maximumLength)
        #expect(try WireLengthValidation.validated(Int.max) == WireLengthValidation.maximumLength)
    }

    @Test("A subscriber whose update length is unusable fails conversion")
    func subscriberWithNonPositiveUpdateLengthThrows() throws {
        #expect(throws: WireDecodingError.invalidMaximumLength(0)) {
            try WireSubscriber(id: UUID(), maximumUpdateValueLength: 0).subscriber
        }
        #expect(throws: WireDecodingError.invalidMaximumLength(-20)) {
            try WireSubscriber(id: UUID(), maximumUpdateValueLength: -20).subscriber
        }
        // A usable one still converts, clamped at the top end.
        #expect(try WireSubscriber(id: UUID(), maximumUpdateValueLength: 180).subscriber.maximumUpdateValueLength == 180)
        #expect(
            try WireSubscriber(id: UUID(), maximumUpdateValueLength: Int.max).subscriber.maximumUpdateValueLength
                == WireLengthValidation.maximumLength
        )
    }

    // MARK: - Offsets

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)
    private static var central: WireSubscriber { WireSubscriber(id: UUID(), maximumUpdateValueLength: 20) }

    @Test("A read request whose offset is negative fails conversion, and a plausible one converts")
    func readRequestOffsetIsValidated() throws {
        func request(offset: Int) -> WireReadRequest {
            WireReadRequest(
                token: UUID(),
                central: Self.central,
                characteristic: WireCharacteristicRef(Self.measurement),
                offset: offset
            )
        }
        // A handler slices its value at the offset, so a negative one would trap the client.
        #expect(throws: WireDecodingError.invalidOffset(-1)) { try request(offset: -1).readRequest }
        #expect(throws: WireDecodingError.invalidOffset(Int.min)) { try request(offset: Int.min).readRequest }
        #expect(try request(offset: 0).readRequest.offset == 0)
        #expect(try request(offset: 7).readRequest.offset == 7)
        // An absurd one is clamped rather than refused, exactly as an absurd length is.
        #expect(try request(offset: WireLengthValidation.maximumOffset + 1).readRequest.offset
            == WireLengthValidation.maximumOffset)
        #expect(try request(offset: Int.max).readRequest.offset == WireLengthValidation.maximumOffset)
    }

    @Test("A write entry whose offset is negative fails conversion, and a plausible one converts")
    func writeEntryOffsetIsValidated() throws {
        func entry(offset: Int) -> WireWriteEntry {
            WireWriteEntry(
                central: Self.central,
                characteristic: WireCharacteristicRef(Self.measurement),
                offset: offset,
                value: Data([1])
            )
        }
        #expect(throws: WireDecodingError.invalidOffset(-1)) { try entry(offset: -1).entry }
        #expect(throws: WireDecodingError.invalidOffset(Int.min)) { try entry(offset: Int.min).entry }
        #expect(try entry(offset: 0).entry.offset == 0)
        #expect(try entry(offset: 7).entry.offset == 7)
        #expect(try entry(offset: WireLengthValidation.maximumOffset + 1).entry.offset
            == WireLengthValidation.maximumOffset)
        #expect(try entry(offset: Int.max).entry.offset == WireLengthValidation.maximumOffset)
        // And a batch carrying one is refused whole.
        #expect(throws: WireDecodingError.invalidOffset(-1)) {
            try WireWriteRequest(token: UUID(), entries: [entry(offset: -1)]).writeRequest
        }
    }

#if !targetEnvironment(simulator)
    // Sockets in a CI simulator are unreliable; the simulator-side path is covered by the
    // two-simulator E2E on real simulators.

    @Test(
        "A provider that reports an unusable write maximum loses its client's session",
        arguments: [0, -1]
    )
    func clientDropsAProviderThatReportsAnUnusableMaximum(maximum: Int) async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "wirelengthvalidation.client")
        let link = LinkCentral(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "test",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: link, queue: queue)
        defer { link.shutdown(); provider.stop() }
        await waitFor(timeout: .seconds(30)) { central.state == .poweredOn }
        #expect(central.state == .poweredOn)
        #expect(provider.helloCount.withLock { $0 } == 1)

        let identifier = UUID()
        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: identifier, name: nil)) }
        await waitFor { !provider.requests.withLock { $0 }.isEmpty }

        // A maximum `Peripheral.writeChunked` would spin on (0) or trap on (-1). Neither is
        // mirrored: the connect never completes, and the session is dropped and redialed.
        provider.emit(.didConnect(
            peripheral: identifier,
            name: nil,
            maximumWriteWithResponse: maximum,
            maximumWriteWithoutResponse: 20
        ))

        await waitFor(timeout: .seconds(10)) { provider.helloCount.withLock { $0 } >= 2 }
        #expect(provider.helloCount.withLock { $0 } >= 2)

        // The connect neither hung the process nor trapped it: it fails on its own terms once
        // the link under it goes.
        connectTask.cancel()
        _ = try? await bounded { try await connectTask.value }
    }

    @Test("A provider that reports an absurd write maximum has it clamped, not refused")
    func clientClampsAnAbsurdMaximum() async throws {
        let provider = try ScriptedProvider()
        try await provider.start()
        let queue = DispatchSerialQueue(label: "wirelengthvalidation.clamp")
        let link = LinkCentral(
            endpoint: provider.endpoint,
            queue: queue,
            clientName: "test",
            retryInterval: .milliseconds(50)
        )
        let central = Central(backend: link, queue: queue)
        defer { link.shutdown(); provider.stop() }
        await waitFor(timeout: .seconds(30)) { central.state == .poweredOn }

        let identifier = UUID()
        let connectTask = Task { try await central.connect(PeripheralIdentifier(uuid: identifier, name: nil)) }
        await waitFor { !provider.requests.withLock { $0 }.isEmpty }
        provider.emit(.didConnect(
            peripheral: identifier,
            name: nil,
            maximumWriteWithResponse: Int.max,
            maximumWriteWithoutResponse: Int.max
        ))
        let peripheral = try await bounded { try await connectTask.value }

        #expect(await peripheral.maximumWriteValueLength(for: .withResponse) == WireLengthValidation.maximumLength)
        #expect(await peripheral.maximumWriteValueLength(for: .withoutResponse) == WireLengthValidation.maximumLength)
        // Clamped, not treated as a violation: the session stayed up.
        #expect(provider.helloCount.withLock { $0 } == 1)
    }
#endif
}
