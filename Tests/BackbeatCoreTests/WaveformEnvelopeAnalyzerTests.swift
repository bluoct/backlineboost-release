import XCTest
@testable import BackbeatCore

final class WaveformEnvelopeAnalyzerTests: XCTestCase {
    func testCacheReusesEnvelopeForUnchangedFileMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-waveform-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("song.m4a")
        try Data("audio-v1".utf8).write(to: url)
        let analyzer = WaveformAnalyzerSpy()
        let cache = WaveformEnvelopeCache(analyzer: analyzer)

        let first = try await cache.envelope(for: url, binCount: 8)
        let second = try await cache.envelope(for: url, binCount: 8)
        let callCount = await analyzer.callCount

        XCTAssertEqual(first, second)
        XCTAssertEqual(callCount, 1)
    }

    func testCacheInvalidatesWhenFileMetadataChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-waveform-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("song.m4a")
        try Data("audio-v1".utf8).write(to: url)
        let analyzer = WaveformAnalyzerSpy()
        let cache = WaveformEnvelopeCache(analyzer: analyzer)

        _ = try await cache.envelope(for: url, binCount: 8)
        try Data("audio-v2-with-more-bytes".utf8).write(to: url)
        _ = try await cache.envelope(for: url, binCount: 8)
        let callCount = await analyzer.callCount

        XCTAssertEqual(callCount, 2)
    }

    func testConcurrentRequestsForSameKeyDecodeOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-waveform-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("song.m4a")
        try Data("audio-v1".utf8).write(to: url)
        let analyzer = GatedWaveformAnalyzerSpy()
        let cache = WaveformEnvelopeCache(analyzer: analyzer)

        async let first = cache.envelope(for: url, binCount: 8)
        async let second = cache.envelope(for: url, binCount: 8)

        // Hold the gate until the first decode is in flight so a concurrent
        // request must join the cached task instead of decoding again.
        while await analyzer.callCount < 1 {
            await Task.yield()
        }
        await analyzer.open()

        let envelopes = try await (first, second)
        let callCount = await analyzer.callCount

        XCTAssertEqual(envelopes.0, envelopes.1)
        XCTAssertEqual(callCount, 1)
    }

    func testFailedAnalysisIsNotCachedAndRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-waveform-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("song.m4a")
        try Data("audio-v1".utf8).write(to: url)
        let analyzer = FlakyWaveformAnalyzerSpy()
        let cache = WaveformEnvelopeCache(analyzer: analyzer)

        do {
            _ = try await cache.envelope(for: url, binCount: 8)
            XCTFail("Expected the first analysis to throw")
        } catch {
            // Expected: the failed decode must not be cached.
        }
        let envelope = try await cache.envelope(for: url, binCount: 8)
        let callCount = await analyzer.callCount

        XCTAssertEqual(envelope.bins.count, 8)
        XCTAssertEqual(callCount, 2)
    }

    func testAnalyzerBuildsEnvelopeFromFullSong() async throws {
        guard let path = ProcessInfo.processInfo.environment["BACKBEAT_TEST_AUDIO"] else {
            throw XCTSkip("Set BACKBEAT_TEST_AUDIO to a local audio file to run this test.")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("BACKBEAT_TEST_AUDIO does not point to an existing file.")
        }
        let envelope = try await WaveformEnvelopeAnalyzer().analyze(url: url, binCount: 120)

        XCTAssertEqual(envelope.bins.count, 120)
        XCTAssertGreaterThan(envelope.duration, 0)
        XCTAssertGreaterThan(envelope.bins.map(\.amplitude).max() ?? 0, 0)
    }
}

private actor WaveformAnalyzerSpy: WaveformEnvelopeAnalyzing {
    private(set) var callCount = 0

    func analyze(url: URL, binCount: Int) async throws -> WaveformEnvelope {
        callCount += 1
        return WaveformEnvelope(
            duration: 8,
            bins: (0..<binCount).map { index in
                WaveformEnvelope.Bin(
                    startTime: Double(index),
                    endTime: Double(index + 1),
                    amplitude: Double(callCount)
                )
            }
        )
    }
}

private actor GatedWaveformAnalyzerSpy: WaveformEnvelopeAnalyzing {
    private(set) var callCount = 0
    private var isOpen = false
    private var gateContinuations: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let continuations = gateContinuations
        gateContinuations = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func analyze(url: URL, binCount: Int) async throws -> WaveformEnvelope {
        callCount += 1
        if !isOpen {
            await withCheckedContinuation { continuation in
                gateContinuations.append(continuation)
            }
        }
        return WaveformEnvelope(
            duration: 8,
            bins: (0..<binCount).map { index in
                WaveformEnvelope.Bin(
                    startTime: Double(index),
                    endTime: Double(index + 1),
                    amplitude: Double(callCount)
                )
            }
        )
    }
}

private actor FlakyWaveformAnalyzerSpy: WaveformEnvelopeAnalyzing {
    private(set) var callCount = 0

    func analyze(url: URL, binCount: Int) async throws -> WaveformEnvelope {
        callCount += 1
        if callCount == 1 {
            throw BoostedDrumsRenderError.invalidOutput(url)
        }
        return WaveformEnvelope(
            duration: 8,
            bins: (0..<binCount).map { index in
                WaveformEnvelope.Bin(
                    startTime: Double(index),
                    endTime: Double(index + 1),
                    amplitude: Double(callCount)
                )
            }
        )
    }
}
