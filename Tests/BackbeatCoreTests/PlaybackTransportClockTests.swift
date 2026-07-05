import XCTest
@testable import BackbeatCore

final class PlaybackTransportClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testWallFallbackAdvancesElapsedBySpeed() {
        var clock = PlaybackTransportClock()
        clock.setSpeed(0.5)
        clock.start(fromElapsed: 10, duration: 100, at: t0)

        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(4)), 12)
    }

    func testRenderedSecondsPathIgnoresSpeedMultiplier() {
        var clock = PlaybackTransportClock()
        clock.setSpeed(1.5)
        clock.start(fromElapsed: 10, duration: 100, at: t0)

        XCTAssertEqual(clock.elapsed(renderedSeconds: 4, at: t0.addingTimeInterval(4)), 14)
    }

    func testNegativeRenderedSecondsClampsToScheduledStart() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 10, duration: 100, at: t0)

        XCTAssertEqual(clock.elapsed(renderedSeconds: -0.01, at: t0), 10)
    }

    func testSetSpeedWhileRunningReanchorsWallFallbackOnly() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 10, duration: 100, at: t0)
        let t1 = t0.addingTimeInterval(4)
        clock.setSpeed(0.5, at: t1)

        XCTAssertEqual(clock.elapsed(at: t1.addingTimeInterval(2)), 15)
        XCTAssertEqual(clock.elapsed(renderedSeconds: 6, at: t1.addingTimeInterval(2)), 16)
    }

    func testSetSpeedCommitsExplicitElapsedIntoWallAnchor() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 10, duration: 100, at: t0)
        let t1 = t0.addingTimeInterval(4)
        clock.setSpeed(0.5, committing: 13, at: t1)

        XCTAssertEqual(clock.elapsed(at: t1.addingTimeInterval(2)), 14)
    }

    func testSetSpeedWhileStoppedOnlyClampsSpeed() {
        var clock = PlaybackTransportClock()
        clock.setSpeed(3)
        XCTAssertEqual(clock.speed, 1.5)

        clock.setSpeed(0.1)
        XCTAssertEqual(clock.speed, 0.5)

        clock.setSpeed(.nan)
        XCTAssertEqual(clock.speed, 1)
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(100)), 0)
    }

    func testPauseCommittingFreezesElapsed() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 10, duration: 100, at: t0)
        let t1 = t0.addingTimeInterval(5)
        clock.pause(committing: 42, at: t1)

        XCTAssertEqual(clock.elapsed(at: t1.addingTimeInterval(100)), 42)
        XCTAssertEqual(clock.elapsed(renderedSeconds: 5, at: t1.addingTimeInterval(100)), 42)
    }

    func testPauseWithoutCommittedElapsedFallsBackToWallClock() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 10, duration: 100, at: t0)
        clock.pause(at: t0.addingTimeInterval(4))

        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(100)), 14)
    }

    func testPrepareKeepsClockStopped() {
        var clock = PlaybackTransportClock()
        clock.prepare(atElapsed: 30, duration: 100)

        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(100)), 30)
        XCTAssertEqual(clock.elapsed(renderedSeconds: 5, at: t0.addingTimeInterval(100)), 30)
    }

    func testZeroDurationSkipsUpperClamp() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 0, duration: 0, at: t0)

        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(500)), 500)
    }

    func testElapsedClampsToDuration() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 10, duration: 20, at: t0)

        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(50)), 20)
        XCTAssertEqual(clock.elapsed(renderedSeconds: 50, at: t0.addingTimeInterval(50)), 20)
    }

    func testDelayedStartClampsToAnchorBeforeStartDate() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 10, duration: 100, at: t0.addingTimeInterval(0.02))

        XCTAssertEqual(clock.elapsed(at: t0), 10)
    }

    func testStopZeroesAnchors() {
        var clock = PlaybackTransportClock()
        clock.start(fromElapsed: 10, duration: 100, at: t0)
        clock.stop()

        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(100)), 0)
    }
}
