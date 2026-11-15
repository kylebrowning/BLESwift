//
//  CBL2CAPChannelTransportTests.swift
//  BLESwiftTests
//

import BLESwiftCore
import Dispatch
import Foundation
import Testing
@testable import BLESwift

/// The lifetime rules of the CoreBluetooth L2CAP transport, over bound pairs of Foundation
/// streams instead of a `CBL2CAPChannel`.
@Suite("CBL2CAPChannelTransport lifetime")
struct CBL2CAPChannelTransportTests {

    /// A transport over two bound stream pairs, and the peer's ends of both pairs.
    private static func makeTransport() -> (CBL2CAPChannelTransport, peerOut: OutputStream, peerIn: InputStream) {
        var transportIn: InputStream?
        var peerOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &transportIn, outputStream: &peerOut)
        var peerIn: InputStream?
        var transportOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &peerIn, outputStream: &transportOut)
        let transport = CBL2CAPChannelTransport(
            psm: L2CAPPSM(0x0080),
            inputStream: transportIn!,
            outputStream: transportOut!
        )
        return (transport, peerOut!, peerIn!)
    }

    /// Polls `condition` every 5 ms until it is `true` or 5 seconds elapse.
    private static func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Reads `stream` on a background thread until it reports the end, and returns whether it
    /// did within 5 seconds. A bound input stream blocks in `read`, so the read must not run on
    /// a cooperative thread.
    private static func readsToEnd(_ stream: InputStream) async -> Bool {
        nonisolated(unsafe) let stream = stream
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 64)
                while stream.read(&buffer, maxLength: buffer.count) > 0 {}
                done.signal()
            }
            DispatchQueue.global().async {
                continuation.resume(returning: done.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    @Test("The inbound stream keeps the transport alive while a consumer reads it")
    func inboundStreamHoldsTheTransport() async throws {
        // Keep no other reference to the transport, so the release below is the last one.
        var transport: CBL2CAPChannelTransport?
        let peerOut: OutputStream
        do {
            let made = Self.makeTransport()
            transport = made.0
            peerOut = made.peerOut
        }
        weak let weakTransport = transport
        let stream = try #require(transport).inbound()
        transport = nil
        #expect(weakTransport != nil)

        peerOut.open()
        let bytes: [UInt8] = [1, 2, 3]
        _ = peerOut.write(bytes, maxLength: bytes.count)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == Data(bytes))

        // The peer ends the stream. The transport tears down, the stream finishes, and the
        // transport goes.
        peerOut.close()
        #expect(try await iterator.next() == nil)
        await Self.waitFor { weakTransport == nil }
        #expect(weakTransport == nil)
    }

    @Test("A second inbound() call returns a stream that finishes at once")
    func secondInboundFinishes() async throws {
        let (transport, _, _) = Self.makeTransport()
        let first = transport.inbound()
        var iterator = transport.inbound().makeAsyncIterator()
        #expect(try await iterator.next() == nil)
        transport.close(error: nil)
        withExtendedLifetime(first) {}
    }

    @Test("A transport that its owner releases with no close closes its streams in deinit")
    func releasedTransportClosesItsStreams() async throws {
        // Keep no other reference to the transport, so the release below is the last one.
        var transport: CBL2CAPChannelTransport?
        let peerIn: InputStream
        do {
            let made = Self.makeTransport()
            transport = made.0
            peerIn = made.peerIn
        }
        weak let weakTransport = transport

        // The block that opens the streams holds the transport, so `deinit` runs after it.
        transport = nil
        await Self.waitFor { weakTransport == nil }
        #expect(weakTransport == nil)

        // `deinit` closed the transport's output stream, so the peer reads to the end.
        #expect(await Self.readsToEnd(peerIn))
    }
}
