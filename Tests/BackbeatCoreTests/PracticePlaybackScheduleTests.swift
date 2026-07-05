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
}
