//
//  ManualClockTests.swift
//  BLESwiftVirtualRadioTests
//

import BLESwiftTestSupport
import Testing

/// `ManualClock` on its own: it moves only when advanced, resumes exactly the sleepers an
/// advance reaches, and settles a cancel against an advance exactly once.
@Suite("ManualClock")
struct ManualClockTests {

    @Test("now moves only when advanced", .timeLimit(.minutes(1)))
    func nowMovesOnlyWhenAdvanced() {
        let clock = ManualClock()
        #expect(clock.now.offset == .zero)
        clock.advance(by: .seconds(3))
        #expect(clock.now.offset == .seconds(3))
        clock.advance(by: .milliseconds(500))
        #expect(clock.now.offset == .milliseconds(3500))
        #expect(clock.now.advanced(by: .seconds(1)).duration(to: clock.now) == .seconds(-1))
    }

    @Test("A sleep until a deadline already reached returns at once and registers nothing", .timeLimit(.minutes(1)))
    func sleepUntilPastReturns() async throws {
        let clock = ManualClock()
        try await clock.sleep(until: clock.now, tolerance: nil)
        try await clock.sleep(for: .zero)
        clock.advance(by: .seconds(5))
        try await clock.sleep(until: ManualClock.Instant(offset: .seconds(2)), tolerance: nil)
        #expect(clock.sleeperCount == 0)
    }

    @Test("Sleepers resume in deadline order, each only once its deadline is reached", .timeLimit(.minutes(1)))
    func deadlineOrder() async throws {
        let clock = ManualClock()
        let three = Task { try await clock.sleep(for: .seconds(3)); return 3 }
        let one = Task { try await clock.sleep(for: .seconds(1)); return 1 }
        let two = Task { try await clock.sleep(for: .seconds(2)); return 2 }
        await clock.waitForSleepers(3)

        clock.advance(by: .seconds(1))
        #expect(try await one.value == 1)
        #expect(clock.sleeperCount == 2)

        clock.advance(by: .seconds(1))
        #expect(try await two.value == 2)
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .seconds(1))
        #expect(try await three.value == 3)
        #expect(clock.sleeperCount == 0)
    }

    @Test("One advance past several deadlines, ties included, resumes them all", .timeLimit(.minutes(1)))
    func advancePastSeveral() async throws {
        let clock = ManualClock()
        let sleepers = [1, 2, 2, 5].map { seconds in
            Task { try await clock.sleep(for: .seconds(seconds)); return seconds }
        }
        await clock.waitForSleepers(4)
        clock.advance(by: .seconds(10))
        for (sleeper, seconds) in zip(sleepers, [1, 2, 2, 5]) {
            #expect(try await sleeper.value == seconds)
        }
        #expect(clock.sleeperCount == 0)
    }

    @Test("A sleep short of its deadline stays suspended", .timeLimit(.minutes(1)))
    func shortOfDeadlineStays() async throws {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(4999))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .milliseconds(1))
        try await sleeper.value
        #expect(clock.sleeperCount == 0)
    }

    @Test("Cancellation resumes a sleeper once, with CancellationError, and an advance after it resumes nothing", .timeLimit(.minutes(1)))
    func cancellationResumesOnce() async {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        await clock.waitForSleepers(1)
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
        // A second resume of the same continuation would trap; reaching the deadline after
        // the cancel must find nothing to resume.
        clock.advance(by: .seconds(10))
        #expect(clock.sleeperCount == 0)
    }

    @Test("A task already cancelled throws without registering a sleeper", .timeLimit(.minutes(1)))
    func alreadyCancelled() async {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test("waitForSleepers is woken by registration and returns at once when already satisfied", .timeLimit(.minutes(1)))
    func waitForSleepers() async throws {
        let clock = ManualClock()
        let waiter = Task { await clock.waitForSleepers(2) }
        let first = Task { try await clock.sleep(for: .seconds(1)) }
        await clock.waitForSleepers(1)
        let second = Task { try await clock.sleep(for: .seconds(1)) }
        await waiter.value
        #expect(clock.sleeperCount == 2)
        // Already satisfied: no registration is coming, so this must not wait for one.
        await clock.waitForSleepers(2)
        await clock.waitForSleepers(0)
        clock.advance(by: .seconds(1))
        try await first.value
        try await second.value
    }

    @Test("A cancelled waitForSleepers returns, once, and leaves the sleepers alone", .timeLimit(.minutes(1)))
    func cancelledWaitForSleepersReturns() async throws {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
        await clock.waitForSleepers(1)
        let waiter = Task { await clock.waitForSleepers(2) }
        waiter.cancel()
        await waiter.value
        #expect(clock.sleeperCount == 1)
        // The cancelled waiter is gone: a registration that would have satisfied it must not
        // resume it a second time.
        let second = Task { try await clock.sleep(for: .seconds(1)) }
        await clock.waitForSleepers(2)
        clock.advance(by: .seconds(1))
        try await sleeper.value
        try await second.value
        #expect(clock.sleeperCount == 0)
    }
}
