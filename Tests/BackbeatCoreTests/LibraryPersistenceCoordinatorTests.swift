import XCTest
@testable import BackbeatCore

/// Behavioral coverage for the single library-save debounce (CLR-003): a
/// burst of triggers must collapse into one write of the freshest state, a
/// windowless render completion must still persist, a termination flush must
/// win over a still-pending debounce, and repeated failures must surface a
/// sticky banner.
@MainActor
final class LibraryPersistenceCoordinatorTests: XCTestCase {
    func testRapidBurstCollapsesIntoOneWriteWithFireTimeSnapshotCapture() async throws {
        let writer = RecordingSnapshotWriter()
        var currentSnapshot = makeSnapshot(volume: 0.1)
        let coordinator = LibraryPersistenceCoordinator(
            writer: writer,
            makeSnapshot: { currentSnapshot },
            debounceInterval: .milliseconds(20)
        )

        for _ in 0..<20 {
            coordinator.noteLibraryChanged()
        }
        try await waitUntil { writer.written.count == 1 }

        XCTAssertEqual(writer.written.count, 1, "a burst of triggers must collapse into a single write")
        XCTAssertEqual(writer.written.first?.snapshot.volume, 0.1)

        // A second burst: mutate the backing state AFTER the triggering call
        // but before the debounce fires — the write must reflect that later
        // state, proving the snapshot is captured at fire time, not call time.
        coordinator.noteLibraryChanged()
        currentSnapshot = makeSnapshot(volume: 0.9)
        try await waitUntil { writer.written.count == 2 }

        XCTAssertEqual(
            writer.written.last?.snapshot.volume, 0.9,
            "fire-time capture must read the freshest state, not the state at the triggering call"
        )
    }

    func testWindowlessRenderCompletionPersists() async throws {
        let writer = RecordingSnapshotWriter()
        let store = LibraryStore()
        let coordinator = LibraryPersistenceCoordinator(
            writer: writer,
            makeSnapshot: { LibrarySnapshot(store: store) },
            debounceInterval: .milliseconds(20)
        )
        let executor = GatedPersistenceExecutor()
        let renderQueue = RenderQueueCoordinator(store: store) { track, _ in
            try await executor.render(track: track)
        }
        renderQueue.onLibraryChanged = { coordinator.noteLibraryChanged() }

        let track = store.importTrack(
            from: AudioMetadata(fileName: "A", duration: 100, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/A-\(UUID().uuidString).m4a")
        )
        renderQueue.enqueue(track.id)
        try await waitUntil { await executor.started == [track.id] }
        let task = renderQueue.activeRenderTask
        await executor.completeNext(.success(makeRenderResult()))
        await task?.value

        try await waitUntil { writer.written.count == 1 }
        XCTAssertEqual(writer.written.count, 1, "a render completing with no window observing must still persist (F8)")
    }

    func testFlushForTerminationWinsOverAStaleDebounce() async throws {
        let writer = RecordingSnapshotWriter()
        var currentSnapshot = makeSnapshot(volume: 0.2)
        let coordinator = LibraryPersistenceCoordinator(
            writer: writer,
            makeSnapshot: { currentSnapshot },
            debounceInterval: .milliseconds(20)
        )

        coordinator.noteLibraryChanged()
        currentSnapshot = makeSnapshot(volume: 0.7)
        coordinator.flushForTermination()

        XCTAssertEqual(writer.written.count, 1)
        XCTAssertEqual(writer.written.first?.snapshot.volume, 0.7, "the flush must capture the state as of termination, not the earlier debounce trigger")

        // Give the (cancelled) pending debounce a chance to fire anyway; the
        // writer's own stale-generation guard would drop it even if it did.
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(writer.written.count, 1, "the pending debounced save must not land a second write after the flush")
    }

    func testFailureAlertThresholdAndStickyMessageUntilDismissed() async throws {
        let writer = RecordingSnapshotWriter()
        let snapshot = makeSnapshot(volume: 0.5)
        let coordinator = LibraryPersistenceCoordinator(
            writer: writer,
            makeSnapshot: { snapshot },
            debounceInterval: .milliseconds(20),
            failureAlertThreshold: 3
        )
        writer.errorToThrow = StubWriteError.boom

        // Wait on saveFailureCount itself, not writer.attempts: the write
        // attempt is recorded on one side of the detached-task hop, the
        // failure count is bumped back on MainActor on the other — waiting
        // on the write count alone can observe a stale saveFailureCount.
        for expectedFailures in 1...3 {
            coordinator.noteLibraryChanged()
            try await waitUntil { coordinator.saveFailureCount == expectedFailures }
        }
        XCTAssertEqual(writer.attempts.count, 3)
        XCTAssertNotNil(coordinator.saveFailureMessage)

        writer.errorToThrow = nil
        coordinator.noteLibraryChanged()
        try await waitUntil { coordinator.saveFailureCount == 0 }
        XCTAssertEqual(coordinator.saveFailureCount, 0)
        XCTAssertNotNil(coordinator.saveFailureMessage, "the banner is sticky until the user dismisses it")

        coordinator.saveFailureMessage = nil
        coordinator.noteLibraryChanged()
        try await waitUntil { writer.written.count == 2 }
        XCTAssertNil(coordinator.saveFailureMessage, "a later success must not resurrect a dismissed banner")
    }

    func testContinuousChangeStreamCannotStarveTheSaveBeyondMaxLatency() async throws {
        let writer = RecordingSnapshotWriter()
        let snapshot = makeSnapshot(volume: 0.5)
        let coordinator = LibraryPersistenceCoordinator(
            writer: writer,
            makeSnapshot: { snapshot },
            debounceInterval: .milliseconds(30),
            maxSaveLatency: .milliseconds(90)
        )

        // Hammer changes faster than the debounce interval for well past the
        // latency cap: pure cancel-and-restart would never write (the exact
        // starvation that could lose a render completion to a force-kill
        // during a long slider drag).
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
        while ContinuousClock.now < deadline, writer.written.isEmpty {
            coordinator.noteLibraryChanged()
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(
            writer.written.isEmpty,
            "the max-latency cap must force a write while the change stream continues"
        )
    }

    // MARK: - Fixtures

    private func makeSnapshot(volume: Double) -> LibrarySnapshot {
        LibrarySnapshot(tracks: [], selectedTrackID: nil, volume: volume)
    }

    private func makeRenderResult() -> PracticeRenderResult {
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

private enum StubWriteError: LocalizedError {
    case boom

    var errorDescription: String? { "boom" }
}

/// Hermetic render execution gated on explicit completion, mirroring the
/// pattern in RenderQueueCoordinatorTests/ReadyTrackReRenderTests — only the
/// success path is needed here.
private actor GatedPersistenceExecutor {
    private var pending: [CheckedContinuation<PracticeRenderResult, Error>] = []
    private(set) var started: [BackbeatTrack.ID] = []

    func render(track: BackbeatTrack) async throws -> PracticeRenderResult {
        started.append(track.id)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
        }
    }

    func completeNext(_ result: Result<PracticeRenderResult, Error>) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(with: result)
    }
}

/// Records every write attempt and replicates `LibrarySnapshotWriter`'s
/// stale-generation skip, so tests can assert exactly what landed without
/// touching disk.
private final class RecordingSnapshotWriter: LibrarySnapshotWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var generationCounter = 0
    private var writtenGeneration = 0
    private var attemptsStorage: [(generation: Int, snapshot: LibrarySnapshot)] = []
    private var writtenStorage: [(generation: Int, snapshot: LibrarySnapshot)] = []
    private var errorToThrowStorage: Error?

    var attempts: [(generation: Int, snapshot: LibrarySnapshot)] {
        lock.lock()
        defer { lock.unlock() }
        return attemptsStorage
    }

    var written: [(generation: Int, snapshot: LibrarySnapshot)] {
        lock.lock()
        defer { lock.unlock() }
        return writtenStorage
    }

    var errorToThrow: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return errorToThrowStorage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            errorToThrowStorage = newValue
        }
    }

    func nextGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generationCounter += 1
        return generationCounter
    }

    func write(_ snapshot: LibrarySnapshot, generation: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        attemptsStorage.append((generation, snapshot))
        guard generation > writtenGeneration else { return }
        if let error = errorToThrowStorage {
            throw error
        }
        writtenStorage.append((generation, snapshot))
        writtenGeneration = generation
    }
}
