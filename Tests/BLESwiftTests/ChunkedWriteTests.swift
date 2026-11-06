//
//  ChunkedWriteTests.swift
//  BLESwiftTests
//

import Foundation
import BLESwiftCompat17
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Tests `Peripheral.writeChunked(...)`: the plain `async throws` overload and the
/// `AsyncThrowingStream<WriteProgress, Error>` progress overload. The tests use the `FakeCentral`
/// and `FakePeripheral` pair of `makeConnectedTestCentral()`.
@Suite("Chunked writes")
struct ChunkedWriteTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let characteristic = CharacteristicIdentifier(uuid: "2A37", service: service)

    // MARK: - Chunking

    @Test("100-byte payload with chunkSize 20 produces exactly five in-order writes")
    func chunksInOrder() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        let written = Mutex<[Data]>([])
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedMaximumWriteValueLength = 20
            fakePeripheral.onWrite = { _, data in written.withLock { $0.append(data) } }
        }

        let payload = Data((0..<100).map { UInt8($0) })
        try await peripheral.writeChunked(payload, to: Self.characteristic, chunkSize: 20)

        let slices = written.withLock { $0 }
        #expect(slices.count == 5)
        #expect(slices.allSatisfy { $0.count == 20 })
        #expect(Data(slices.joined()) == payload)
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == 5)
    }

    // MARK: - .withoutResponse back-pressure

    @Test(".withoutResponse chunking blocks on back-pressure and resumes when ready")
    func withoutResponseBackPressure() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.scriptedMaximumWriteValueLength = 20 }
        fakePeripheral.simulateWriteWithoutResponseBackPressure()

        let payload = Data(repeating: 0xAB, count: 100)
        let writeTask = Task {
            try await peripheral.writeChunked(payload, to: Self.characteristic, type: .withoutResponse, chunkSize: 20)
        }

        // The write is blocked before the first chunk. No write must arrive while back pressure is
        // active.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == nil)

        fakePeripheral.simulateReadyToSendWriteWithoutResponse()
        try await writeTask.value

        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == 5)
    }

    // MARK: - Cancellation

    @Test("Cancellation after chunk two stops at two writes and throws .operationCancelled")
    func cancellationBetweenChunks() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue {
            fakePeripheral.scriptedMaximumWriteValueLength = 20
            // Stop the fake's automatic `.withResponse` completion so that the test drives
            // completions one chunk at a time. Otherwise all five chunks complete before the poll
            // below can observe exactly two.
            fakePeripheral.onWriteRequest = { _, _, _ in }
        }

        let payload = Data(repeating: 0x01, count: 100)
        let writeTask = Task {
            try await peripheral.writeChunked(payload, to: Self.characteristic, chunkSize: 20)
        }

        // Complete chunk one. Then the code issues chunk two.
        await waitUntil { await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == 1 }
        await fakePeripheral.onQueue { fakePeripheral.simulateWriteCompletion(for: Self.characteristic) }

        // The code now issues chunk two and waits for its completion. Cancel instead of completing.
        await waitUntil { await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == 2 }
        writeTask.cancel()

        await #expect(throws: BLESwiftError.operationCancelled) {
            try await writeTask.value
        }
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == 2)
    }

    // MARK: - Progress stream

    @Test("Progress stream emits monotonically increasing byte counts ending at the total")
    func progressStream() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.scriptedMaximumWriteValueLength = 20 }

        let payload = Data(repeating: 0x02, count: 100)
        let stream: AsyncThrowingStream<WriteProgress, Error> = peripheral.writeChunked(payload, to: Self.characteristic, chunkSize: 20)

        var progress: [WriteProgress] = []
        for try await update in stream {
            progress.append(update)
        }

        #expect(progress.map(\.bytesSent) == [20, 40, 60, 80, 100])
        #expect(progress.allSatisfy { $0.totalBytes == 100 })
        // The values strictly increase.
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.bytesSent < $1.bytesSent })
        // isComplete is true only on the last emission.
        #expect(progress.dropLast().allSatisfy { !$0.isComplete })
        #expect(progress.last?.isComplete == true)
        #expect(progress.last?.bytesSent == 100)
    }

    // MARK: - Argument validation

    @Test("chunkSize greater than the maximum, and chunkSize 0, both throw .invalidArgument")
    func invalidChunkSize() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.scriptedMaximumWriteValueLength = 20 }

        let payload = Data(repeating: 0x03, count: 40)

        do {
            try await peripheral.writeChunked(payload, to: Self.characteristic, chunkSize: 21)
            Issue.record("expected .invalidArgument")
        } catch let error as BLESwiftError {
            guard case .invalidArgument = error else {
                Issue.record("expected .invalidArgument, got \(error)")
                return
            }
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
        do {
            try await peripheral.writeChunked(payload, to: Self.characteristic, chunkSize: 0)
            Issue.record("expected .invalidArgument")
        } catch let error as BLESwiftError {
            guard case .invalidArgument = error else {
                Issue.record("expected .invalidArgument, got \(error)")
                return
            }
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
        // The code must not issue a write for either rejected call.
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == nil)
    }

    // MARK: - Empty payload

    @Test("Empty payload performs zero writes; the stream emits a single (0, 0)")
    func emptyPayload() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()

        try await peripheral.writeChunked(Data(), to: Self.characteristic)
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == nil)

        var progress: [WriteProgress] = []
        let emptyStream: AsyncThrowingStream<WriteProgress, Error> = peripheral.writeChunked(Data(), to: Self.characteristic)
        for try await update in emptyStream {
            progress.append(update)
        }
        #expect(progress == [WriteProgress(bytesSent: 0, totalBytes: 0)])
        #expect(await fakePeripheral.onQueue { fakePeripheral.writeCallCounts[Self.characteristic] } == nil)
    }

    // MARK: - Helpers

    /// Polls `condition` until it is `true` or a long timeout ends.
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
