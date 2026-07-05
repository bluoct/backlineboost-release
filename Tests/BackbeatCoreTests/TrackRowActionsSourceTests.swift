import XCTest

final class TrackRowActionsSourceTests: XCTestCase {
    func testOpenRoutesEveryTrackToThePlayer() throws {
        let source = try readSource("Sources/Backbeat/Views/TrackRowActions.swift")

        XCTAssertTrue(source.contains("store.selectRenderedTrackForInspection(track.id)"))
        XCTAssertTrue(source.contains("store.selectTrack(track.id)"))
        XCTAssertFalse(source.contains("route.wrappedValue = .preview"), "There is no preview screen; unrendered tracks open in the Player.")
        XCTAssertTrue(source.contains("route.wrappedValue = .player"))
    }

    func testPlayFromStartPlaysOriginalForUnrenderedTracks() throws {
        let source = try readSource("Sources/Backbeat/Views/TrackRowActions.swift")

        XCTAssertTrue(source.contains("store.selectTrackForPlayback(track.id, restart: true)"))
        XCTAssertTrue(source.contains("playback.playRenderFromStart(track: track, store: store)"))
        XCTAssertTrue(
            source.contains("playback.playTrack(track: track, store: store, source: .original, startElapsed: 0)"),
            "An unrendered track must start playing immediately from its original file."
        )
    }

    func testRowActionsHostTheSharedTapGestureDispatcher() throws {
        let source = try readSource("Sources/Backbeat/Views/TrackRowActions.swift")

        XCTAssertTrue(source.contains("TapGesture(count: 2)"))
        XCTAssertTrue(source.contains(".exclusively(before: TapGesture(count: 1))"))
        XCTAssertTrue(source.contains("playFromStart(track)"))
        XCTAssertTrue(source.contains("open(track)"))
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
