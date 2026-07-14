import XCTest
@testable import BackbeatCore

/// `LoudnessAnalysisQueue` is the serial, deduplicated replacement for the
/// cancel-and-restart sweep in `BackbeatRootView` (EFF-001): an import burst
/// used to trigger concurrent duplicate full-track analyses of the same file
/// because the replacement scan re-included a track whose (uninterruptible)
/// analysis was still running. These tests pin the resulting invariants: at
/// most one analysis in flight globally, one ID never analyzed twice
/// concurrently, and enqueuing during a drain only appends.
@MainActor
final class LoudnessAnalysisQueueTests: XCTestCase {
    func testBurstDedupeAnalyzesEachTrackOnceWithAtMostOneAnalysisInFlight() async throws {
        let analyzer = CountingLoudnessAnalyzer()
        var committed: [BackbeatTrack.ID] = []
        let queue = LoudnessAnalysisQueue(
            analyze: { item in try await analyzer.analyze(item) },
            commit: { trackID, _ in committed.append(trackID) }
        )

        let ids = (0..<15).map { _ in UUID() }
        let items = (0..<50).map { index -> LoudnessAnalysisQueue.Item in
            let id = ids[index % ids.count]
            return LoudnessAnalysisQueue.Item(
                trackID: id, sourceURL: URL(fileURLWithPath: "/tmp/\(id).wav"), settings: .default)
        }

        // Fire every enqueue concurrently, mirroring an import burst where the
        // per-file commit callback re-triggers the sweep for every track still
        // pending — including ones already queued or mid-analysis.
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask { await queue.enqueue([item]) }
            }
        }

        while committed.count < ids.count { await Task.yield() }

        let counts = await analyzer.callCounts
        let maxConcurrent = await analyzer.maxConcurrentCount
        XCTAssertEqual(Set(counts.keys), Set(ids), "every unique track must be analyzed")
        for id in ids {
            XCTAssertEqual(counts[id], 1, "track \(id) must be analyzed exactly once despite duplicate enqueues")
        }
        XCTAssertEqual(maxConcurrent, 1, "no two analyses may run concurrently")
        XCTAssertEqual(committed.count, ids.count, "every unique track must commit exactly once")
    }

    func testEnqueueDuringDrainAppendsWithoutRestartingTheInFlightItem() async throws {
        let analyzer = GatedLoudnessAnalyzer()
        var committed: [BackbeatTrack.ID] = []
        let queue = LoudnessAnalysisQueue(
            analyze: { item in try await analyzer.analyze(item) },
            commit: { trackID, _ in committed.append(trackID) }
        )

        let trackA = UUID()
        let trackB = UUID()
        let itemA = LoudnessAnalysisQueue.Item(trackID: trackA, sourceURL: URL(fileURLWithPath: "/tmp/a.wav"), settings: .default)
        let itemB = LoudnessAnalysisQueue.Item(trackID: trackB, sourceURL: URL(fileURLWithPath: "/tmp/b.wav"), settings: .default)

        await queue.enqueue([itemA])
        // Hold the gate until A's analysis is actually in flight before
        // re-enqueuing it alongside B — this is the exact race the per-commit
        // sweep triggered.
        while await analyzer.callCounts[trackA] == nil { await Task.yield() }
        await queue.enqueue([itemA, itemB])
        await analyzer.open()

        while committed.count < 2 { await Task.yield() }

        let counts = await analyzer.callCounts
        XCTAssertEqual(counts[trackA], 1, "re-enqueuing the in-flight track must not restart its analysis")
        XCTAssertEqual(counts[trackB], 1)
        XCTAssertEqual(committed, [trackA, trackB], "A must finish (and commit) before B starts")
    }

    func testAnalysisFailureForOneItemDoesNotStopTheRemainingItems() async throws {
        let analyzer = CountingLoudnessAnalyzer()
        var committed: [BackbeatTrack.ID] = []
        let queue = LoudnessAnalysisQueue(
            analyze: { item in try await analyzer.analyze(item) },
            commit: { trackID, _ in committed.append(trackID) }
        )

        let ids = (0..<3).map { _ in UUID() }
        await analyzer.setFailing([ids[1]])
        let items = ids.map { id in
            LoudnessAnalysisQueue.Item(trackID: id, sourceURL: URL(fileURLWithPath: "/tmp/\(id).wav"), settings: .default)
        }

        await queue.enqueue(items)
        while committed.count < 2 { await Task.yield() }

        XCTAssertEqual(Set(committed), Set([ids[0], ids[2]]), "the failing item's neighbors must still commit")
        let counts = await analyzer.callCounts
        XCTAssertEqual(counts[ids[1]], 1, "the failing item must still be attempted")
    }

    func testCancelAllDropsPendingItemsWithoutAnalyzingThem() async throws {
        let analyzer = GatedLoudnessAnalyzer()
        var committed: [BackbeatTrack.ID] = []
        let queue = LoudnessAnalysisQueue(
            analyze: { item in try await analyzer.analyze(item) },
            commit: { trackID, _ in committed.append(trackID) }
        )

        let trackA = UUID()
        let trackB = UUID()
        let trackC = UUID()
        let items = [trackA, trackB, trackC].map { id in
            LoudnessAnalysisQueue.Item(trackID: id, sourceURL: URL(fileURLWithPath: "/tmp/\(id).wav"), settings: .default)
        }

        await queue.enqueue(items)
        // Wait until the drain has picked up the first item (now in flight,
        // blocked on the gate) before cancelling — B and C are still pending.
        while await analyzer.callCounts[trackA] == nil { await Task.yield() }
        await queue.cancelAll()
        await analyzer.open()

        while committed.count < 1 { await Task.yield() }
        // Give a wrongly-continued drain a chance to surface before asserting.
        try? await Task.sleep(nanoseconds: 20_000_000)

        let counts = await analyzer.callCounts
        XCTAssertEqual(counts[trackA], 1, "the already in-flight item finishes")
        XCTAssertNil(counts[trackB], "a still-pending item must never be analyzed after cancelAll")
        XCTAssertNil(counts[trackC], "a still-pending item must never be analyzed after cancelAll")
    }
}

private enum LoudnessAnalyzerStubError: Error {
    case failed
}

/// Tracks per-ID call counts and the peak number of concurrent `analyze`
/// calls, with a short real await inside each call so a concurrency
/// regression (two analyses overlapping) would actually be observable.
private actor CountingLoudnessAnalyzer {
    private(set) var callCounts: [BackbeatTrack.ID: Int] = [:]
    private(set) var concurrentCount = 0
    private(set) var maxConcurrentCount = 0
    private var failingIDs: Set<BackbeatTrack.ID> = []

    func setFailing(_ ids: Set<BackbeatTrack.ID>) {
        failingIDs = ids
    }

    func analyze(_ item: LoudnessAnalysisQueue.Item) async throws -> TrackLoudnessProfile {
        concurrentCount += 1
        maxConcurrentCount = max(maxConcurrentCount, concurrentCount)
        callCounts[item.trackID, default: 0] += 1
        try? await Task.sleep(nanoseconds: 2_000_000)
        concurrentCount -= 1
        if failingIDs.contains(item.trackID) {
            throw LoudnessAnalyzerStubError.failed
        }
        return TrackLoudnessProfile(
            integratedLUFS: -14, samplePeakDBFS: -1, suggestedGainDB: 0,
            analyzedAt: Date(), analyzerVersion: TrackLoudnessAnalyzerVersion.current
        )
    }
}

/// Blocks every `analyze` call on a shared gate until `open()` is called,
/// so a test can deterministically hold one item in flight while it
/// enqueues more work — mirrors `GatedWaveformAnalyzerSpy`.
private actor GatedLoudnessAnalyzer {
    private(set) var callCounts: [BackbeatTrack.ID: Int] = [:]
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for continuation in waiting {
            continuation.resume()
        }
    }

    func analyze(_ item: LoudnessAnalysisQueue.Item) async throws -> TrackLoudnessProfile {
        callCounts[item.trackID, default: 0] += 1
        if !isOpen {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return TrackLoudnessProfile(
            integratedLUFS: -14, samplePeakDBFS: -1, suggestedGainDB: 0,
            analyzedAt: Date(), analyzerVersion: TrackLoudnessAnalyzerVersion.current
        )
    }
}
