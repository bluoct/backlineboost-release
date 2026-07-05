import Foundation

public actor WaveformEnvelopeCache {
    private let analyzer: any WaveformEnvelopeAnalyzing
    // Caching the in-flight Task (not the value) means concurrent requests
    // for the same key share one decode despite actor reentrancy. The UUID
    // is the eviction token: Task is not Equatable, and a stale waiter must
    // not evict a fresh replacement entry.
    private var entries: [WaveformEnvelopeCacheKey: (id: UUID, task: Task<WaveformEnvelope, any Error>)]

    public init(
        analyzer: any WaveformEnvelopeAnalyzing = WaveformEnvelopeAnalyzer()
    ) {
        self.analyzer = analyzer
        self.entries = [:]
    }

    public func envelope(for url: URL, binCount: Int = 240) async throws -> WaveformEnvelope {
        let key = try WaveformEnvelopeCacheKey(url: url, binCount: binCount)
        if let entry = entries[key] {
            return try await entry.task.value
        }
        let id = UUID()
        let analyzer = self.analyzer
        // Awaiting .value does not forward a waiter's cancellation, which is
        // desired: an abandoned decode runs to completion and stays cached
        // for the next view identity.
        let task = Task {
            try await analyzer.analyze(url: url, binCount: binCount)
        }
        entries[key] = (id, task)
        do {
            return try await task.value
        } catch {
            if entries[key]?.id == id {
                entries[key] = nil
            }
            throw error
        }
    }

    public func removeAll() {
        entries.removeAll()
    }
}

private struct WaveformEnvelopeCacheKey: Hashable {
    let path: String
    let fileSize: Int
    let modificationTime: TimeInterval
    let binCount: Int

    init(url: URL, binCount: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        self.path = url.standardizedFileURL.path
        self.fileSize = attributes[.size] as? Int ?? 0
        self.modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        self.binCount = binCount
    }
}
