import XCTest
@testable import BackbeatCore

/// Behavioral coverage for re-rendering an already-`.ready` track (COR-008,
/// D-105): the old Drums/Drumless pair must keep playing while the new job is
/// in flight, survive a failure untouched, and only be deleted once a fresh
/// render actually succeeds.
@MainActor
final class ReadyTrackReRenderTests: XCTestCase {
    func testEnqueueingAReadyTrackStartsRenderingWithBothOldRecordsIntact() async throws {
        let (store, executor, coordinator) = makeFixture()
        let (track, oldDrumsURL, oldDrumlessURL) = try makeReadyTrack(store, title: "A")

        coordinator.enqueue(track.id)

        try await waitUntil { await executor.started == [track.id] }
        let updated = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(updated.status, .rendering)
        XCTAssertEqual(updated.activeRender(for: .drums)?.fileURL, oldDrumsURL)
        XCTAssertEqual(updated.activeRender(for: .drumless)?.fileURL, oldDrumlessURL)
    }

    func testFailedReRenderKeepsOldRecordsAndFilesOnDisk() async throws {
        let (store, executor, coordinator) = makeFixture()
        let (track, oldDrumsURL, oldDrumlessURL) = try makeReadyTrack(store, title: "A")

        coordinator.enqueue(track.id)
        try await waitUntil { await executor.started == [track.id] }
        let task = coordinator.activeRenderTask
        await executor.completeNext(.failure(StubReRenderError.boom))
        await task?.value

        let updated = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(updated.status, .renderFailed)
        XCTAssertEqual(updated.activeRender(for: .drums)?.fileURL, oldDrumsURL)
        XCTAssertEqual(updated.activeRender(for: .drumless)?.fileURL, oldDrumlessURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDrumsURL.path), "a failed re-render must not touch the old drums file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDrumlessURL.path), "a failed re-render must not touch the old drumless file")
    }

    func testSuccessfulReRenderPromotesNewFilesAndDeletesSuperseded() async throws {
        let (store, executor, coordinator) = makeFixture()
        let (track, oldDrumsURL, oldDrumlessURL) = try makeReadyTrack(store, title: "A")

        coordinator.enqueue(track.id)
        try await waitUntil { await executor.started == [track.id] }
        let task = coordinator.activeRenderTask
        let newResult = try makeResult(title: "A-new")
        await executor.completeNext(.success(newResult))
        await task?.value

        let updated = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(updated.status, .ready)
        XCTAssertEqual(updated.activeRender(for: .drums)?.fileURL, newResult.drumsURL)
        XCTAssertEqual(updated.activeRender(for: .drumless)?.fileURL, newResult.drumlessURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDrumsURL.path), "the superseded drums file must be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDrumlessURL.path), "the superseded drumless file must be deleted")
    }

    func testStatusDisplayIsNilWhenIdleAndNonNilWhileActive() async throws {
        let (store, executor, coordinator) = makeFixture()
        let (track, _, _) = try makeReadyTrack(store, title: "A")

        XCTAssertNil(coordinator.statusDisplay(for: store.track(id: track.id)!), "an idle ready track shows no banner")

        coordinator.enqueue(track.id)
        try await waitUntil { await executor.started == [track.id] }

        XCTAssertNotNil(coordinator.statusDisplay(for: store.track(id: track.id)!), "the active re-render must show its progress")
    }

    // MARK: - Fixture

    private func makeFixture() -> (LibraryStore, GatedReRenderExecutor, RenderQueueCoordinator) {
        let store = LibraryStore()
        let executor = GatedReRenderExecutor()
        let coordinator = RenderQueueCoordinator(store: store) { track, _ in
            try await executor.render(track: track)
        }
        return (store, executor, coordinator)
    }

    /// Imports a track and completes its render with real temp files, so file
    /// presence/absence can be asserted directly. Returns the resulting
    /// `.ready` track plus the URLs of its now-active Drums/Drumless files.
    private func makeReadyTrack(_ store: LibraryStore, title: String) throws -> (BackbeatTrack, URL, URL) {
        let track = store.importTrack(
            from: AudioMetadata(fileName: title, duration: 100, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/\(title)-\(UUID().uuidString).m4a")
        )
        let result = try makeResult(title: title)
        store.completePracticeRender(for: track.id, result: result)
        return (store.track(id: track.id)!, result.drumsURL, result.drumlessURL)
    }

    private func makeResult(title: String) throws -> PracticeRenderResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let drumsURL = root.appendingPathComponent("\(title)-drums.m4a")
        let drumlessURL = root.appendingPathComponent("\(title)-drumless.m4a")
        try Data("drums".utf8).write(to: drumsURL)
        try Data("drumless".utf8).write(to: drumlessURL)
        return PracticeRenderResult(drumsURL: drumsURL, drumlessURL: drumlessURL)
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

private enum StubReRenderError: LocalizedError {
    case boom

    var errorDescription: String? { "boom" }
}

/// Hermetic render execution gated on explicit completion, so tests control
/// exactly when each job finishes and can observe serialization.
private actor GatedReRenderExecutor {
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
