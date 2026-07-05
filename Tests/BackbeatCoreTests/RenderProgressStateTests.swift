import XCTest
@testable import BackbeatCore

final class RenderProgressStateTests: XCTestCase {
    func testRenderProgressStateExposesDisplayCopy() {
        XCTAssertEqual(
            RenderProgressState.separatingStems.display,
            ProgressStatusDisplay(
                kind: .active,
                title: "Separating stems",
                detail: "Extracting drums, bass, vocals, and other parts."
            )
        )
        XCTAssertEqual(
            RenderProgressState.mixingDrumsTrack.display,
            ProgressStatusDisplay(
                kind: .active,
                title: "Creating drums track",
                detail: "Exporting the isolated drum stem for live mixing."
            )
        )
        XCTAssertEqual(
            RenderProgressState.mixingDrumlessTrack.display,
            ProgressStatusDisplay(
                kind: .active,
                title: "Creating drumless track",
                detail: "Combining the backing stems without the drum stem."
            )
        )
        XCTAssertEqual(
            RenderProgressState.finalizingOutput.display,
            ProgressStatusDisplay(
                kind: .active,
                title: "Finalizing render",
                detail: "Validating the rendered files and clearing temporary stems."
            )
        )
        XCTAssertEqual(
            RenderProgressState.failed("ffmpeg failed").display,
            ProgressStatusDisplay(
                kind: .failed,
                title: "Render failed",
                detail: "ffmpeg failed",
                actionTitle: "Retry render"
            )
        )
        XCTAssertNil(RenderProgressState.idle.display)
    }
}
