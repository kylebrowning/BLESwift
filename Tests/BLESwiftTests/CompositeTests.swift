//
//  CompositeTests.swift
//  BLESwiftTests
//

import Foundation
import Synchronization
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
        fakePeripheral.onQueue {
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
        #expect(fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.txCharacteristic] } == 1)

        // The one-shot subscription is released afterward: notify disabled again.
        await waitFor { fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 2 }
        #expect(fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.last?.enabled } == false)
    }

    // MARK: - writeAndAssemble

    @Test("writeAndAssemble accumulates packets to exactly expectedLength and decodes")
    func assembleExact() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        fakePeripheral.onQueue {
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
        fakePeripheral.onQueue {
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
        fakePeripheral.onQueue {
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
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        let quietPeriod: Duration = .milliseconds(250)
        let clock = ContinuousClock()

        let flushTask = Task {
            try await peripheral.flush(Self.rxCharacteristic, quietPeriod: quietPeriod)
        }

        // Wait until the flush's subscription is live, then land a packet mid-window.
        await waitFor { fakePeripheral.onQueue { fakePeripheral.notifyingCharacteristics.contains(Self.rxCharacteristic) } }
        try await Task.sleep(for: .milliseconds(100))
        let packetTime = clock.now
        fakePeripheral.simulateNotification(for: Self.rxCharacteristic, value: Data([0xEE]))

        try await flushTask.value
        let elapsedSincePacket = clock.now - packetTime

        // Without the reset, the flush would have completed ~150 ms after the packet
        // (the remainder of the original window). With it, a full fresh quiet period must
        // elapse after the packet. 240 ms leaves slop for timer coalescing.
        #expect(elapsedSincePacket >= .milliseconds(240), "a packet mid-window must restart the quiet period")

        // The flush's one-shot subscription is released afterward.
        await waitFor { fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.count } == 2 }
        #expect(fakePeripheral.onQueue { fakePeripheral.setNotifyValueCalls.last?.enabled } == false)
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
        let fakePeripheralB = addFakePeripheral(to: central, fakeCentral: fakeCentral)
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheralA.identifier] = fakePeripheralA
            fakeCentral.connectBehavior = .succeed
        }
        let peripheralA = try await central.connect(fakePeripheralA.peripheralIdentifier)
        let peripheralB = try await central.connect(fakePeripheralB.peripheralIdentifier)

        fakePeripheralA.onQueue {
            fakePeripheralA.onWrite = { _, _ in
                fakePeripheralA.simulateNotification(for: Self.rxCharacteristic, value: Data([0xAB, 0xCD]))
            }
        }

        // B's own, independent notification stream on the SAME characteristic UUID as A's
        // composite round-trip — started before A's write, so it's live throughout.
        let streamB: AsyncThrowingStream<Data, Error> = peripheralB.notifications(for: Self.rxCharacteristic)
        let collectorB = Task { try await collectData(streamB, count: 1) }
        await waitFor { fakePeripheralB.onQueue { fakePeripheralB.notifyingCharacteristics.contains(Self.rxCharacteristic) } }

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
        await waitFor { fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.count } == 2 }
        #expect(fakePeripheralA.onQueue { fakePeripheralA.setNotifyValueCalls.last?.enabled } == false)
        #expect(fakePeripheralB.onQueue { fakePeripheralB.setNotifyValueCalls.count } == 1)
    }
}
