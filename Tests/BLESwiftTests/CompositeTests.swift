//
//  CompositeTests.swift
//  BLESwiftTests
//

import Foundation
import BLESwiftCompat17
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Exercises Phase 7's composite helpers — `writeAndAwaitNotification`,
/// `writeAndAssemble`, and `flush(_:quietPeriod:)` — covering listen-before-write ordering,
/// exact/overshoot assembly, the partial-data-timeout regression (a partially-assembled
/// reply must not defeat the overall timeout), and the flush window-reset loop.
@Suite("Composite helpers")
struct CompositeTests {

    // MARK: - Fixtures

    private static let uartService = ServiceIdentifier(uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let txCharacteristic = CharacteristicIdentifier(uuid: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E", service: uartService)
    private static let rxCharacteristic = CharacteristicIdentifier(uuid: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E", service: uartService)

    // MARK: - writeAndAwaitNotification

    @Test("writeAndAwaitNotification catches a notification emitted at the instant of the write — no loss window, listen installed first")
    func writeAndAwaitNotificationHasNoLossWindow() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        // Device scripted to respond INSTANTLY: the response notification is enqueued from
        // inside `writeValue` itself, before even the write's own completion event — the
        // hardest ordering for the no-loss guarantee. Also records whether the listen was
        // installed (notify enabled) by the time the write arrived, to verify
        // listen-before-write ordering.
        let notifyingAtWrite = Mutex<Bool?>(nil)
        await fakePeripheral.onQueue {
            fakePeripheral.onWrite = { _, _ in
                notifyingAtWrite.withLock { $0 = fakePeripheral.notifyingCharacteristics.contains(Self.rxCharacteristic) }
                fakePeripheral.simulateNotification(for: Self.rxCharacteristic, value: Data([0xAB, 0xCD]))
            }
        }

        let response: Data = try await peripheral.writeAndAwaitNotification(
            write: UInt8(0x01),
            to: Self.txCharacteristic,
            awaitOn: Self.rxCharacteristic
        )

        #expect(response == Data([0xAB, 0xCD]))
        #expect(notifyingAtWrite.withLock { $0 } == true, "the listen must be installed before the write is issued")
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.txCharacteristic] } == 1)

        // The one-shot subscription is released afterward: notify disabled again.
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 2 }
        #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.last?.enabled } == false)
    }

    // MARK: - writeAndAssemble

    @Test("writeAndAssemble accumulates packets to exactly expectedLength and decodes")
    func assembleExact() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue {
            fakePeripheral.onWrite = { _, _ in
                fakePeripheral.simulateNotification(for: Self.rxCharacteristic, value: Data([1, 2]))
                fakePeripheral.simulateNotification(for: Self.rxCharacteristic, value: Data([3, 4]))
            }
        }

        let assembled: Data = try await peripheral.writeAndAssemble(
            write: UInt8(0x01),
            to: Self.txCharacteristic,
            assembleFrom: Self.rxCharacteristic,
            expectedLength: 4
        )

        #expect(assembled == Data([1, 2, 3, 4]))
    }

    @Test("writeAndAssemble overshooting expectedLength throws .tooMuchData carrying everything received")
    func assembleOvershoot() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue {
            fakePeripheral.onWrite = { _, _ in
                fakePeripheral.simulateNotification(for: Self.rxCharacteristic, value: Data([1, 2, 3]))
                fakePeripheral.simulateNotification(for: Self.rxCharacteristic, value: Data([4, 5, 6]))
            }
        }

        do {
            let _: Data = try await peripheral.writeAndAssemble(
                write: UInt8(0x01),
                to: Self.txCharacteristic,
                assembleFrom: Self.rxCharacteristic,
                expectedLength: 4
            )
            Issue.record("expected .tooMuchData")
        } catch let error as BLESwiftError {
            #expect(error == .tooMuchData(expected: 4, received: Data([1, 2, 3, 4, 5, 6])))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("writeAndAssemble times out even after PARTIAL data was received (partial-data-timeout regression)")
    func assembleTimeoutWithPartialData() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        // The device sends 2 of the expected 4 bytes, then goes silent forever. A
        // partially-assembled reply must not defeat the overall timeout.
        await fakePeripheral.onQueue {
            fakePeripheral.onWrite = { _, _ in
                fakePeripheral.simulateNotification(for: Self.rxCharacteristic, value: Data([1, 2]))
            }
        }

        do {
            let _: Data = try await peripheral.writeAndAssemble(
                write: UInt8(0x01),
                to: Self.txCharacteristic,
                assembleFrom: Self.rxCharacteristic,
                expectedLength: 4,
                timeout: .milliseconds(150)
            )
            Issue.record("expected .listenTimedOut")
        } catch let error as BLESwiftError {
            #expect(error == .listenTimedOut)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - flush

    @Test("flush completes only after a full quiet period: a mid-window packet resets the window")
    func flushWindowResetsOnPacket() async throws {
        // Timed, so built to fail only on a real regression (#42). With a 1 s window and the
        // packet ~300 ms in, a flush that resets ends a full second after the packet, and one
        // that does not ends ~700 ms after it; the 950 ms bound sits between the two and a
        // busy machine can only lengthen the first. What a busy machine *can* break is the
        // setup: if the test oversleeps past the window, the flush is already over and the
        // packet tests nothing. Such an attempt is detected and retried, not misreported.
        let quietPeriod: Duration = .seconds(1)
        let clock = ContinuousClock()

        for _ in 1...3 {
            let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
            let flushReturned = Mutex(false)
            let flushTask = Task {
                try await peripheral.flush(Self.rxCharacteristic, quietPeriod: quietPeriod)
                flushReturned.withLock { $0 = true }
            }

            // Wait until the flush's subscription is live, then land a packet mid-window.
            await waitFor { await fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.rxCharacteristic) } }
            let subscribedTime = clock.now
            try await Task.sleep(for: .milliseconds(300))
            let packetTime = clock.now
            let packetLandedMidWindow = packetTime - subscribedTime < .milliseconds(600) && !flushReturned.withLock { $0 }
            fakePeripheral.simulateNotification(for: Self.rxCharacteristic, value: Data([0xEE]))

            try await flushTask.value
            guard packetLandedMidWindow else { continue }
            let elapsedSincePacket = clock.now - packetTime

            #expect(elapsedSincePacket >= .milliseconds(950), "a packet mid-window must restart the quiet period")

            // The flush's one-shot subscription is released afterward.
            await waitFor { await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 2 }
            #expect(await fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.last?.enabled } == false)
            return
        }
        Issue.record("in three attempts the runner never let the test land a packet inside the quiet period")
    }

    @Test("flush with a silent characteristic completes after one quiet period")
    func flushCompletesWhenQuiet() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        let clock = ContinuousClock()
        let start = clock.now

        try await peripheral.flush(Self.rxCharacteristic, quietPeriod: .milliseconds(150))

        #expect(clock.now - start >= .milliseconds(140))
        _ = fakePeripheral
    }

    @Test("flush rejects a non-positive quietPeriod with .invalidArgument")
    func flushInvalidQuietPeriodThrows() async throws {
        let (_, _, _, peripheral) = try await makeConnectedTestCentral()

        do {
            try await peripheral.flush(Self.rxCharacteristic, quietPeriod: .zero)
            Issue.record("expected .invalidArgument")
        } catch let error as BLESwiftError {
            guard case .invalidArgument = error else {
                Issue.record("expected .invalidArgument, got \(error)")
                return
            }
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }
}

/// Exercises Phase 2's multi-peripheral isolation for the composite helpers: a
/// `writeAndAwaitNotification` round-trip on one peripheral running concurrently with an
/// independent notification stream on another must not cross-talk in either direction.
@Suite("Multi-peripheral composite helper isolation")
struct MultiPeripheralCompositeTests {

    private static let uartService = ServiceIdentifier(uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let txCharacteristic = CharacteristicIdentifier(uuid: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E", service: uartService)
    private static let rxCharacteristic = CharacteristicIdentifier(uuid: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E", service: uartService)

    @Test("writeAndAwaitNotification on A, running concurrently with a plain notification stream on B (identical characteristic UUIDs), has no cross-talk in either direction")
    func writeAndAwaitNotificationOnOneDoesNotCrossTalkWithAnothersStream() async throws {
        let (central, fakeCentral, fakePeripheralA) = makeTestCentral()
        let fakePeripheralB = await addFakePeripheral(to: central, fakeCentral: fakeCentral)
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheralA.identifier] = fakePeripheralA
            fakeCentral.connectBehavior = .succeed
        }
        let peripheralA = try await central.connect(fakePeripheralA.peripheralIdentifier)
        let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)

        await fakePeripheralA.onQueue {
            fakePeripheralA.onWrite = { _, _ in
                fakePeripheralA.simulateNotification(for: Self.rxCharacteristic, value: Data([0xAB, 0xCD]))
            }
        }

        // B's own, independent notification stream on the SAME characteristic UUID as A's
        // composite round-trip — started before A's write, so it's live throughout.
        let streamB: AsyncThrowingStream<Data, Error> = peripheralB.notifications(for: Self.rxCharacteristic)
        let collectorB = Task { try await collectData(streamB, count: 1) }
        await waitFor { await fakePeripheralB.onQueue { fakePeripheralB.notifyingCharacteristics.contains(Self.rxCharacteristic) } }

        let response: Data = try await peripheralA.writeAndAwaitNotification(
            write: UInt8(0x01),
            to: Self.txCharacteristic,
            awaitOn: Self.rxCharacteristic
        )
        #expect(response == Data([0xAB, 0xCD]))

        // B must not have observed A's response notification — it never fired on B's fake.
        fakePeripheralB.simulateNotification(for: Self.rxCharacteristic, value: Data([0x01]))
        let receivedB = try await collectorB.value
        #expect(receivedB == [Data([0x01])], "B's stream must see only its own peripheral's notification, not A's")

        // A's one-shot subscription must have released cleanly, independent of B's
        // still-live one.
        await waitFor { await fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.count } == 2 }
        #expect(await fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.last?.enabled } == false)
        #expect(await fakePeripheralB.onQueue { fakePeripheralB.setNotifyValueCalls.count } == 1)
    }
}
