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

        let loopBoundsBody = try methodBody(source, signature: "private func syncEngineSectionLoop(track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(loopBoundsBody.contains("activeRenderEngine(for: track)"))
        XCTAssertTrue(loopBoundsBody.contains("setSectionLoop("))
    }

    func testControllerResolvesTransportDurationFromTheActiveEngineWithTrackDurationFallback() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(
            source.contains("private func transportDuration(for track: BackbeatTrack) -> TimeInterval {"),
            "One resolved-duration helper must back every transport site so file-derived duration and track.duration never disagree (Task 2)."
        )
        XCTAssertTrue(
            source.contains("activeRenderEngine(for: track)?.transportDuration ?? track.duration"),
            "The active engine's file-derived duration must win; track.duration is only the no-engine fallback."
        )

        let tickBody = try methodBody(source, signature: "private func tickRenderEngine(_ engine: RenderPlaybackEngine, track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(
            tickBody.contains("duration: transportDuration(for: track)"),
            "Building the tick schedule from track.duration while the engine clock clamps at the file-derived duration made .finished unreachable (F1 companion fix)."
        )
        XCTAssertFalse(
            tickBody.contains("duration: track.duration"),
            "tickRenderEngine must not build the schedule off the raw persisted estimate."
        )
    }

    func testSyncEngineSectionLoopSnapGuardsAgainstPastEOFRanges() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let loopBoundsBody = try methodBody(source, signature: "private func syncEngineSectionLoop(track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(
            loopBoundsBody.contains("let duration = transportDuration(for: track)"),
            "The loop-bounds guard must consult the resolved transport duration, not the raw persisted estimate."
        )
        XCTAssertTrue(
            loopBoundsBody.contains("guard range.start < duration else { return }"),
            "A loop start at/past the file-derived duration must not seek past EOF; the clamped PracticePlaybackSchedule (and the engine's linear degrade) take over instead of overshooting once (Phase A semantics)."
        )
        XCTAssertTrue(
            loopBoundsBody.contains("store.setPlaybackElapsed(range.start, duration: duration)"),
            "The commit must use the same resolved duration the guard just checked against."
        )
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

    func testControllerReflectsHardwareInterruptionAsPaused() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(
            source.contains("onPlaybackInterrupted"),
            "The controller must wire the engines' hardware-interruption signal (F3)."
        )
        let handler = try methodBody(source, signature: "private func handlePlaybackInterrupted(elapsed: TimeInterval)")
        XCTAssertTrue(
            handler.contains("setPlaybackPlaying(false)"),
            "A hardware interruption must reflect as paused, not silent 'playing' (F3)."
        )
    }

    func testNormalizationAndVolumeChangesShareOneGainApplyPath() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(
            source.contains("func applyOutputGain(store: LibraryStore)"),
            "Volume and normalization changes must share one gain-apply path (F4)."
        )
        XCTAssertTrue(
            try methodBody(source, signature: "func updateVolume(toProgress progress: Double, store: LibraryStore)")
                .contains("applyOutputGain(store: store)")
        )

        let root = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")
        XCTAssertTrue(
            root.contains("playback.applyOutputGain(store: store)"),
            "The Normalize toggle lives in the Settings scene; the main window must re-apply gain on the change so it reaches live playback (F4)."
        )
    }

    func testSectionLoopWrapIsOwnedByTheEngineChain() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let tickBody = try methodBody(source, signature: "private func tickRenderEngine(_ engine: RenderPlaybackEngine, track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(
            tickBody.contains("engine.isSectionLoopChainActive"),
            "The chain renders the seam; a transient float/debounce .wrap must not flush it (D-094)."
        )
        XCTAssertFalse(
            source.contains("0.03"),
            "The faster section-loop poll is gone — wrap ownership moved into the pre-scheduled engine chain (D-094)."
        )
    }

    func testPlayPassesTheEffectiveSectionLoopToTheEngines() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let occurrences = source.components(separatedBy: "sectionLoop: effectiveSectionLoop(store: store)").count - 1
        XCTAssertEqual(
            occurrences,
            2,
            "Both playTrack and playTwoTrackMix must pass the effective section loop into their engine's play() call."
        )
    }

    func testResumeDoesNotStopTheTargetEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(
            source.contains("private func prepareForPlayback(target: RenderPlaybackBackend)"),
            "Stopping the target engine would destroy the pre-scheduled chain the pause/resume contract preserves (D-094)."
        )

        let playTrackBody = try methodBody(
            source,
            signature: "func playTrack(\n        track: BackbeatTrack,\n        store: LibraryStore,\n        source: PlaybackSource,\n        startElapsed: TimeInterval? = nil,\n        isRenderFallback: Bool = false\n    )"
        )
        XCTAssertTrue(playTrackBody.contains("prepareForPlayback(target: .singleFile(track.id))"))
        XCTAssertTrue(
            playTrackBody.contains("catch {\n            stopCurrent()"),
            "A failed play must still silence everything — stopCurrent() must be the catch block's first statement."
        )

        let playTwoTrackMixBody = try methodBody(
            source,
            signature: "private func playTwoTrackMix(track: BackbeatTrack, asset: TwoTrackMixAsset, store: LibraryStore, startElapsed: TimeInterval)"
        )
        XCTAssertTrue(playTwoTrackMixBody.contains("prepareForPlayback(target: .twoTrackMix(track.id))"))
        XCTAssertTrue(
            playTwoTrackMixBody.contains("catch {\n            stopCurrent()"),
            "A failed play must still silence everything — stopCurrent() must be the catch block's first statement."
        )
    }

    func testStoreSideLoopClearsReachTheEngines() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let resetBody = try methodBody(source, signature: "func resetPracticePlayback(store: LibraryStore)")
        XCTAssertTrue(
            resetBody.contains("singleFileEngine.setSectionLoop(nil)") && resetBody.contains("twoTrackMixEngine.setSectionLoop(nil)"),
            "The route-change zombie loop: with wrap ownership in the chain, a store-only clear leaves audio looping A→B forever."
        )
    }

    func testMarkerCaptureReadsTheEngineNotThePolledStore() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let startBody = try methodBody(source, signature: "func capturePracticeLoopStart(track: BackbeatTrack, store: LibraryStore)")
        let endBody = try methodBody(source, signature: "func capturePracticeLoopEnd(track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(
            startBody.contains("currentRenderElapsed(store: store)") && endBody.contains("currentRenderElapsed(store: store)"),
            "The 0.2s UI poll is too stale for a precision feature; marker capture must read the engine's live position."
        )
    }

    func testSyncEngineSectionLoopResolvesThroughTheControllersOwnMode() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let syncBody = try methodBody(source, signature: "private func syncEngineSectionLoop(track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(
            syncBody.contains("guard case .render(let activeTrackID) = mode"),
            "Loop edits can arrive from a detail view of a different track, and nowPlayingTrackID is hijackable by a detail-view scrub without playback — only the controller's own mode names the live engine. Resolving any other way re-opens the zombie-loop class."
        )
        XCTAssertFalse(
            syncBody.contains("store.nowPlayingTrack ??"),
            "nowPlayingTrackID must not be the resolution source here (seekRender mutates it for non-playing tracks)."
        )
    }

    func testSeekRenderRefusesTracksWithoutALiveSession() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let seekBody = try methodBody(source, signature: "func seekRender(toProgress progress: Double, track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(
            seekBody.contains("let ownsLiveSession = mode == .render(track.id)"),
            "During a live session, only its own track may scrub — resolution goes through the controller's own mode (D-100), never nowPlayingTrackID (COR-002)."
        )
        XCTAssertTrue(
            seekBody.contains("let transportIsFree = !store.isPlaybackSessionActive"),
            "With no live session the transport is free: a scrub may anchor any track to pick a start point or a replay position (D-108); only a bystander scrub DURING another track's live session is refused."
        )
        let guardRange = try XCTUnwrap(
            seekBody.range(of: "guard ownsLiveSession || transportIsFree else { return }"),
            "seekRender must be a no-op exactly when another track owns the live session (COR-002, D-108)."
        )
        let identityAssignment = try XCTUnwrap(seekBody.range(of: "store.nowPlayingTrackID = track.id"))
        XCTAssertLessThan(
            guardRange.lowerBound,
            identityAssignment.lowerBound,
            "The ownership guard must run before the anchor write, or a detail-view scrub during another track's session can still hijack the transport (COR-002)."
        )
    }

    func testPracticeEditsRefuseBystanderTracksDuringAnotherTracksLiveSession() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        // The shared guard mirrors seekRender's rule (D-108), extended to
        // every practice edit after owner QA (2026-07-13) caught a bystander
        // track's loop-marker drag yanking the live session's playhead: the
        // practice loop and speed are global store state resolving to the
        // LIVE engine (D-100), so the edit itself must be refused.
        let helperBody = try methodBody(
            source,
            signature: "private func allowsPracticeEdit(track: BackbeatTrack, store: LibraryStore) -> Bool"
        )
        XCTAssertTrue(helperBody.contains("let ownsLiveSession = mode == .render(track.id)"))
        XCTAssertTrue(helperBody.contains("let transportIsFree = !store.isPlaybackSessionActive"))

        for signature in [
            "func setPracticeSpeed(_ speed: Double, track: BackbeatTrack, store: LibraryStore)",
            "func stepPracticeSpeed(by delta: Double, track: BackbeatTrack, store: LibraryStore)",
            "func setPracticeLoopMode(_ mode: PracticeLoopMode, track: BackbeatTrack, store: LibraryStore)",
            "func setPracticeLoopStart(_ elapsed: TimeInterval, track: BackbeatTrack, store: LibraryStore)",
            "func setPracticeLoopEnd(_ elapsed: TimeInterval, track: BackbeatTrack, store: LibraryStore)",
            "func clearPracticeLoop(track: BackbeatTrack, store: LibraryStore)"
        ] {
            let body = try methodBody(source, signature: signature)
            XCTAssertTrue(
                body.contains("guard allowsPracticeEdit(track: track, store: store) else { return }"),
                "\(signature) must refuse a bystander edit during another track's live session"
            )
        }

        // And the affordance disables rather than sitting dead (the D-108
        // review's enabled-but-dead-control lesson).
        let controls = try readSource("Sources/Backbeat/Views/PracticeControlsView.swift")
        XCTAssertTrue(controls.contains("isPracticeEditingEnabled"))
        XCTAssertTrue(controls.contains(".disabled(!isPracticeEditingEnabled)"))
        let player = try readSource("Sources/Backbeat/Views/PlayerView.swift")
        XCTAssertTrue(player.contains("isPracticeEditingEnabled: !store.isPlaybackSessionActive || store.nowPlayingTrackID == track.id"))
    }

    func testDrumMixPushResolvesThroughTheControllersOwnMode() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let mixBody = try methodBody(source, signature: "func setDrumMixBoostDB(_ boostDB: Double, track: BackbeatTrack, store: LibraryStore)")
        XCTAssertTrue(
            mixBody.contains("store.setDrumMixBoostDB(boostDB, for: track.id)"),
            "Saving an edited track's boost must stay unconditional — any track's saved settings may be edited even while a different track plays (D-060)."
        )
        let saveRange = try XCTUnwrap(mixBody.range(of: "store.setDrumMixBoostDB(boostDB, for: track.id)"))
        let guardRange = try XCTUnwrap(
            mixBody.range(of: "guard case .render(let activeTrackID) = mode, activeTrackID == track.id"),
            "The live-engine push must resolve through the controller's own mode (D-100): editing an inspected track's saved boost must not bleed into another track's live audio (D-060)."
        )
        XCTAssertLessThan(
            saveRange.lowerBound,
            guardRange.lowerBound,
            "The store save must happen before the live-engine guard so editing a non-playing track's boost still persists even with no live session."
        )
    }

    func testPrepareForPlaybackStopsOnlyTheNonTargetEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        let prepareBody = try methodBody(source, signature: "private func prepareForPlayback(target: RenderPlaybackBackend)")
        let singleCase = try XCTUnwrap(prepareBody.range(of: "case .singleFile:"))
        let stopsTwoTrack = try XCTUnwrap(prepareBody.range(of: "twoTrackMixEngine.stop()"))
        let twoTrackCase = try XCTUnwrap(prepareBody.range(of: "case .twoTrackMix:"))
        let stopsSingle = try XCTUnwrap(prepareBody.range(of: "singleFileEngine.stop()"))
        XCTAssertLessThan(singleCase.lowerBound, stopsTwoTrack.lowerBound)
        XCTAssertLessThan(stopsTwoTrack.lowerBound, twoTrackCase.lowerBound)
        XCTAssertLessThan(
            twoTrackCase.lowerBound,
            stopsSingle.lowerBound,
            "Each case must stop ONLY the engine it is not about to play — stopping the target destroys the pre-scheduled chain the pause/resume contract preserves (D-094)."
        )
    }

    func testDeletedRenderFilesRecoverAndFallBackToOriginal() throws {
        let source = try readSource("Sources/Backbeat/Services/AudioPlaybackController.swift")

        XCTAssertTrue(
            source.contains("recoverMissingRenderFiles"),
            "A rendered file deleted on disk must be recovered instead of surfacing a raw error forever (F7)."
        )
        let mixBody = try methodBody(
            source,
            signature: "private func playTwoTrackMix(track: BackbeatTrack, asset: TwoTrackMixAsset, store: LibraryStore, startElapsed: TimeInterval)"
        )
        XCTAssertTrue(
            mixBody.contains("source: .original"),
            "A Drum Boost failure must fall back to Original instead of dead-ending (F7)."
        )
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
