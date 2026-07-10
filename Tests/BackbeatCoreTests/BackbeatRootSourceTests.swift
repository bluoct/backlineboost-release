import XCTest

final class BackbeatRootSourceTests: XCTestCase {
    func testRootStartsBackgroundLoudnessAnalysisForMissingProfiles() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("TrackLoudnessAnalyzer"))
        XCTAssertTrue(source.contains("analyzeMissingLoudnessProfiles"))
        XCTAssertTrue(source.contains("store.setLoudnessProfile"))
    }

    func testRootDebouncesLibrarySavesOffTheMainActor() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("pendingLibrarySave?.cancel()"))
        XCTAssertTrue(source.contains("try await Task.sleep"))
        XCTAssertTrue(source.contains("Task.detached"))
        XCTAssertTrue(source.contains("writer.write(snapshot, generation: generation)"))
        XCTAssertFalse(
            source.contains("try persistence.save(store: store)"),
            "root view saves must go through the debounced generation-stamped writer, not a synchronous main-actor write per change"
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

    func testRootSurfacesLibraryLoadRecoveryMessage() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("libraryLoadRecoveryMessage"))
        XCTAssertTrue(source.contains("Library could not be fully loaded"))
    }

    func testAppFlushesLibraryOnTermination() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")

        XCTAssertTrue(source.contains("applicationWillTerminate"))
        XCTAssertTrue(source.contains("persistLibraryOnTerminate"))
        XCTAssertTrue(source.contains("libraryWriter.write(LibrarySnapshot(store: store)"))
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

    func testAppPersistsBackgroundRenderCompletionsWhileWindowClosed() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")

        XCTAssertTrue(
            source.contains("renderQueue.onLibraryChanged"),
            "A render completing while the window is closed must still schedule a save; the view's .onChange trigger is gone once its view dies (F8)."
        )
        XCTAssertTrue(source.contains("scheduleBackgroundLibrarySave"))
    }

    func testLibrarySaveFailuresAreLoggedAndSurfacedNotSwallowed() throws {
        let root = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")
        XCTAssertTrue(
            root.contains("DebugLog.persistence"),
            "A failed debounced save must be logged, not swallowed by print() (F12)."
        )
        XCTAssertTrue(
            root.contains("librarySaveFailureMessage"),
            "Repeated save failures must surface a banner so silent data loss is visible (F12)."
        )
        XCTAssertFalse(
            root.contains("print(\"Backbeat library save failed"),
            "The print()-only failure path is replaced by logging plus a banner."
        )

        let app = try readSource("Sources/Backbeat/App/BackbeatApp.swift")
        XCTAssertTrue(
            app.contains("DebugLog.persistence"),
            "The terminate flush must log a write failure instead of swallowing it with try? (F12)."
        )
    }

    func testLoudnessAnalysisCommitsComputedProfilesEvenAfterCancellation() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")
        let taskStart = try XCTUnwrap(
            source.range(of: "loudnessAnalysisTask = Task"),
            "loudness analysis task missing"
        )
        let body = source[taskStart.lowerBound...]
        let cancellationGuards = body.components(separatedBy: "guard !Task.isCancelled").count - 1
        XCTAssertEqual(
            cancellationGuards,
            1,
            "Only the pre-analyze cancellation guard may remain; the post-analyze guard discarded a fully computed profile and forced a duplicate decode (F15)."
        )
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
            source.range(of: "persistLibrary()", range: resolveGuard.upperBound..<source.endIndex),
            "a successful apply must persist the library"
        )
        XCTAssertLessThan(
            resolveGuard.lowerBound, persist.lowerBound,
            "persistLibrary() must be gated behind the apply's return value so a no-op apply doesn't burn a debounced save cycle"
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
