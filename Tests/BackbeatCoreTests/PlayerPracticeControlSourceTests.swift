import XCTest

final class PlayerPracticeControlSourceTests: XCTestCase {
    func testPlayerViewHostsPracticeControlsAndLoopTimeline() throws {
        let source = try readSource("Sources/Backbeat/Views/PlayerView.swift")

        XCTAssertTrue(source.contains("@State private var waveformEnvelope"))
        XCTAssertTrue(source.contains("static let waveformCache = WaveformEnvelopeCache()"))
        XCTAssertTrue(source.contains("LoopTimelineView("))
        XCTAssertTrue(source.contains("PracticeControlsView("))
        XCTAssertTrue(source.contains("store.practiceLoopRange"))
        XCTAssertTrue(source.contains("waveformCache.envelope(for:"))
    }

    func testPlayerViewScrollsInsteadOfPushingMiniPlayerOffscreen() throws {
        let source = try readSource("Sources/Backbeat/Views/PlayerView.swift")

        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, alignment: .top)"))
        XCTAssertFalse(source.contains("            Spacer()\n\n            VStack(spacing: 26)"))
    }

    func testPracticeControlsExposeLoopSpeedMarkersZoomAndClear() throws {
        let source = try readSource("Sources/Backbeat/Views/PracticeControlsView.swift")

        XCTAssertTrue(source.contains("ForEach(PracticeLoopMode.allCases"))
        XCTAssertTrue(source.contains("Slider(value: speedBinding, in: 0.5...1.5"))
        XCTAssertTrue(source.contains("playback.setPracticeLoopMode"))
        XCTAssertTrue(source.contains("playback.clearPracticeLoop"))
        XCTAssertTrue(source.contains("playback.setPracticeSpeed"))
        XCTAssertTrue(source.contains("LoopTimelineView("))
        XCTAssertTrue(source.contains("Image(systemName: \"xmark.circle\")"))
        XCTAssertTrue(source.contains("accessibilityLabel(\"Clear loop markers\")"))
    }

    func testDoubleClickingSpeedSliderResetsPracticeSpeed() throws {
        let source = try readSource("Sources/Backbeat/Views/PracticeControlsView.swift")

        XCTAssertTrue(source.contains("TapGesture(count: 2)"))
        XCTAssertTrue(source.contains("playback.setPracticeSpeed(1, track: track, store: store)"))
    }

    func testRabbitAndTurtleButtonsStepPracticeSpeedIncrementally() throws {
        let source = try readSource("Sources/Backbeat/Views/PracticeControlsView.swift")

        XCTAssertTrue(source.contains("changePracticeSpeed(by: -0.05)"))
        XCTAssertTrue(source.contains("changePracticeSpeed(by: 0.05)"))
        XCTAssertTrue(source.contains("Image(systemName: \"tortoise.fill\")"))
        XCTAssertTrue(source.contains("Image(systemName: \"hare.fill\")"))
        XCTAssertTrue(source.contains("accessibilityLabel(\"Slower\")"))
        XCTAssertTrue(source.contains("accessibilityLabel(\"Faster\")"))
    }

    func testLoopTimelineExposesWaveformAndDraggableABMarkers() throws {
        let source = try readSource("Sources/Backbeat/Views/LoopTimelineView.swift")

        XCTAssertTrue(source.contains("WaveformEnvelopeShape"))
        XCTAssertTrue(source.contains("label: \"A\""))
        XCTAssertTrue(source.contains("label: \"B\""))
        XCTAssertTrue(source.contains("DragGesture(minimumDistance: 0"))
        XCTAssertTrue(source.contains("onMoveLoopStart"))
        XCTAssertTrue(source.contains("onMoveLoopEnd"))
    }

    func testPlayerViewShowsDrumMixControlsForDrumBoostSource() throws {
        let player = try readSource("Sources/Backbeat/Views/PlayerView.swift")
        let controls = try readSource("Sources/Backbeat/Views/DrumMixControlsView.swift")

        XCTAssertTrue(player.contains("DrumMixControlsView("))
        XCTAssertTrue(player.contains("selectedSource == .drumBoost"))
        XCTAssertTrue(player.contains("store.twoTrackMixAsset(for: track, preferredSource: .drumBoost)"))
        XCTAssertTrue(player.contains("playback.setDrumMixBoostDB"))
        XCTAssertTrue(controls.contains("Slider(value: boostBinding, in: 0...8"))
        XCTAssertTrue(controls.contains("Image(systemName: \"drum.fill\")"))
    }

    func testAudioControllerAppliesPitchPreservingPracticePlayback() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")
        let engine = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        XCTAssertTrue(source.contains("setPracticeSpeed"))
        XCTAssertTrue(source.contains("setPracticeLoopMode"))
        XCTAssertTrue(source.contains("PracticePlaybackSchedule("))
        XCTAssertTrue(source.contains("singleFileEngine.setSpeed"))
        XCTAssertTrue(engine.contains("AVAudioUnitTimePitch"))
        XCTAssertTrue(engine.contains("timePitch.rate = Float(clock.speed)"))
    }

    func testPracticeControlsStayOutOfPlaylistLibrarySidebarAndMiniPlayer() throws {
        for path in [
            "Sources/Backbeat/Views/PlaylistDetailView.swift",
            "Sources/Backbeat/Views/LibraryView.swift",
            "Sources/Backbeat/Views/SidebarView.swift",
            "Sources/Backbeat/Views/MiniPlayerView.swift"
        ] {
            let source = try readSource(path)
            XCTAssertFalse(source.contains("PracticeControlsView("), "\(path) should not host Player-only practice controls.")
            XCTAssertFalse(source.contains("LoopTimelineView("), "\(path) should not host Player-only loop controls.")
            XCTAssertFalse(source.contains("practiceLoopRange"), "\(path) should not mutate Player-only loop state.")
        }
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
