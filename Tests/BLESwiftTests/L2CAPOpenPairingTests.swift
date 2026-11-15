//
//  L2CAPOpenPairingTests.swift
//  BLESwiftTests
//

import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Foundation
import Testing

/// Tests that each `didOpenL2CAPChannel` event goes to the correct pending open. The backend
/// sends one event for each `openL2CAPChannel` call, in call order. These tests make sure that
/// the late event of a cancelled call does not go to a different open.
@Suite("L2CAP open pairing")
struct L2CAPOpenPairingTests {

    private static let psmA = L2CAPPSM(0x0080)
    private static let psmB = L2CAPPSM(0x0081)

    /// Starts an open of `psm` and waits until the fake has received the call, so that the
    /// open order is the task order.
    private func startOpen(
        _ peripheral: Peripheral,
        _ fakePeripheral: FakePeripheral,
        psm: L2CAPPSM,
        timeout: Duration? = nil,
        expectedCalls: Int
    ) async -> Task<L2CAPChannel, Error> {
        let task = Task { try await peripheral.openL2CAPChannel(psm: psm, timeout: timeout) }
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.openL2CAPChannelCalls.count >= expectedCalls } }
        return task
    }

    /// Returns the error that `task` throws, or `nil` if it returns.
    private func thrownError(_ task: Task<L2CAPChannel, Error>) async -> Error? {
        do {
            _ = try await task.value
            return nil
        } catch {
            return error
        }
    }

    @Test("A late success for a cancelled open is closed, and the next open gets its own channel")
    func lateSuccessAfterCancel() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        let openA = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, expectedCalls: 1)
        let openB = await startOpen(peripheral, fakePeripheral, psm: Self.psmB, expectedCalls: 2)
        openA.cancel()
        #expect(await thrownError(openA) as? BLESwiftError == .operationCancelled)

        let channelA = FakeL2CAPChannel(psm: Self.psmA, queue: fakePeripheral.queue)
        let channelB = FakeL2CAPChannel(psm: Self.psmB, queue: fakePeripheral.queue)
        fakePeripheral.simulateL2CAPOpenResult(channel: channelA, error: nil)
        fakePeripheral.simulateL2CAPOpenResult(channel: channelB, error: nil)

        let channel = try await openB.value
        #expect(channel.psm == Self.psmB)
        await waitFor { await channelA.onQueue { channelA.isClosed } }
        #expect(await channelA.onQueue { channelA.isClosed })
        #expect(await channelB.onQueue { !channelB.isClosed })
    }

    @Test("A late failure for a cancelled open does not fail the next open")
    func lateFailureAfterCancel() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        let openA = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, expectedCalls: 1)
        let openB = await startOpen(peripheral, fakePeripheral, psm: Self.psmB, expectedCalls: 2)
        openA.cancel()
        #expect(await thrownError(openA) as? BLESwiftError == .operationCancelled)

        let channelB = FakeL2CAPChannel(psm: Self.psmB, queue: fakePeripheral.queue)
        fakePeripheral.simulateL2CAPOpenResult(channel: nil, error: NSError(domain: "L2CAPOpenPairingTests", code: 7))
        fakePeripheral.simulateL2CAPOpenResult(channel: channelB, error: nil)

        let channel = try await openB.value
        #expect(channel.psm == Self.psmB)
    }

    @Test("A late success for a timed-out open is closed, and the next open on the same PSM gets the second channel")
    func lateSuccessAfterTimeout() async throws {
        let clock = ManualClock()
        let (central, fakeCentral, fakePeripheral) = makeTestCentral(configuration: Configuration(clock: clock))
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }
        let peripheral = try await central.connect(fakePeripheral.peripheralIdentifier)
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        let openA = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, timeout: .milliseconds(50), expectedCalls: 1)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(50))
        #expect(await thrownError(openA) as? BLESwiftError == .timedOut)

        let openB = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, expectedCalls: 2)
        let first = FakeL2CAPChannel(psm: Self.psmA, queue: fakePeripheral.queue)
        let second = FakeL2CAPChannel(psm: Self.psmA, queue: fakePeripheral.queue)
        fakePeripheral.simulateL2CAPOpenResult(channel: first, error: nil)
        fakePeripheral.simulateL2CAPOpenResult(channel: second, error: nil)

        let channel = try await openB.value
        #expect(channel.psm == Self.psmA)
        await waitFor { await first.onQueue { first.isClosed } }
        #expect(await first.onQueue { first.isClosed })
        #expect(await second.onQueue { !second.isClosed })

        // The handle that open B returned writes to the second channel.
        try await channel.write(Data([0x01]))
        #expect(await second.onQueue { second.writtenData } == [Data([0x01])])
        #expect(await first.onQueue { first.writtenData }.isEmpty)
    }

    @Test("A success whose PSM matches no pending open is closed and resumes no open")
    func unmatchedPSMIsClosed() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        let openA = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, expectedCalls: 1)
        let stray = FakeL2CAPChannel(psm: Self.psmB, queue: fakePeripheral.queue)
        fakePeripheral.simulateL2CAPOpenResult(channel: stray, error: nil)
        await waitFor { await stray.onQueue { stray.isClosed } }
        #expect(await stray.onQueue { stray.isClosed })

        // Open A is still pending. Its own channel resolves it.
        let channelA = FakeL2CAPChannel(psm: Self.psmA, queue: fakePeripheral.queue)
        fakePeripheral.simulateL2CAPOpenResult(channel: channelA, error: nil)
        let channel = try await openA.value
        #expect(channel.psm == Self.psmA)
        #expect(await channelA.onQueue { !channelA.isClosed })
    }

    @Test("A disconnect fails the live open with the disconnect error and drops the tombstone")
    func disconnectFailsLiveOpen() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        let openA = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, expectedCalls: 1)
        let openB = await startOpen(peripheral, fakePeripheral, psm: Self.psmB, expectedCalls: 2)
        openA.cancel()
        #expect(await thrownError(openA) as? BLESwiftError == .operationCancelled)

        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        #expect(await thrownError(openB) as? BLESwiftError == .unexpectedDisconnect)

        // After a reconnect, the new session has no old entries. The first event goes to the
        // first new open.
        let reconnected = try await central.connect(fakePeripheral.peripheralIdentifier)
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }
        let openC = await startOpen(reconnected, fakePeripheral, psm: Self.psmA, expectedCalls: 3)
        let channelC = FakeL2CAPChannel(psm: Self.psmA, queue: fakePeripheral.queue)
        fakePeripheral.simulateL2CAPOpenResult(channel: channelC, error: nil)
        let channel = try await openC.value
        #expect(channel.psm == Self.psmA)
        #expect(await channelC.onQueue { !channelC.isClosed })
    }

    @Test("An explicit disconnect fails the live open with explicitDisconnect")
    func explicitDisconnectFailsLiveOpen() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        let openA = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, expectedCalls: 1)
        let disconnect = Task { try await central.disconnect(fakePeripheral.peripheralIdentifier) }
        #expect(await thrownError(openA) as? BLESwiftError == .explicitDisconnect)

        // The radio is on, so the fake does not confirm the cancel. Confirm it here.
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)
        try await disconnect.value
    }

    @Test("cancelAllOperations fails the live open, closes its late channel, and the next open gets its own channel")
    func cancelAllOperationsKeepsTombstones() async throws {
        let (central, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.l2capOpenBehavior = .hold }

        let openA = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, expectedCalls: 1)
        await central.cancelAllOperations()
        #expect(await thrownError(openA) as? BLESwiftError == .cancelled)

        let openB = await startOpen(peripheral, fakePeripheral, psm: Self.psmA, expectedCalls: 2)
        let late = FakeL2CAPChannel(psm: Self.psmA, queue: fakePeripheral.queue)
        let own = FakeL2CAPChannel(psm: Self.psmA, queue: fakePeripheral.queue)
        fakePeripheral.simulateL2CAPOpenResult(channel: late, error: nil)
        fakePeripheral.simulateL2CAPOpenResult(channel: own, error: nil)

        let channel = try await openB.value
        await waitFor { await late.onQueue { late.isClosed } }
        #expect(await late.onQueue { late.isClosed })
        #expect(await own.onQueue { !own.isClosed })
        try await channel.write(Data([0x02]))
        #expect(await own.onQueue { own.writtenData } == [Data([0x02])])
    }
}
