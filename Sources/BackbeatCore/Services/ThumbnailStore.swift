import Foundation

/// Async, byte-budgeted thumbnail cache (EFF-004): keys on URL + mtime +
/// pixel size so an edited file misses naturally, dedupes concurrent
/// requests for the same key into one load, and evicts least-recently-used
/// entries past the byte budget. Decoding is injected — BackbeatCore stays
/// AppKit-free, and tests drive a counting fake.
///
/// Failed loads are cached too (as cheap negative entries) so a corrupt file
/// is not re-decoded on every appearance of its tile — but only for
/// `failureRetryInterval`, so a transient I/O failure (file locked during a
/// backup pass) self-heals instead of blanking the tile until relaunch.
///
/// Shared loads are refcounted: one requester cancelling never interrupts a
/// load others are awaiting, but when the LAST requester abandons it the
/// load is cancelled — fast-scrolling a large library must not queue a
/// backlog of decodes nobody will display.
public actor ThumbnailStore<Image: Sendable> {
    private struct Key: Hashable, Sendable {
        let path: String
        let modificationTime: TimeInterval?
        let pixelSize: Int
    }

    private struct Entry {
        let image: Image?
        let cost: Int
        let insertedAt: ContinuousClock.Instant
    }

    private struct InFlightLoad {
        let task: Task<Image?, Never>
        var requesterCount: Int
    }

    private let load: @Sendable (URL, Int) async -> (image: Image, byteCost: Int)?
    private let totalCostLimit: Int
    private let failureRetryInterval: Duration
    private let clock = ContinuousClock()
    private var cache: [Key: Entry] = [:]
    private var recencyOrder: [Key] = []   // most-recent last
    private var totalCost = 0
    private var inFlight: [Key: InFlightLoad] = [:]

    public init(
        totalCostLimit: Int = 32 * 1024 * 1024,
        failureRetryInterval: Duration = .seconds(30),
        load: @escaping @Sendable (URL, Int) async -> (image: Image, byteCost: Int)?
    ) {
        self.totalCostLimit = totalCostLimit
        self.failureRetryInterval = failureRetryInterval
        self.load = load
    }

    // nonisolated so the stat runs on the caller's executor — the actor must
    // not serialize every tile (including pure cache hits) behind disk I/O.
    public nonisolated func thumbnail(for url: URL, pixelSize: Int) async -> Image? {
        let key = Key(
            path: url.path,
            modificationTime: Self.modificationTime(of: url),
            pixelSize: pixelSize
        )
        return await image(for: key, url: url, pixelSize: pixelSize)
    }

    private func image(for key: Key, url: URL, pixelSize: Int) async -> Image? {
        if let cached = cache[key] {
            // A negative entry past its retry window is dropped so the next
            // load can self-heal a transient failure; inside the window it
            // stops the corrupt-file re-decode churn.
            if cached.image != nil || clock.now - cached.insertedAt < failureRetryInterval {
                touch(key)
                return cached.image
            }
            removeEntry(key)
        }

        if inFlight[key] != nil {
            inFlight[key]!.requesterCount += 1
            let task = inFlight[key]!.task
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { await self.abandonRequest(for: key) }
            }
        }

        // Unstructured: the shared load does not inherit any requester's
        // cancellation — only the refcount hitting zero cancels it.
        let task = Task<Image?, Never> {
            await self.loadAndStore(key: key, url: url, pixelSize: pixelSize)
        }
        inFlight[key] = InFlightLoad(task: task, requesterCount: 1)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.abandonRequest(for: key) }
        }
    }

    private func loadAndStore(key: Key, url: URL, pixelSize: Int) async -> Image? {
        guard !Task.isCancelled else {
            inFlight[key] = nil
            return nil
        }
        let result = await load(url, pixelSize)
        inFlight[key] = nil
        // A load that was abandoned mid-flight but completed anyway still
        // caches — the work is done; don't throw it away.
        let entry = Entry(
            image: result?.image,
            cost: result?.byteCost ?? 1,
            insertedAt: clock.now
        )
        cache[key] = entry
        recencyOrder.append(key)
        totalCost += entry.cost
        evictIfNeeded(protecting: key)
        return result?.image
    }

    private func abandonRequest(for key: Key) {
        guard var entry = inFlight[key] else { return }
        entry.requesterCount -= 1
        if entry.requesterCount <= 0 {
            entry.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = entry
        }
    }

    private func touch(_ key: Key) {
        guard let index = recencyOrder.firstIndex(of: key) else { return }
        recencyOrder.remove(at: index)
        recencyOrder.append(key)
    }

    private func removeEntry(_ key: Key) {
        if let removed = cache.removeValue(forKey: key) {
            totalCost -= removed.cost
        }
        if let index = recencyOrder.firstIndex(of: key) {
            recencyOrder.remove(at: index)
        }
    }

    // The front of recencyOrder is the least-recently-used entry; the
    // just-inserted key is exempt so a single entry whose own cost exceeds
    // the budget is still cached, instead of being evicted the instant it lands.
    private func evictIfNeeded(protecting justInserted: Key) {
        while totalCost > totalCostLimit, let oldest = recencyOrder.first, oldest != justInserted {
            recencyOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                totalCost -= evicted.cost
            }
        }
    }

    // FileManager, not URL.resourceValues: resource values are cached per
    // URL instance, so a repeated request through the same URL would read a
    // STALE modification date and defeat the mtime key. The stat runs on the
    // caller's executor (nonisolated), so the actor never serializes cache
    // hits behind disk I/O.
    private nonisolated static func modificationTime(of url: URL) -> TimeInterval? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
    }
}
