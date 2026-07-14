import XCTest

final class BackbeatRootSourceTests: XCTestCase {
    func testRootStartsBackgroundLoudnessAnalysisForMissingProfiles() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("analyzeMissingLoudnessProfiles"))

        // The queue's analyze/commit closures live only in BackbeatApp.init —
        // a view-side fallback copy would drift from the production wiring.
        // (The version check `TrackLoudnessAnalyzerVersion` stays in the
        // sweep filter, so pin the analyzer CONSTRUCTION specifically.)
        let app = try readSource("Sources/Backbeat/App/BackbeatApp.swift")
        XCTAssertTrue(app.contains("TrackLoudnessAnalyzer(settings:"))
        XCTAssertTrue(app.contains("store.setLoudnessProfile"))
        XCTAssertFalse(source.contains("TrackLoudnessAnalyzer(settings:"))
    }

    func testPersistenceCoordinatorDebouncesLibrarySavesOffTheMainActor() throws {
        let source = try readSource("Sources/BackbeatCore/Stores/LibraryPersistenceCoordinator.swift")

        XCTAssertTrue(source.contains("pendingSave?.cancel()"))
        XCTAssertTrue(source.contains("try await Task.sleep"))
        XCTAssertTrue(source.contains("Task.detached"))
        XCTAssertTrue(source.contains("writer.write(snapshot, generation: generation)"))
        XCTAssertFalse(
            source.contains("try persistence.save(store: store)"),
            "the coordinator must save through the debounced generation-stamped writer, not a synchronous main-actor write per change"
        )
    }

    func testImportCompletionEnqueuesBackgroundRenderWithoutRoutingAway() throws {
        let core = try readSource("Sources/BackbeatCore/Services/TrackImportPipeline.swift")

        let importTrack = try XCTUnwrap(core.range(of: "let track = store.importTrack("))
        let enqueue = try XCTUnwrap(
            core.range(of: "renderQueue.enqueue(track.id)"),
            "Every import must queue a background render."
        )
        XCTAssertLessThan(importTrack.lowerBound, enqueue.lowerBound, "The track must exist in the store before it is enqueued.")

        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")
        XCTAssertFalse(source.contains("route = .preview"), "Import must leave the user where they are; there is no preview step.")
        XCTAssertFalse(source.contains("rankedPreviewCandidates"), "Import no longer runs spectrum preview analysis.")
    }

    func testDeleteCancelsQueuedRenderBeforeRemovingTheTrack() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        let cancel = try XCTUnwrap(source.range(of: "renderQueue.cancel(track.id)"))
        let delete = try XCTUnwrap(source.range(of: "try store.deleteTrack(id: track.id)"))
        XCTAssertLessThan(cancel.lowerBound, delete.lowerBound, "The in-flight demucs job must die before the track record disappears.")
    }

    func testLaunchScanReenqueuesMissingRenders() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("renderQueue.enqueueMissingRenders()"))
    }

    func testLaunchReconcilesLibraryFilesBeforeTheRenderScan() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        let reconcile = try XCTUnwrap(
            source.range(of: "store.reconcileLibraryFiles()"),
            "Statuses must be re-derived from disk before anything consumes them (D-107)."
        )
        let scan = try XCTUnwrap(source.range(of: "renderQueue.enqueueMissingRenders()"))
        XCTAssertLessThan(
            reconcile.lowerBound, scan.lowerBound,
            "Reconciliation must run before the launch scan, or the scan sees a stale `.ready` whose files are gone."
        )
    }

    func testLoudnessSweepSkipsTracksWithAMissingSourceFile() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(
            source.contains("guard track.status != .sourceMissing else { return false }"),
            "A missing source is a guaranteed-failing decode every launch (D-107)."
        )
    }

    func testRootSurfacesLibraryLoadRecoveryMessage() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("libraryLoadRecoveryMessage"))
        XCTAssertTrue(source.contains("Library could not be fully loaded"))
    }

    func testRootPresentsPlaybackFailures() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains(".alert(\"Playback failed\", isPresented: playbackFailureBinding)"))
        XCTAssertTrue(source.contains("store.playbackFailure?.userMessage"))
        XCTAssertTrue(source.contains("store.playbackFailure = nil"))
    }

    func testAppFlushesLibraryOnTermination() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")

        XCTAssertTrue(source.contains("applicationWillTerminate"))
        XCTAssertTrue(source.contains("persistLibraryOnTerminate"))
        XCTAssertTrue(source.contains("persistenceCoordinator.flushForTermination()"))
    }

    func testMainSceneIsASingleWindowNotAWindowGroup() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")

        XCTAssertTrue(
            source.contains("Window(\"Backline Boost\", id: \"main\")"),
            "One library session must have exactly one playback/import owner (D-103)."
        )
        XCTAssertFalse(
            source.contains("WindowGroup"),
            "WindowGroup restores Cmd+N: a second main window creates a second engine set and reopens the cross-window import TOCTOU (D-103 tripwire)."
        )
    }

    func testPlayerWaveformLoadIgnoresCancelledTasks() throws {
        let source = try readSource("Sources/Backbeat/Views/PlayerView.swift")

        let loadMethod = try XCTUnwrap(source.range(of: "private func loadWaveformEnvelope() async"))
        let cancelGuard = try XCTUnwrap(
            source.range(of: "guard !Task.isCancelled else { return }", range: loadMethod.lowerBound..<source.endIndex),
            "a cancelled waveform task must not overwrite state set by a newer task"
        )
        let nilAssignment = try XCTUnwrap(source.range(of: "waveformEnvelope = nil", range: loadMethod.lowerBound..<source.endIndex))
        XCTAssertNotNil(cancelGuard)
        XCTAssertNotNil(nilAssignment)
    }

    func testImportRunsHeavyPerFileWorkOffTheMainActorThroughASerialChain() throws {
        let source = try readSource("Sources/BackbeatCore/Services/TrackImportPipeline.swift")

        XCTAssertTrue(
            source.contains("Task.detached(priority: .userInitiated)"),
            "The per-file dedupe hash, byte copy, and artwork write must run off the MainActor so a batch import never freezes the UI (F2)."
        )
        XCTAssertTrue(
            source.contains("importChain"),
            "Every import entry point must serialize through one chain so two concurrent drops can't both pass the duplicate check before either commits (F2 TOCTOU)."
        )
    }

    func testRootWiresPerFileImportCommitsToTheLoudnessSweep() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(
            source.contains("pipeline.onTrackCommitted = { _ in analyzeMissingLoudnessProfiles() }"),
            "Each committed import must re-trigger the loudness sweep per file — batch-end triggering would be a silent behavior change (Phase B)."
        )
        XCTAssertTrue(
            source.contains("pipeline.onTrackCommitted = nil"),
            "The callback captures the view struct whose @State holds the pipeline — the onDisappear clear is what breaks the retain cycle when the window closes."
        )
    }

    func testAppWiresInSessionRenderRecoveryToTheQueue() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")

        XCTAssertTrue(
            source.contains("store.onRenderRecoveryNeeded = { [weak renderQueue]"),
            "In-session recovery must start the replacement render immediately, not strand the track until the next launch (COR-004)."
        )
        XCTAssertTrue(source.contains("renderQueue?.enqueue(trackID)"))
    }

    func testAppPersistsBackgroundRenderCompletionsWhileWindowClosed() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")

        XCTAssertTrue(
            source.contains("renderQueue.onLibraryChanged"),
            "A render completing while the window is closed must still schedule a save; the view's .onChange trigger is gone once its view dies (F8)."
        )
        XCTAssertTrue(source.contains("coordinator.noteLibraryChanged()"))
        XCTAssertFalse(
            source.contains("scheduleBackgroundLibrarySave"),
            "The duplicated app-delegate debounce is gone; the coordinator is the single save path (CLR-003)."
        )
    }

    func testLibrarySaveFailuresAreLoggedAndSurfacedNotSwallowed() throws {
        let coordinator = try readSource("Sources/BackbeatCore/Stores/LibraryPersistenceCoordinator.swift")
        XCTAssertTrue(
            coordinator.contains("DebugLog.persistence"),
            "A failed debounced save, and a failed terminate flush, must be logged instead of swallowed by print() (F12)."
        )
        XCTAssertTrue(
            coordinator.contains("saveFailureMessage"),
            "Repeated save failures must surface a banner so silent data loss is visible (F12)."
        )
        XCTAssertFalse(
            coordinator.contains("print(\"Backbeat library save failed"),
            "The print()-only failure path is replaced by logging plus a banner."
        )

        let root = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")
        XCTAssertTrue(
            root.contains("persistenceCoordinator.saveFailureMessage"),
            "The alert must read the coordinator's failure message, not a view-local one."
        )
        XCTAssertFalse(
            root.contains("scheduleLibrarySave"),
            "Library saves are debounced by the coordinator now, not a view-local scheduler."
        )
    }

    func testLoudnessSweepRoutesThroughTheDedupedQueueInsteadOfCancelAndRestart() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertFalse(
            source.contains("loudnessAnalysisTask"),
            "The cancel-and-restart Task is gone: its replacement scan re-included a track whose analysis was still running, forcing concurrent duplicate full-track decodes (EFF-001, formerly guarded by F15's commit-even-after-cancellation fix)."
        )
        XCTAssertTrue(
            source.contains("loudnessAnalysisQueue.enqueue(items)"),
            "The sweep must hand its pending list to the serial, deduplicated queue rather than cancelling and rescanning."
        )

        let app = try readSource("Sources/Backbeat/App/BackbeatApp.swift")
        XCTAssertTrue(
            app.contains("LoudnessAnalysisQueue("),
            "The commit closure is now provided at construction (BackbeatApp.init), not wired later via setCommit."
        )
        XCTAssertTrue(app.contains("store.setLoudnessProfile"))
    }

    func testLaunchStartsDurationBackfillSweepForUnresolvedTracks() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(
            source.contains("backfillImpreciseDurations()"),
            "The launch hook must invoke the duration backfill sweep alongside loudness analysis (Phase A)."
        )
        XCTAssertTrue(
            source.contains("!$0.isDurationResolved"),
            "The sweep must only collect tracks whose duration has not been precisely resolved yet, or every launch re-probes the whole library."
        )
        XCTAssertTrue(
            source.contains("!$0.isDurationResolved && $0.status != .sourceMissing"),
            "Probing a dead source path burns the one-shot isDurationResolved flag on a .keptEstimate — skip .sourceMissing like the loudness sweep does."
        )
    }

    func testDurationBackfillProbesPreciseDurationAndAppliesThroughTheStoreBeforePersisting() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(
            source.contains("AudioMetadataReader().preciseDuration"),
            "The sweep's probe must be the slim precise-duration reader (Task 5), not a full metadata read."
        )

        let resolveGuard = try XCTUnwrap(
            source.range(of: "guard store.applyDurationBackfill(id: trackID, outcome: outcome) else { return }"),
            "each resolution must apply through the single MainActor entry point on LibraryStore"
        )
        let persist = try XCTUnwrap(
            source.range(of: "persistenceCoordinator.noteLibraryChanged()", range: resolveGuard.upperBound..<source.endIndex),
            "a successful apply must persist the library"
        )
        XCTAssertLessThan(
            resolveGuard.lowerBound, persist.lowerBound,
            "persistenceCoordinator.noteLibraryChanged() must be gated behind the apply's return value so a no-op apply doesn't burn a debounced save cycle"
        )
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
