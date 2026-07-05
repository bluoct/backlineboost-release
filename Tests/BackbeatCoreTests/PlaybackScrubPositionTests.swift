import XCTest
@testable import BackbeatCore

final class PlaybackScrubPositionTests: XCTestCase {
    func testProgressClampsPointerLocationToTrackWidth() {
        XCTAssertEqual(PlaybackScrubPosition.progress(locationX: -20, width: 200), 0)
        XCTAssertEqual(PlaybackScrubPosition.progress(locationX: 50, width: 200), 0.25)
        XCTAssertEqual(PlaybackScrubPosition.progress(locationX: 240, width: 200), 1)
    }

    func testProgressIsZeroWhenTrackHasNoWidth() {
        XCTAssertEqual(PlaybackScrubPosition.progress(locationX: 50, width: 0), 0)
        XCTAssertEqual(PlaybackScrubPosition.progress(locationX: 50, width: -10), 0)
    }

    func testElapsedClampsProgressToDuration() {
        XCTAssertEqual(PlaybackScrubPosition.elapsed(progress: -0.2, duration: 100), 0)
        XCTAssertEqual(PlaybackScrubPosition.elapsed(progress: 0.75, duration: 100), 75)
        XCTAssertEqual(PlaybackScrubPosition.elapsed(progress: 1.2, duration: 100), 100)
    }
}
