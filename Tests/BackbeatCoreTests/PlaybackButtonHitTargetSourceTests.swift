import XCTest

final class PlaybackButtonHitTargetSourceTests: XCTestCase {
    func testCircularPlaybackControlsUseSharedHitTargetComponent() throws {
        let styleSource = try readSource("Sources/Backbeat/Views/BackbeatStyle.swift")
        XCTAssertTrue(styleSource.contains("struct PlaybackCircleButton"))
        XCTAssertTrue(styleSource.contains(".contentShape(Circle())"))

        for path in [
            "Sources/Backbeat/Views/PlayerView.swift",
            "Sources/Backbeat/Views/MiniPlayerView.swift"
        ] {
            let source = try readSource(path)
            XCTAssertTrue(source.contains("PlaybackCircleButton"), "\(path) should use the shared circular playback button.")
            XCTAssertFalse(source.contains(".background(BackbeatStyle.primary, in: Circle())"), "\(path) should not draw the playable circle outside the button label.")
        }
    }

    func testSharedBackbeatButtonStyleExposesFullFrameAsHitTarget() throws {
        let styleSource = try readSource("Sources/Backbeat/Views/BackbeatStyle.swift")
        XCTAssertTrue(styleSource.contains(".contentShape(Rectangle())"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
