import XCTest
import AVFoundation
@testable import BackbeatCore

@MainActor
final class TrackImportPipelineTests: XCTestCase {

    // MARK: - TOCTOU serialization

    func testChainSerializesBatchesSoTheSecondSnapshotSeesTheFirstCommit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let sourceA = try writeFixtureWAV(seed: 1, name: "a.wav", in: fixture.inputDir)
        let copiesDir = try makeSubdirectory("copies", in: fixture)
        let copyOfA = copiesDir.appendingPathComponent("b.wav")
        try FileManager.default.copyItem(at: sourceA, to: copyOfA)

        // Both enqueue calls happen back-to-back with no await between them,
        // so batch 2 must still see batch 1's commit through the chain.
        let batch1 = fixture.pipeline.enqueue(urls: [sourceA], managesSecurityScope: false, useArtworkFallback: false)
        let batch2 = fixture.pipeline.enqueue(urls: [copyOfA], managesSecurityScope: false, useArtworkFallback: false)

        let report1 = await batch1.value
        let report2 = await batch2.value

        XCTAssertEqual(fixture.store.tracks.count, 1)
        XCTAssertEqual(try managedSourceEntryCount(fixture.sourcesDir), 1)
        XCTAssertTrue(report1.skippedDuplicateTitles.isEmpty)
        XCTAssertTrue(report1.failureDescriptions.isEmpty)
        XCTAssertEqual(report2.skippedDuplicateTitles, [fixture.store.tracks[0].title])
        XCTAssertTrue(report2.failureDescriptions.isEmpty)
    }

    // MARK: - Await contract (Music scratch-dir cleanup)

    func testEnqueueTaskCompletesOnlyAfterTheManagedCopyExists() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let sourceA = try writeFixtureWAV(seed: 2, name: "a.wav", in: fixture.inputDir)

        _ = await fixture.pipeline.enqueue(urls: [sourceA], managesSecurityScope: false, useArtworkFallback: false).value

        XCTAssertEqual(fixture.store.tracks.count, 1)
        let track = try XCTUnwrap(fixture.store.tracks.first)

        try FileManager.default.removeItem(at: sourceA)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: track.sourceURL.path),
            "the committed track's sourceURL must be the managed copy, which must already exist by the time enqueue's task completes"
        )
    }

    // MARK: - Aggregation without aborting

    func testBatchAggregatesDuplicatesAndFailuresWithoutAborting() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let existingURL = try writeFixtureWAV(seed: 3, name: "existing.wav", in: fixture.inputDir)
        _ = await fixture.pipeline.enqueue(urls: [existingURL], managesSecurityScope: false, useArtworkFallback: false).value
        let existingTrack = try XCTUnwrap(fixture.store.tracks.first)

        let good1URL = try writeFixtureWAV(seed: 4, name: "good1.wav", in: fixture.inputDir)
        let duplicatesDir = try makeSubdirectory("duplicates", in: fixture)
        let duplicateOfExisting = duplicatesDir.appendingPathComponent("existing-copy.wav")
        try FileManager.default.copyItem(at: existingURL, to: duplicateOfExisting)
        let missingURL = fixture.inputDir.appendingPathComponent("missing.wav")
        let good2URL = try writeFixtureWAV(seed: 5, name: "good2.wav", in: fixture.inputDir)

        let report = await fixture.pipeline.enqueue(
            urls: [good1URL, duplicateOfExisting, missingURL, good2URL],
            managesSecurityScope: false,
            useArtworkFallback: false
        ).value

        XCTAssertEqual(report.skippedDuplicateTitles, [existingTrack.title])
        XCTAssertEqual(report.failureDescriptions.count, 1)
        XCTAssertTrue(
            report.failureDescriptions.first?.contains("missing.wav") ?? false,
            "the failure description must name the missing file: \(report.failureDescriptions)"
        )
        XCTAssertEqual(fixture.store.tracks.count, 3, "the two good files must commit alongside the pre-existing track")
    }

    // MARK: - D-080 ordering

    func testDuplicateNeverCreatesAManagedCopy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let sourceA = try writeFixtureWAV(seed: 6, name: "a.wav", in: fixture.inputDir)
        _ = await fixture.pipeline.enqueue(urls: [sourceA], managesSecurityScope: false, useArtworkFallback: false).value
        XCTAssertEqual(try managedSourceEntryCount(fixture.sourcesDir), 1)

        let duplicatesDir = try makeSubdirectory("duplicates", in: fixture)
        let duplicateOfA = duplicatesDir.appendingPathComponent("a-copy.wav")
        try FileManager.default.copyItem(at: sourceA, to: duplicateOfA)

        let report = await fixture.pipeline.enqueue(urls: [duplicateOfA], managesSecurityScope: false, useArtworkFallback: false).value

        XCTAssertEqual(fixture.store.tracks.count, 1)
        XCTAssertEqual(report.skippedDuplicateTitles.count, 1)
        XCTAssertEqual(
            try managedSourceEntryCount(fixture.sourcesDir),
            1,
            "a duplicate must never create a second managed copy"
        )
    }

    // MARK: - Artwork fallback gating

    func testArtworkFallbackRunsOnlyWhenEnabledAndEmbeddedArtworkIsAbsent() async throws {
        let enabledFixtureRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: enabledFixtureRoot) }
        let (enabledFallback, enabledCounter) = makeCountingArtworkFallback(returning: samplePNGData())
        let enabledFixture = try makeFixture(rootDirectory: enabledFixtureRoot, artworkFallback: enabledFallback)

        let artlessEnabledURL = try writeFixtureWAV(seed: 7, name: "artless.wav", in: enabledFixture.inputDir)
        _ = await enabledFixture.pipeline.enqueue(urls: [artlessEnabledURL], managesSecurityScope: false, useArtworkFallback: true).value

        let callCountWhenEnabled = await enabledCounter.count
        XCTAssertEqual(callCountWhenEnabled, 1, "the fallback must run exactly once for an artless file when enabled")
        let receivedURLs = await enabledCounter.receivedURLs
        XCTAssertEqual(
            receivedURLs, [artlessEnabledURL],
            "the fallback must receive the ORIGINAL source URL — the path Music's own database records — never the managed copy"
        )
        let committedTrack = try XCTUnwrap(enabledFixture.store.tracks.first)
        let artworkURL = try XCTUnwrap(committedTrack.artworkURL, "a fallback that returns data must populate artworkURL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path))
        XCTAssertTrue(artworkURL.path.hasPrefix(enabledFixture.artworkDir.path), "artwork must be stored under the injected artwork directory")

        let disabledFixtureRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: disabledFixtureRoot) }
        let (disabledFallback, disabledCounter) = makeCountingArtworkFallback(returning: samplePNGData())
        let disabledFixture = try makeFixture(rootDirectory: disabledFixtureRoot, artworkFallback: disabledFallback)

        let artlessDisabledURL = try writeFixtureWAV(seed: 8, name: "artless.wav", in: disabledFixture.inputDir)
        _ = await disabledFixture.pipeline.enqueue(urls: [artlessDisabledURL], managesSecurityScope: false, useArtworkFallback: false).value

        let callCountWhenDisabled = await disabledCounter.count
        XCTAssertEqual(callCountWhenDisabled, 0, "the fallback must never run when useArtworkFallback is false")
        let disabledTrack = try XCTUnwrap(disabledFixture.store.tracks.first)
        XCTAssertNil(disabledTrack.artworkURL)
    }

    // MARK: - Folder enumeration failure

    func testFolderEnumerationFailureLandsInTheBatchReport() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let nonexistentDir = fixture.tempDir.appendingPathComponent("does-not-exist", isDirectory: true)

        let report = await fixture.pipeline.enqueueFolder(nonexistentDir).value

        XCTAssertEqual(report.failureDescriptions.count, 1)
        XCTAssertTrue(report.skippedDuplicateTitles.isEmpty)
        XCTAssertTrue(fixture.store.tracks.isEmpty)
    }

    // MARK: - onTrackCommitted cadence

    func testOnTrackCommittedFiresPerFileNotPerBatch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        var observedCounts: [Int] = []
        fixture.pipeline.onTrackCommitted = { _ in observedCounts.append(fixture.store.tracks.count) }

        let good1URL = try writeFixtureWAV(seed: 9, name: "good1.wav", in: fixture.inputDir)
        let good2URL = try writeFixtureWAV(seed: 10, name: "good2.wav", in: fixture.inputDir)

        _ = await fixture.pipeline.enqueue(urls: [good1URL, good2URL], managesSecurityScope: false, useArtworkFallback: false).value

        XCTAssertEqual(observedCounts, [1, 2], "the callback must fire per committed file, observing the running count each time")

        observedCounts.removeAll()
        let duplicatesDir = try makeSubdirectory("duplicates", in: fixture)
        let duplicateOfGood1 = duplicatesDir.appendingPathComponent("good1-copy.wav")
        try FileManager.default.copyItem(at: good1URL, to: duplicateOfGood1)

        let duplicateReport = await fixture.pipeline.enqueue(urls: [duplicateOfGood1], managesSecurityScope: false, useArtworkFallback: false).value

        XCTAssertTrue(observedCounts.isEmpty, "a duplicates-only batch must never fire onTrackCommitted")
        XCTAssertEqual(duplicateReport.skippedDuplicateTitles.count, 1)
    }

    // MARK: - Fixture

    private struct Fixture {
        let store: LibraryStore
        let renderQueue: RenderQueueCoordinator
        let pipeline: TrackImportPipeline
        let tempDir: URL
        let inputDir: URL
        let sourcesDir: URL
        let artworkDir: URL
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFixture(
        rootDirectory: URL? = nil,
        artworkFallback: (@Sendable (URL) async -> Data?)? = nil
    ) throws -> Fixture {
        let tempDir = try rootDirectory ?? makeTempDirectory()
        let inputDir = tempDir.appendingPathComponent("input", isDirectory: true)
        let sourcesDir = tempDir.appendingPathComponent("sources", isDirectory: true)
        let artworkDir = tempDir.appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)

        let store = LibraryStore()
        let renderQueue = RenderQueueCoordinator(store: store) { _, _ in throw CancellationError() }
        let pipeline = TrackImportPipeline(
            store: store,
            renderQueue: renderQueue,
            managedLibrary: ManagedAudioLibrary(sourceDirectory: sourcesDir),
            artworkStore: AudioArtworkStore(artworkDirectory: artworkDir),
            artworkFallback: artworkFallback
        )
        return Fixture(
            store: store,
            renderQueue: renderQueue,
            pipeline: pipeline,
            tempDir: tempDir,
            inputDir: inputDir,
            sourcesDir: sourcesDir,
            artworkDir: artworkDir
        )
    }

    private func makeSubdirectory(_ name: String, in fixture: Fixture) throws -> URL {
        let dir = fixture.tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func managedSourceEntryCount(_ directory: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count
    }

    /// Writes a small mono float32 WAV fixture. `seed` shifts the waveform so
    /// distinct logical fixtures produce distinct bytes — byte-identical
    /// duplicates must be made via `FileManager.copyItem`, never by writing
    /// the same seed twice.
    @discardableResult
    private func writeFixtureWAV(seed: Int, name: String, in directory: URL, durationSeconds: Double = 0.2) throws -> URL {
        let sampleRate = 44_100.0
        let frames = AVAudioFrameCount(sampleRate * durationSeconds)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let url = directory.appendingPathComponent(name)
        // Scope the writer: AVAudioFile finalizes the WAV header on
        // deallocation, and the pipeline must read a finished file.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let ptr = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                ptr[i] = Float((Double((i + seed) % 441) / 441.0) - 0.5)
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func samplePNGData() -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 16)
    }

    private func makeCountingArtworkFallback(returning data: Data) -> (fallback: @Sendable (URL) async -> Data?, counter: CallCounter) {
        let counter = CallCounter()
        let fallback: @Sendable (URL) async -> Data? = { url in
            await counter.record(url)
            return data
        }
        return (fallback, counter)
    }
}

private actor CallCounter {
    private(set) var count = 0
    private(set) var receivedURLs: [URL] = []

    func record(_ url: URL) {
        count += 1
        receivedURLs.append(url)
    }
}
