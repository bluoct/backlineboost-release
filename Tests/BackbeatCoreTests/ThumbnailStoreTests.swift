import XCTest
@testable import BackbeatCore

/// Hermetic behavioral coverage for ThumbnailStore (EFF-004): the loader is
/// an injected counting fake, gated where a test needs to observe an
/// in-flight load deterministically.
final class ThumbnailStoreTests: XCTestCase {
    func testSecondRequestAfterCompletedFirstIsACacheHit() async throws {
        let loader = CountingThumbnailLoader()
        let store = ThumbnailStore<TestImage>(totalCostLimit: 1_000) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let url = try makeTempFile(named: "a.jpg")

        let first = await store.thumbnail(for: url, pixelSize: 64)
        let second = await store.thumbnail(for: url, pixelSize: 64)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        let loadCount1 = await loader.loadCount
        XCTAssertEqual(loadCount1, 1)
    }

    func testConcurrentRequestsForTheSameKeyDedupeIntoOneLoad() async throws {
        let loader = CountingThumbnailLoader()
        await loader.closeGate()
        let store = ThumbnailStore<TestImage>(totalCostLimit: 1_000) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let url = try makeTempFile(named: "concurrent.jpg")

        async let first = store.thumbnail(for: url, pixelSize: 64)
        async let second = store.thumbnail(for: url, pixelSize: 64)

        try await waitUntil { await loader.loadCount == 1 }
        await loader.openGate()

        let (resultA, resultB) = await (first, second)

        XCTAssertNotNil(resultA)
        XCTAssertEqual(resultA, resultB)
        let loadCount2 = await loader.loadCount
        XCTAssertEqual(loadCount2, 1, "two concurrent requests for the same key must dedupe into one load")
    }

    func testFileModificationInvalidatesTheCachedThumbnail() async throws {
        let loader = CountingThumbnailLoader()
        let store = ThumbnailStore<TestImage>(totalCostLimit: 1_000) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let url = try makeTempFile(named: "mutable.jpg")

        _ = await store.thumbnail(for: url, pixelSize: 64)

        // Force a distinct, deterministic modification date rather than
        // relying on filesystem mtime resolution to advance on its own
        // between two nearly-simultaneous writes.
        let bumpedDate = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: bumpedDate], ofItemAtPath: url.path)

        _ = await store.thumbnail(for: url, pixelSize: 64)

        let loadCount3 = await loader.loadCount
        XCTAssertEqual(loadCount3, 2, "a changed modification date must miss the cache")
    }

    func testEvictsLeastRecentlyUsedEntryPastByteBudget() async throws {
        let loader = CountingThumbnailLoader()
        let store = ThumbnailStore<TestImage>(totalCostLimit: 100) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let directory = try makeTempDirectory()
        let urlA = try makeTempFile(named: "a.jpg", in: directory)
        let urlB = try makeTempFile(named: "b.jpg", in: directory)
        await loader.setCost(60, forPath: urlA.path)
        await loader.setCost(60, forPath: urlB.path)

        _ = await store.thumbnail(for: urlA, pixelSize: 64)
        _ = await store.thumbnail(for: urlB, pixelSize: 64)
        // 60 + 60 > 100: A (least-recently-used) must have been evicted.
        _ = await store.thumbnail(for: urlA, pixelSize: 64)

        let loadCount4 = await loader.loadCount
        XCTAssertEqual(loadCount4, 3, "A must have been evicted, forcing a third load")
    }

    func testTouchingAnEntryProtectsItFromEviction() async throws {
        let loader = CountingThumbnailLoader()
        let store = ThumbnailStore<TestImage>(totalCostLimit: 150) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let directory = try makeTempDirectory()
        let urlA = try makeTempFile(named: "a.jpg", in: directory)
        let urlB = try makeTempFile(named: "b.jpg", in: directory)
        let urlC = try makeTempFile(named: "c.jpg", in: directory)
        await loader.setCost(60, forPath: urlA.path)
        await loader.setCost(60, forPath: urlB.path)
        await loader.setCost(60, forPath: urlC.path)

        _ = await store.thumbnail(for: urlA, pixelSize: 64)
        _ = await store.thumbnail(for: urlB, pixelSize: 64)
        let loadCount5 = await loader.loadCount
        XCTAssertEqual(loadCount5, 2)

        // Touch A: a cache hit, not a new load — but it must move A ahead of
        // B in recency order.
        _ = await store.thumbnail(for: urlA, pixelSize: 64)
        let loadCount6 = await loader.loadCount
        XCTAssertEqual(loadCount6, 2, "touching a cached entry must not trigger a load")

        // 60 + 60 + 60 > 150: B (now least-recently-used) must be evicted, not A.
        _ = await store.thumbnail(for: urlC, pixelSize: 64)
        let loadCount7 = await loader.loadCount
        XCTAssertEqual(loadCount7, 3)

        _ = await store.thumbnail(for: urlA, pixelSize: 64)
        let loadCount8 = await loader.loadCount
        XCTAssertEqual(loadCount8, 3, "A must still be cached — no new load")

        _ = await store.thumbnail(for: urlB, pixelSize: 64)
        let loadCount9 = await loader.loadCount
        XCTAssertEqual(loadCount9, 4, "B must have been evicted — a new load is required")
    }

    func testCancellingOneRequesterDoesNotCancelTheSharedLoadForOthers() async throws {
        let loader = CountingThumbnailLoader()
        await loader.closeGate()
        let store = ThumbnailStore<TestImage>(totalCostLimit: 1_000) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let url = try makeTempFile(named: "cancel-test.jpg")

        // Two requesters share the in-flight load; cancelling ONE must not
        // interrupt it for the survivor (refcount 2 -> 1, not 0).
        let cancelledTask = Task {
            await store.thumbnail(for: url, pixelSize: 64)
        }
        let survivingTask = Task {
            await store.thumbnail(for: url, pixelSize: 64)
        }
        try await waitUntil { await loader.loadCount == 1 }
        cancelledTask.cancel()

        await loader.openGate()
        let survivorResult = await survivingTask.value

        XCTAssertNotNil(survivorResult, "the shared load must complete for the requester that did not cancel")
        let loadCount10 = await loader.loadCount
        XCTAssertEqual(loadCount10, 1, "only one load must ever have started for the shared key")
    }

    func testLoadAbandonedByItsLastRequesterCompletesAndCachesIfAlreadyRunning() async throws {
        // A decode that already started is not thrown away when its last
        // requester scrolls off — the completed work is cached for the next
        // appearance. (What abandonment prevents is the NOT-yet-started
        // backlog: the shared task is cancelled at refcount 0, and a load
        // that hasn't begun checks cancellation before decoding.)
        let loader = CountingThumbnailLoader()
        await loader.closeGate()
        let store = ThumbnailStore<TestImage>(totalCostLimit: 1_000) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let url = try makeTempFile(named: "abandoned.jpg")

        let soleRequester = Task {
            await store.thumbnail(for: url, pixelSize: 64)
        }
        try await waitUntil { await loader.loadCount == 1 }
        soleRequester.cancel()
        await loader.openGate()

        // The (cancelled) shared task still runs to completion and caches;
        // poll until the next request is served from cache with no new load.
        try await waitUntil {
            let result = await store.thumbnail(for: url, pixelSize: 64)
            let loads = await loader.loadCount
            return result != nil && loads == 1
        }
    }

    func testFailedLoadIsNegativelyCachedWithinTheRetryWindow() async throws {
        let loader = CountingThumbnailLoader()
        await loader.setShouldFail(true)
        let store = ThumbnailStore<TestImage>(totalCostLimit: 1_000, failureRetryInterval: .seconds(60)) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let url = try makeTempFile(named: "corrupt.jpg")

        let first = await store.thumbnail(for: url, pixelSize: 64)
        let second = await store.thumbnail(for: url, pixelSize: 64)

        XCTAssertNil(first)
        XCTAssertNil(second)
        let loadCount11 = await loader.loadCount
        XCTAssertEqual(loadCount11, 1, "a corrupt file must not be re-decoded on every appearance of its tile")
    }

    func testFailedLoadRetriesAfterTheRetryWindowElapses() async throws {
        let loader = CountingThumbnailLoader()
        await loader.setShouldFail(true)
        let store = ThumbnailStore<TestImage>(totalCostLimit: 1_000, failureRetryInterval: .milliseconds(20)) { url, pixelSize in
            await loader.load(url: url, pixelSize: pixelSize)
        }
        let url = try makeTempFile(named: "transient.jpg")

        _ = await store.thumbnail(for: url, pixelSize: 64)
        try await Task.sleep(for: .milliseconds(40))
        await loader.setShouldFail(false)
        let healed = await store.thumbnail(for: url, pixelSize: 64)

        XCTAssertNotNil(healed, "a transient failure must self-heal once the retry window elapses")
        let loadCount12 = await loader.loadCount
        XCTAssertEqual(loadCount12, 2)
    }

    // MARK: - Fixture

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

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeTempFile(named name: String, in directory: URL? = nil) throws -> URL {
        let dir = try directory ?? makeTempDirectory()
        let url = dir.appendingPathComponent(name)
        try Data("thumbnail-fixture".utf8).write(to: url)
        return url
    }
}

private struct TestImage: Equatable, Sendable {
    let source: URL
    let pixelSize: Int
}

/// Counting fake loader. `isGateOpen` defaults to true so most tests need no
/// gating ceremony; `closeGate()`/`openGate()` let concurrency-sensitive
/// tests hold a load open deterministically.
private actor CountingThumbnailLoader {
    private(set) var loadCount = 0
    private var shouldFail = false
    private var isGateOpen = true
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
    private var costsByPath: [String: Int] = [:]
    private let defaultCost: Int

    init(defaultCost: Int = 10) {
        self.defaultCost = defaultCost
    }

    func setCost(_ cost: Int, forPath path: String) {
        costsByPath[path] = cost
    }

    func setShouldFail(_ shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func closeGate() {
        isGateOpen = false
    }

    func openGate() {
        isGateOpen = true
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func load(url: URL, pixelSize: Int) async -> (image: TestImage, byteCost: Int)? {
        loadCount += 1
        await waitForGateIfClosed()
        guard !shouldFail else { return nil }
        let cost = costsByPath[url.path] ?? defaultCost
        return (TestImage(source: url, pixelSize: pixelSize), cost)
    }

    private func waitForGateIfClosed() async {
        if isGateOpen { return }
        await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }
}
