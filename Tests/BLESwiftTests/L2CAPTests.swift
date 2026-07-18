//
//  L2CAPTests.swift
//  BLESwiftTests
//

import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Foundation
import Testing

@Suite("L2CAP channels")
struct L2CAPTests {

    private static let psm = L2CAPPSM(0x0041)

    // MARK: - Open

    @Test("openL2CAPChannel succeeds: returns a handle carrying the PSM and peripheral")
    func openSucceeds() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm)

        #expect(channel.psm == Self.psm)
        #expect(channel.peripheral == fakePeripheral.peripheralIdentifier)
        #expect(await fakePeripheral.onQueue { fakePeripheral.openL2CAPChannelCalls } == [Self.psm])
    }

    @Test("openL2CAPChannel throws the CoreBluetooth error when the open fails")
    func openFailsWithError() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        let scriptedError = NSError(domain: "L2CAPTests", code: 42)
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .fail(scriptedError) }

        do {
            _ = try await peripheral.openL2CAPChannel(psm: Self.psm)
            Issue.record("expected the open to throw")
        } catch {
            #expect((error as NSError).domain == "L2CAPTests")
            #expect((error as NSError).code == 42)
        }
    }

    @Test("openL2CAPChannel times out, leaving the session healthy")
    func openTimesOut() async throws {
        let (central, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        do {
            _ = try await peripheral.openL2CAPChannel(psm: Self.psm, timeout: .milliseconds(50))
            Issue.record("expected the open to time out")
        } catch {
            #expect(error as? BLESwiftError == .timedOut)
        }

        guard case .connected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected the peripheral to remain .connected after a timed-out open")
            return
        }
    }

    @Test("Cancelling an in-flight open leaves the session healthy")
    func cancellationMidOpenLeavesSessionHealthy() async throws {
        let (central, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        let openTask = Task { try await peripheral.openL2CAPChannel(psm: Self.psm) }
        // Wait until the open has actually been issued to the fake before cancelling.
        await waitFor { await fakePeripheral.onQueue { !fakePeripheral.openL2CAPChannelCalls.isEmpty } }
        openTask.cancel()

        do {
            _ = try await openTask.value
            Issue.record("expected the cancelled open to throw")
        } catch {
            #expect(error as? BLESwiftError == .operationCancelled)
        }

        // Still connected, and a fresh open now succeeds — the session was left healthy.
        guard case .connected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected the peripheral to remain .connected after a cancelled open")
            return
        }
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .succeed }
        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm)
        #expect(channel.psm == Self.psm)
    }

    // MARK: - I/O

    @Test("Inbound data flows to the channel's incomingData stream")
    func inboundDataDelivered() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm)
        let fakeChannel = await fakePeripheral.onQueue { fakePeripheral.lastOpenedL2CAPChannel }
        let fake = try #require(fakeChannel)

        let payload = Data([0x01, 0x02, 0x03])
        fake.simulateInbound(payload)

        var iterator = channel.incomingData.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == payload)
    }

    @Test("write sends bytes outbound through the transport")
    func writePath() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm)
        let fake = try #require(await fakePeripheral.onQueue { fakePeripheral.lastOpenedL2CAPChannel })

        let first = Data([0xAA, 0xBB])
        let second = Data([0xCC])
        try await channel.write(first)
        try await channel.write(second)

        let written = await fake.onQueue { fake.writtenData }
        #expect(written == [first, second])
    }

    // MARK: - Teardown

    @Test("A disconnect tears the channel down, finishing incomingData with the disconnect error")
    func teardownOnDisconnectFinishesInbound() async throws {
        let (_, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm)
        let fake = try #require(await fakePeripheral.onQueue { fakePeripheral.lastOpenedL2CAPChannel })

        let task = Task { () -> Error? in
            do {
                for try await _ in channel.incomingData {}
                return nil
            } catch {
                return error
            }
        }

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let error = await task.value
        #expect(error as? BLESwiftError == .unexpectedDisconnect)
        #expect(await fake.onQueue { fake.isClosed })
    }

    @Test("Explicit close finishes incomingData cleanly and deregisters the channel")
    func explicitCloseFinishesInbound() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let channel = try await peripheral.openL2CAPChannel(psm: Self.psm)
        let fake = try #require(await fakePeripheral.onQueue { fakePeripheral.lastOpenedL2CAPChannel })

        let task = Task { () -> Error? in
            do {
                for try await _ in channel.incomingData {}
                return nil
            } catch {
                return error
            }
        }

        await channel.close()

        let error = await task.value
        #expect(error == nil)
        #expect(await fake.onQueue { fake.isClosed })
    }
}
