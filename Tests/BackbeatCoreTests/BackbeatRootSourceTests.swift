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
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        let importTrack = try XCTUnwrap(source.range(of: "let track = store.importTrack("))
        let enqueue = try XCTUnwrap(
            source.range(of: "renderQueue.enqueue(track.id)"),
            "Every import must queue a background render."
        )
        XCTAssertLessThan(importTrack.lowerBound, enqueue.lowerBound, "The track must exist in the store before it is enqueued.")
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

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
