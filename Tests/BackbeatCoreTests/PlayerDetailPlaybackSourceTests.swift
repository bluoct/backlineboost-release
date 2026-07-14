import XCTest

final class PlayerDetailPlaybackSourceTests: XCTestCase {
    func testPlayerDetailUsesSelectedTrackAndOnlyMirrorsPlaybackForNowPlayingTrack() throws {
        let source = try readSource("Sources/Backbeat/Views/PlayerView.swift")

        XCTAssertTrue(source.contains("store.selectedTrack ?? store.nowPlayingTrack"))
        XCTAssertTrue(source.contains("isDetailTrackNowPlaying"))
        XCTAssertTrue(source.contains("detailPlaybackProgress"))
        XCTAssertTrue(source.contains("detailIsPlaying"))
        XCTAssertTrue(source.contains("store.detailPlaybackAsset(for: track)"))
        XCTAssertTrue(source.contains("controlSource: renderControlSource"))
    }

    func testPlayerGuardsAgainstEmptyLibraryInsteadOfForceUnwrapping() throws {
        let source = try readSource("Sources/Backbeat/Views/PlayerView.swift")

        XCTAssertFalse(source.contains("store.tracks.first!"), "An empty library must route back instead of crashing on a force-unwrap.")
        XCTAssertTrue(source.contains("if let track = store.selectedTrack ?? store.nowPlayingTrack ?? store.tracks.first {"))
        XCTAssertTrue(source.contains("route = .library"))
    }

    func testLibraryAndSidebarOpenRenderedRowsForInspectionOnly() throws {
        let actions = try readSource("Sources/Backbeat/Views/TrackRowActions.swift")
        XCTAssertTrue(actions.contains("selectRenderedTrackForInspection(track.id)"), "TrackRowActions should inspect rendered rows without taking over now-playing.")
        XCTAssertTrue(actions.contains("selectTrackForPlayback(track.id, restart: true)"))

        // The sidebar keeps the shared single/double dispatcher (single-click
        // opens); the library's single-click became native List selection, so
        // only the double-click play routes through the shared helper there.
        let sidebar = try readSource("Sources/Backbeat/Views/SidebarView.swift")
        XCTAssertTrue(
            sidebar.contains("rowActions.tapGesture(for: track, queueing: sortedIDs)"),
            "SidebarView should route row taps through the shared TrackRowActions helper with the full sorted queue context."
        )
        let library = try readSource("Sources/Backbeat/Views/LibraryView.swift")
        XCTAssertTrue(
            library.contains("rowActions.playFromStart(track, queueing: visibleTrackIDs)"),
            "LibraryView double-click should play through the shared TrackRowActions helper with the visible-order queue context."
        )
        XCTAssertTrue(
            library.contains("rowActions.open(track)"),
            "LibraryView should keep an explicit open-in-Player affordance now that single-click selects."
        )

        for path in [
            "Sources/Backbeat/Views/TrackRowActions.swift",
            "Sources/Backbeat/Views/LibraryView.swift",
            "Sources/Backbeat/Views/SidebarView.swift"
        ] {
            let source = try readSource(path)
            XCTAssertFalse(source.contains("if track.status == .ready, store.selectTrackForPlayback(track.id)"), "\(path) should not make single-click/open mutate now-playing.")
        }
    }

    func testPlaybackSourceSwitchOnlySamplesElapsedForCurrentRenderSession() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(source.contains("let isCurrentRender = mode == .render(track.id)"))
        XCTAssertTrue(source.contains("if isCurrentRender {"))
        XCTAssertTrue(source.contains("store.selectDetailPlaybackSource(source, for: track)"))
        XCTAssertTrue(source.contains("store.selectNowPlayingPlaybackSource(source, for: track)"))
    }

    func testAudioControllerPlaysResolvedPlaybackAssetsAndAdvancesQueue() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(source.contains("func playTrack("))
        XCTAssertTrue(source.contains("store.playbackAsset(for: track, preferredSource:"))
        XCTAssertTrue(source.contains("store.advanceQueue()"))
        XCTAssertTrue(source.contains("switchPlaybackSource"))
    }

    func testAudioControllerRoutesDrumBoostThroughTwoTrackMixEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(source.contains("private let twoTrackMixEngine = TwoTrackMixPlaybackEngine()"))
        XCTAssertTrue(source.contains("private enum RenderPlaybackBackend"))
        XCTAssertTrue(source.contains("private var renderPlaybackBackend: RenderPlaybackBackend?"))
        XCTAssertTrue(source.contains("if source == .drumBoost"))
        XCTAssertTrue(source.contains("store.twoTrackMixAsset(for: track, preferredSource: .drumBoost)"))
        XCTAssertTrue(source.contains("try twoTrackMixEngine.play(asset:"))
        XCTAssertTrue(source.contains("renderPlaybackBackend = .twoTrackMix(track.id)"))
        XCTAssertTrue(source.contains("activeRenderEngine(for: track)"))
        XCTAssertTrue(source.contains("return twoTrackMixEngine"))
        XCTAssertTrue(source.contains("twoTrackMixEngine.setMixSettings("))
    }

    func testAudioControllerRoutesNormalizationGainIntoPlaybackEngines() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(source.contains("private let singleFileEngine = SingleFilePlaybackEngine()"))
        XCTAssertTrue(source.contains("store.normalizationGainDB(for: track)"))
        XCTAssertTrue(source.contains("normalizationGainDB:"))
        XCTAssertTrue(source.contains("renderPlaybackBackend = .singleFile(track.id)"))
    }

    func testAudioControllerStopsStoreStateWhenTwoTrackMixFails() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(source.contains("catch {"))
        XCTAssertTrue(source.contains("renderPlaybackBackend = nil"))
        XCTAssertTrue(source.contains("store.nowPlayingTrackID = track.id"))
        XCTAssertTrue(source.contains("store.setActiveQueueSource(.drumBoost)"))
        XCTAssertTrue(source.contains("store.setPlaybackPlaying(false)"))
        XCTAssertTrue(source.contains("store.setPlaybackElapsed(startElapsed, duration: transportDuration(for: track))"))
        XCTAssertTrue(source.contains("store.playbackFailure = .renderUnplayable"))
        XCTAssertFalse(source.contains("playbackErrorMessage"))
        XCTAssertFalse(source.contains("store.playbackFailure = error"))
        XCTAssertTrue(source.contains("isRenderFallback"))
        XCTAssertTrue(source.contains(".fallbackFailed"))
        XCTAssertTrue(source.contains("store.noteOriginalSourceMissing(for: track.id)"))
        XCTAssertTrue(source.contains("store.playbackFailure = .sourceFileMissing"))
        // Classification and recovery key on what actually played, not the
        // preferred source — a render-preferring source resolves to Original
        // when no renders exist yet.
        XCTAssertTrue(source.contains("if asset.effectiveSource == .original, store.noteOriginalSourceMissing(for: track.id)"))
        XCTAssertTrue(source.contains("if asset.effectiveSource != .original, store.recoverMissingRenderFiles(for: track.id)"))
        XCTAssertFalse(source.contains("source == .original ? .originalUnplayable"))
        XCTAssertTrue(source.contains("store.noteOriginalSourceRestored(for: track.id)"))
    }

    func testPracticeLoopBoundsSyncTheActiveRenderEngineChain() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(source.contains("let engine = activeRenderEngine(for: track)"))
        XCTAssertTrue(source.contains("let current = engine.currentElapsed()"))
        XCTAssertTrue(
            source.contains("engine.setSectionLoop("),
            "Bounds edits push the loop into the engine's pre-scheduled chain instead of seeking every wrap (D-094)."
        )
        XCTAssertTrue(
            source.contains("store.setPlaybackElapsed(range.start, duration: duration)"),
            "The immediate store write preserves the old snap UX while the debounced chain rebuild settles behind it."
        )
    }

    func testPlayerDetailUsesRoutablePlaybackSourcePicker() throws {
        let source = try readSource("Sources/Backbeat/Views/PlayerView.swift")
        let controls = try readSource("Sources/Backbeat/Views/PlaybackSourceControls.swift")

        XCTAssertTrue(source.contains("PlaybackSourcePicker("))
        XCTAssertTrue(source.contains("store.detailPlaybackAsset(for: track)"))
        XCTAssertTrue(source.contains("playback.switchPlaybackSource(source, track: track, store: store, controlSource: renderControlSource)"))
        XCTAssertTrue(controls.contains("ForEach(PlaybackSource.controlCases, id: \\.self)"))
        XCTAssertFalse(controls.contains("ForEach(PlaybackSource.allCases, id: \\.self)"))
    }

    func testPlayerDetailUsesNowPlayingSourceControlsForCurrentTrack() throws {
        let source = try readSource("Sources/Backbeat/Views/PlayerView.swift")

        XCTAssertTrue(source.contains("private var renderControlSource: AudioPlaybackController.RenderControlSource"))
        XCTAssertTrue(source.contains("isDetailTrackNowPlaying ? .nowPlaying : .detail"))
        XCTAssertTrue(source.contains("store.nowPlayingPlaybackSource : store.selectedPlaybackSource"))
        XCTAssertTrue(source.contains("playback.toggleRender(track: track, store: store, source: renderControlSource)"))
    }

    func testPlayerDetailExposesQueuePreviousAndNextControls() throws {
        let source = try readSource("Sources/Backbeat/Views/PlayerView.swift")

        XCTAssertTrue(source.contains("Image(systemName: \"backward.end.fill\")"))
        XCTAssertTrue(source.contains("Image(systemName: \"forward.end.fill\")"))
        XCTAssertTrue(source.contains("playback.playPreviousInQueue(store: store)"))
        XCTAssertTrue(source.contains("playback.playNextInQueue(store: store)"))
        XCTAssertTrue(source.contains(".disabled(!store.canPlayPreviousInQueue)"))
        XCTAssertTrue(source.contains(".disabled(!store.canPlayNextInQueue)"))
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
