import XCTest
@testable import BackbeatCore

@MainActor
final class RenderQueueCoordinatorTests: XCTestCase {
    func testEnqueueStartsRenderWithoutStealingSelection() async throws {
        let (store, executor, coordinator) = makeFixture()
        let trackA = importTrack(store, title: "A")
        let trackB = importTrack(store, title: "B")
        store.selectedTrackID = trackB.id

        coordinator.enqueue(trackA.id)

        try await waitUntil { await executor.started == [trackA.id] }
        XCTAssertEqual(coordinator.activeTrackID, trackA.id)
        XCTAssertEqual(store.track(id: trackA.id)?.status, .rendering)
        XCTAssertEqual(store.selectedTrackID, trackB.id, "a background render must not steal selection")
    }

    func testRendersSerializeInFIFOOrder() async throws {
        let (store, executor, coordinator) = makeFixture()
        let trackA = importTrack(store, title: "A")
        let trackB = importTrack(store, title: "B")

        coordinator.enqueue(trackA.id)
        coordinator.enqueue(trackB.id)

        try await waitUntil { await executor.started == [trackA.id] }
        XCTAssertEqual(coordinator.pendingTrackIDs, [trackB.id])
        XCTAssertEqual(store.track(id: trackB.id)?.status, .imported, "queued tracks stay imported until their job starts")

        let firstTask = coordinator.activeRenderTask
        await executor.completeNext(.success(makeResult()))
        await firstTask?.value

        XCTAssertEqual(store.track(id: trackA.id)?.status, .ready)
        try await waitUntil { await executor.started == [trackA.id, trackB.id] }
        XCTAssertEqual(coordinator.activeTrackID, trackB.id)
        XCTAssertTrue(coordinator.pendingTrackIDs.isEmpty)
    }

    func testSuccessPromotesRendersAndPreservesLiveTunedDrumMix() async throws {
        let (store, executor, coordinator) = makeFixture()
        let track = importTrack(store, title: "A")
        store.setDrumMixBoostDB(6.5, for: track.id)

        coordinator.enqueue(track.id)
        try await waitUntil { await executor.started == [track.id] }
        let task = coordinator.activeRenderTask
        let result = makeResult()
        await executor.completeNext(.success(result))
        await task?.value

        let updated = store.track(id: track.id)
        XCTAssertEqual(updated?.status, .ready)
        XCTAssertEqual(updated?.activeRender(for: .drums)?.fileURL, result.drumsURL)
        XCTAssertEqual(updated?.activeRender(for: .drumless)?.fileURL, result.drumlessURL)
        XCTAssertEqual(updated?.drumMixSettings, DrumMixSettings(boostDB: 6.5))
        XCTAssertNil(coordinator.activeTrackID)
        XCTAssertEqual(coordinator.activeProgress, .idle)
    }

    func testFailureMarksTrackFailedAndContinuesToNext() async throws {
        let (store, executor, coordinator) = makeFixture()
        let trackA = importTrack(store, title: "A")
        let trackB = importTrack(store, title: "B")

        coordinator.enqueue(trackA.id)
        coordinator.enqueue(trackB.id)
        try await waitUntil { await executor.started == [trackA.id] }
        let task = coordinator.activeRenderTask
        await executor.completeNext(.failure(StubRenderError.demucsExploded))
        await task?.value

        XCTAssertEqual(store.track(id: trackA.id)?.status, .renderFailed)
        XCTAssertNotNil(store.renderFailureMessage)
        try await waitUntil { await executor.started == [trackA.id, trackB.id] }
        XCTAssertEqual(coordinator.activeTrackID, trackB.id, "one failure must not stall the queue")
    }

    func testCancelPendingRemovesTrackWithoutRendering() async throws {
        let (store, executor, coordinator) = makeFixture()
        let trackA = importTrack(store, title: "A")
        let trackB = importTrack(store, title: "B")

        coordinator.enqueue(trackA.id)
        coordinator.enqueue(trackB.id)
        try await waitUntil { await executor.started == [trackA.id] }

        coordinator.cancel(trackB.id)

        XCTAssertTrue(coordinator.pendingTrackIDs.isEmpty)
        XCTAssertEqual(store.track(id: trackB.id)?.status, .imported)
        let task = coordinator.activeRenderTask
        await executor.completeNext(.success(makeResult()))
        await task?.value
        let started = await executor.started
        XCTAssertEqual(started, [trackA.id], "a cancelled pending track must never start")
    }

    func testCancelActiveRevertsTrackToImportedAndAdvances() async throws {
        let (store, executor, coordinator) = makeFixture()
        let trackA = importTrack(store, title: "A")
        let trackB = importTrack(store, title: "B")

        coordinator.enqueue(trackA.id)
        coordinator.enqueue(trackB.id)
        try await waitUntil { await executor.started == [trackA.id] }
        let task = coordinator.activeRenderTask

        coordinator.cancel(trackA.id)
        await task?.value

        XCTAssertEqual(store.track(id: trackA.id)?.status, .imported, "cancellation is not a failure")
        XCTAssertNil(store.track(id: trackA.id)?.activeRender(for: .drums))
        try await waitUntil { await executor.started == [trackA.id, trackB.id] }
        XCTAssertEqual(coordinator.activeTrackID, trackB.id)
    }

    func testTrackDeletedMidRenderSkipsPromotionAndRemovesOrphanFiles() async throws {
        let (store, executor, coordinator) = makeFixture()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sourceURL = temporaryRoot.appendingPathComponent("a.m4a")
        try Data("source".utf8).write(to: sourceURL)
        let track = store.importTrack(
            from: AudioMetadata(fileName: "A", duration: 100, sampleRate: 44_100, channelCount: 2),
            sourceURL: sourceURL
        )

        coordinator.enqueue(track.id)
        try await waitUntil { await executor.started == [track.id] }

        try store.deleteTrack(id: track.id)

        let drumsURL = temporaryRoot.appendingPathComponent("orphan_drums.m4a")
        let drumlessURL = temporaryRoot.appendingPathComponent("orphan_drumless.m4a")
        try Data("drums".utf8).write(to: drumsURL)
        try Data("drumless".utf8).write(to: drumlessURL)

        let task = coordinator.activeRenderTask
        await executor.completeNext(.success(PracticeRenderResult(drumsURL: drumsURL, drumlessURL: drumlessURL)))
        await task?.value

        XCTAssertNil(store.track(id: track.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drumsURL.path), "orphaned render outputs must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drumlessURL.path))
    }

    func testDuplicateEnqueueIsANoOp() async throws {
        let (store, executor, coordinator) = makeFixture()
        let track = importTrack(store, title: "A")

        coordinator.enqueue(track.id)
        coordinator.enqueue(track.id)
        try await waitUntil { await executor.started == [track.id] }
        coordinator.enqueue(track.id)

        XCTAssertTrue(coordinator.pendingTrackIDs.isEmpty)
        let task = coordinator.activeRenderTask
        await executor.completeNext(.success(makeResult()))
        await task?.value
        let started = await executor.started
        XCTAssertEqual(started, [track.id])
    }

    func testEnqueueMissingRendersPicksUnrenderedAndStaleRenderingInLibraryOrder() async throws {
        let (store, executor, coordinator) = makeFixture()
        let ready = importTrack(store, title: "Ready")
        let unrendered = importTrack(store, title: "Unrendered")
        let stale = importTrack(store, title: "Stale")
        let failed = importTrack(store, title: "Failed")
        store.completePracticeRender(for: ready.id, result: makeResult())
        store.beginRendering(for: stale.id)
        store.markRenderFailed(for: failed.id, message: "boom")

        coordinator.enqueueMissingRenders()

        try await waitUntil { await executor.started == [unrendered.id] }
        XCTAssertEqual(coordinator.pendingTrackIDs, [stale.id])
        XCTAssertEqual(coordinator.queuePosition(of: stale.id), 1)
    }

    func testStatusDisplayCoversQueuedRenderingAndFailedStates() async throws {
        let (store, executor, coordinator) = makeFixture()
        let trackA = importTrack(store, title: "A")
        let trackB = importTrack(store, title: "B")

        coordinator.enqueue(trackA.id)
        coordinator.enqueue(trackB.id)
        try await waitUntil { await executor.started == [trackA.id] }

        let active = coordinator.statusDisplay(for: store.track(id: trackA.id)!)
        XCTAssertEqual(active?.title, "Separating stems")
        let queued = coordinator.statusDisplay(for: store.track(id: trackB.id)!)
        XCTAssertEqual(queued?.title, "Waiting to render (#1)")

        let task = coordinator.activeRenderTask
        await executor.completeNext(.failure(StubRenderError.demucsExploded))
        await task?.value
        // B is the active render now; cancel it and wait for the revert.
        try await waitUntil { await executor.started.count == 2 }
        let taskB = coordinator.activeRenderTask
        coordinator.cancel(trackB.id)
        await taskB?.value

        let failed = coordinator.statusDisplay(for: store.track(id: trackA.id)!)
        XCTAssertEqual(failed?.title, "Render failed")
        XCTAssertEqual(failed?.actionTitle, "Retry render")
        XCTAssertNil(coordinator.statusDisplay(for: store.track(id: trackB.id)!))
    }

    // MARK: - Fixture

    private func makeFixture() -> (LibraryStore, GatedRenderExecutor, RenderQueueCoordinator) {
        let store = LibraryStore()
        let executor = GatedRenderExecutor()
        let coordinator = RenderQueueCoordinator(store: store) { track, _ in
            try await executor.render(track: track)
        }
        return (store, executor, coordinator)
    }

    private func importTrack(_ store: LibraryStore, title: String) -> BackbeatTrack {
        store.importTrack(
            from: AudioMetadata(fileName: title, duration: 100, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/\(title)-\(UUID().uuidString).m4a")
        )
    }

    private func makeResult() -> PracticeRenderResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return PracticeRenderResult(
            drumsURL: root.appendingPathComponent("drums.m4a"),
            drumlessURL: root.appendingPathComponent("drumless.m4a")
        )
    }

    private func waitUntil(
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
            try await Task.sleep(for: .microseconds(50))
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

private enum StubRenderError: LocalizedError {
    case demucsExploded

    var errorDescription: String? { "demucs exploded" }
}

/// Hermetic render execution gated on explicit completion, so tests control
/// exactly when each job finishes and can observe serialization.
private actor GatedRenderExecutor {
    private var pending: [CheckedContinuation<PracticeRenderResult, Error>] = []
    private(set) var started: [BackbeatTrack.ID] = []

    func render(track: BackbeatTrack) async throws -> PracticeRenderResult {
        started.append(track.id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func completeNext(_ result: Result<PracticeRenderResult, Error>) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(with: result)
    }

    private func cancelAll() {
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
        pending.removeAll()
    }
}
