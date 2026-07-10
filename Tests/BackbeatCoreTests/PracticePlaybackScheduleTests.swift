import XCTest
@testable import BackbeatCore

final class PracticePlaybackScheduleTests: XCTestCase {
    func testAdvancesElapsedByPracticeSpeed() {
        let schedule = PracticePlaybackSchedule(
            duration: 120,
            loopMode: .off,
            loopRange: nil,
            speed: 0.5
        )

        XCTAssertEqual(schedule.advancedElapsed(from: 20, by: 4), 22)
    }

    func testFullSongLoopWrapsAtDuration() {
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .song,
            loopRange: nil,
            speed: 1
        )

        XCTAssertEqual(schedule.advancedElapsed(from: 59, by: 3), 2)
        XCTAssertEqual(schedule.wrapTarget(forElapsed: 60.1), 0)
    }

    func testSectionLoopWrapsInsideRange() {
        let range = PracticeLoopRange(start: 10, end: 14, duration: 60)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertEqual(schedule.advancedElapsed(from: 13, by: 3), 12)
        XCTAssertEqual(schedule.wrapTarget(forElapsed: 14.1), 10)
    }

    func testSectionLoopClampsBeforeRangeToStart() {
        let range = PracticeLoopRange(start: 10, end: 14, duration: 60)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertEqual(schedule.advancedElapsed(from: 4, by: 1), 10)
    }

    func testTickActionWrapsSectionLoopPastEnd() {
        let range = PracticeLoopRange(start: 10, end: 14, duration: 60)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertEqual(schedule.tickAction(forElapsed: 14.1), .wrap(to: 10))
    }

    func testTickActionWrapsSectionLoopEndingAtTrackDurationInsteadOfFinishing() {
        let range = PracticeLoopRange(start: 50, end: 60, duration: 60)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertEqual(schedule.tickAction(forElapsed: 60), .wrap(to: 50))
    }

    func testTickActionWrapsSongModeAtDuration() {
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .song,
            loopRange: nil,
            speed: 1
        )

        XCTAssertEqual(schedule.tickAction(forElapsed: 60), .wrap(to: 0))
    }

    func testTickActionFinishesPastDurationWithLoopOff() {
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .off,
            loopRange: nil,
            speed: 1
        )

        XCTAssertEqual(schedule.tickAction(forElapsed: 60), .finished)
    }

    func testTickActionReportsProgressMidTrack() {
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .off,
            loopRange: nil,
            speed: 1
        )

        XCTAssertEqual(schedule.tickAction(forElapsed: 30), .progress(30))
    }

    func testTickActionFinishesForZeroDuration() {
        let schedule = PracticePlaybackSchedule(
            duration: 0,
            loopMode: .off,
            loopRange: nil,
            speed: 1
        )

        XCTAssertEqual(schedule.tickAction(forElapsed: 0), .finished)
    }

    // MARK: - Loop range clamped against a file-derived duration

    func testSectionLoopClampsEndPastDurationAndWrapsAtClampedEnd() {
        let range = PracticeLoopRange(start: 10, end: 70, duration: 100)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertEqual(schedule.loopRange, PracticeLoopRange(start: 10, end: 60, duration: 60))
        XCTAssertEqual(schedule.wrapTarget(forElapsed: 60), 10)
        XCTAssertEqual(schedule.tickAction(forElapsed: 60), .wrap(to: 10))
    }

    func testSectionLoopEntirelyPastDurationDropsRangeAndFinishesAtDuration() {
        let range = PracticeLoopRange(start: 70, end: 90, duration: 100)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertNil(schedule.loopRange)
        XCTAssertEqual(schedule.tickAction(forElapsed: 60), .finished)
    }

    func testSectionLoopDegradesToNilForZeroDuration() {
        let range = PracticeLoopRange(start: 10, end: 14, duration: 60)
        let schedule = PracticePlaybackSchedule(
            duration: 0,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertNil(schedule.loopRange)
        XCTAssertEqual(schedule.tickAction(forElapsed: 0), .finished)
    }

    func testSectionLoopInBoundsRangeIsUnchangedByClamping() {
        let range = PracticeLoopRange(start: 10, end: 14, duration: 60)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertEqual(schedule.loopRange, range)
    }

    func testClampedSectionLoopAgreesAcrossAdvancedElapsedWrapTargetAndTickAction() {
        let range = PracticeLoopRange(start: 10, end: 70, duration: 100)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        // Clamped range is (10, 60): a 59s elapsed + 3s delta wraps 2s past the
        // clamped end back around to 12 (10 + (52 % 50)), matching wrapTarget/tickAction.
        XCTAssertEqual(schedule.advancedElapsed(from: 59, by: 3), 12)
        XCTAssertEqual(schedule.wrapTarget(forElapsed: 60), 10)
        XCTAssertEqual(schedule.tickAction(forElapsed: 60), .wrap(to: 10))
    }

    func testStallRegressionSectionLoopEndBeyondDurationWrapsInsteadOfStallingAtElapsedEqualsDuration() {
        // The real-world case: a two-track pairDuration (60) shorter than a
        // section loop end (70) clamped against a stale persisted estimate.
        // Without the clamp, elapsed pins at 60 and neither .wrap nor .finished
        // ever fires — a silent stall while "playing".
        let range = PracticeLoopRange(start: 50, end: 70, duration: 100)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        XCTAssertEqual(schedule.tickAction(forElapsed: 60), .wrap(to: 50))
    }

    func testSectionLoopStraddlingDurationRecentersToMinimumDurationAtEndOfTrack() {
        // The clamped remainder (60 - 59.97 = 0.03s) is below PracticeLoopRange's
        // 0.05s minimum, so PracticeLoopRange.init re-centers it into a 50ms
        // micro-loop pinned at end-of-track. This is accepted (user-set, rare
        // straddle) rather than dropped like the fully-past-duration case.
        let range = PracticeLoopRange(start: 59.97, end: 70, duration: 100)
        let schedule = PracticePlaybackSchedule(
            duration: 60,
            loopMode: .section,
            loopRange: range,
            speed: 1
        )

        guard let clamped = schedule.loopRange else {
            XCTFail("expected a re-centered loop range, got nil")
            return
        }
        XCTAssertEqual(clamped.start, 59.95, accuracy: 1e-9)
        XCTAssertEqual(clamped.end, 60, accuracy: 1e-9)
    }
}
