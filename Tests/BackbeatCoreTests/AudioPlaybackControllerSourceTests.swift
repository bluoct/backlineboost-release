import XCTest

final class AudioPlaybackControllerSourceTests: XCTestCase {
    func testPausePathStopsThePollingTimer() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(source.contains("private func stopTimer()"))
        XCTAssertTrue(try methodBody(source, signature: "private func pauseRender(store: LibraryStore)").contains("stopTimer()"))
    }

    func testPausingARenderCommitsTheEnginePositionToTheStore() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let pauseBody = try methodBody(source, signature: "private func pauseRender(store: LibraryStore)")
        let commit = try XCTUnwrap(
            pauseBody.range(of: "store.setPlaybackElapsed(currentRenderElapsed(store: store)"),
            "With the tick timer stopped on pause, resume reads store.playbackElapsed — it must be committed from the engine or resume rewinds by up to a poll interval."
        )
        let enginePause = try XCTUnwrap(pauseBody.range(of: "singleFileEngine.pause()"))
        XCTAssertLessThan(commit.lowerBound, enginePause.lowerBound, "The position must be committed before the engines pause.")
    }

    func testRenderTickIsUnifiedThroughRenderPlaybackEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")
        let engineProtocol = try readSource("Sources/Backbeat/Services/RenderPlaybackEngine.swift")

        XCTAssertTrue(source.contains("private func tickRenderEngine("))
        XCTAssertFalse(source.contains("func tickRender("), "The per-engine tick duplicates must stay collapsed into tickRenderEngine.")
        XCTAssertFalse(source.contains("func tickTwoTrackMix("), "The per-engine tick duplicates must stay collapsed into tickRenderEngine.")
        XCTAssertTrue(source.contains("schedule.tickAction(forElapsed: engine.currentElapsed())"))
        XCTAssertTrue(engineProtocol.contains("protocol RenderPlaybackEngine"))
        XCTAssertTrue(engineProtocol.contains("extension SingleFilePlaybackEngine: RenderPlaybackEngine {}"))
        XCTAssertTrue(engineProtocol.contains("extension TwoTrackMixPlaybackEngine: RenderPlaybackEngine {}"))
    }

    func testSeekAndLoopBoundsShareTheActiveRenderEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(source.contains("private func activeRenderEngine(for track: BackbeatTrack) -> RenderPlaybackEngine?"))
        XCTAssertTrue(try methodBody(source, signature: "func seekRender(toProgress progress: Double, track: BackbeatTrack, store: LibraryStore)").contains("activeRenderEngine(for: track)"))

        let loopBoundsBody = try methodBody(source, signature: "private func enforcePracticeLoopBounds(track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(loopBoundsBody.contains("activeRenderEngine(for: track)"))
        XCTAssertTrue(loopBoundsBody.contains("engine.seek(to: range.start"))
    }

    func testPreviewPlaybackPathIsFullyRemoved() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertFalse(
            source.lowercased().contains("preview"),
            "The AVAudioEngine stem-preview backend died with the preview screen; render engines are the only playback path."
        )
        XCTAssertFalse(source.contains("AVPlayer"))
        XCTAssertFalse(source.contains("import AVFoundation"), "Nothing in the controller talks to AVFoundation directly anymore.")
    }

    private func methodBody(_ source: String, signature: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "Missing method: \(signature)")
        let searchRange = start.upperBound..<source.endIndex
        let boundaries = [
            source.range(of: "\n    func ", range: searchRange),
            source.range(of: "\n    private func ", range: searchRange)
        ]
        let end = boundaries.compactMap { $0?.lowerBound }.min() ?? source.endIndex
        return String(source[start.lowerBound..<end])
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
