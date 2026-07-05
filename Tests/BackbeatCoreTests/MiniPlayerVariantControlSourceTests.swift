import XCTest

final class MiniPlayerVariantControlSourceTests: XCTestCase {
    func testMiniPlayerSourceTagCyclesThroughPlaybackSources() throws {
        let source = try readSource("Sources/Backbeat/Views/MiniPlayerView.swift")
        let controls = try readSource("Sources/Backbeat/Views/PlaybackSourceControls.swift")

        XCTAssertTrue(source.contains("PlaybackSourceTag("))
        XCTAssertTrue(source.contains("nextPlaybackSource(after:"))
        XCTAssertTrue(source.contains("playback.switchPlaybackSource(nextSource, track: track, store: store, controlSource: .nowPlaying)"))
        XCTAssertTrue(source.contains("let sources = PlaybackSource.controlCases"))
        XCTAssertFalse(source.contains("let sources = PlaybackSource.allCases"))
        XCTAssertTrue(controls.contains("struct PlaybackSourceTag"))
    }

    func testMiniPlayerSourceCycleUsesOnlyUserFacingPlaybackSources() throws {
        let source = try readSource("Sources/Backbeat/Views/MiniPlayerView.swift")

        XCTAssertTrue(source.contains("PlaybackSource.controlCases"))
        XCTAssertTrue(source.contains(".drumBoost"))
        XCTAssertTrue(source.contains(".drumless"))
        XCTAssertFalse(source.contains("sources.contains(.drums)"))
    }

    func testMiniPlayerExposesQueuePreviousAndNextControls() throws {
        let source = try readSource("Sources/Backbeat/Views/MiniPlayerView.swift")

        XCTAssertTrue(source.contains("Image(systemName: \"backward.end.fill\")"))
        XCTAssertTrue(source.contains("Image(systemName: \"forward.end.fill\")"))
        XCTAssertTrue(source.contains("playback.playPreviousInQueue(store: store)"))
        XCTAssertTrue(source.contains("playback.playNextInQueue(store: store)"))
        XCTAssertTrue(source.contains(".disabled(!store.canPlayPreviousInQueue)"))
        XCTAssertTrue(source.contains(".disabled(!store.canPlayNextInQueue)"))
    }

    func testMiniPlayerExposesRepeatAndShuffleControls() throws {
        let source = try readSource("Sources/Backbeat/Views/MiniPlayerView.swift")

        XCTAssertTrue(source.contains("Image(systemName: store.repeatModeSystemImage)"))
        XCTAssertTrue(source.contains("Image(systemName: \"shuffle\")"))
        XCTAssertTrue(source.contains("store.cycleRepeatMode()"))
        XCTAssertTrue(source.contains("store.toggleShuffleMode()"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Repeat mode\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Shuffle\")"))
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
