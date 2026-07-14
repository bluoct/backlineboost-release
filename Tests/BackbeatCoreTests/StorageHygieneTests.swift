import AVFoundation
import XCTest
@testable import BackbeatCore

/// Behavioral coverage for Phase 5A storage hygiene (COR-012 b/c/d): a failed
/// post-copy import stage must roll back its managed copy instead of leaking
/// a recordless directory forever, deleting a track must prune the now-empty
/// per-track UUID directory left behind, and a two-output render failure must
/// not strand a half-written Drums/Drumless pair.
@MainActor
final class StorageHygieneTests: XCTestCase {
    // MARK: - (b) Import rollback

    func testFailedArtworkWriteRollsBackTheManagedCopy() async throws {
        let managedRoot = try makeTempDirectory()
        let artworkBlockerPath = try makeTempDirectory().appendingPathComponent("artwork-blocker")
        // Sabotage: a plain FILE sitting at the artwork directory's own path
        // makes AudioArtworkStore's createDirectory(at:) throw.
        try Data("blocker".utf8).write(to: artworkBlockerPath)

        let store = LibraryStore()
        // Throwing stub: these tests must never reach the default render
        // execution, which reads real RenderSettings/UserDefaults.
        let renderQueue = RenderQueueCoordinator(store: store) { _, _ in throw CancellationError() }
        let pipeline = TrackImportPipeline(
            store: store,
            renderQueue: renderQueue,
            managedLibrary: ManagedAudioLibrary(sourceDirectory: managedRoot),
            artworkStore: AudioArtworkStore(artworkDirectory: artworkBlockerPath),
            artworkFallback: { _ in pngishArtworkData }
        )

        let sourceURL = try makeTempDirectory().appendingPathComponent("song.wav")
        try writeSynthesizedWAV(to: sourceURL)

        let report = await pipeline.enqueue(urls: [sourceURL], managesSecurityScope: false, useArtworkFallback: true).value

        XCTAssertFalse(report.failureDescriptions.isEmpty, "the sabotaged artwork write must surface as an import failure")
        XCTAssertTrue(store.tracks.isEmpty, "no track record must exist for a rolled-back import")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: managedRoot.path)) ?? ["<missing>"]
        XCTAssertEqual(leftovers, [], "the just-created UUID directory must be rolled back, not stranded (COR-012b)")
    }

    func testRollbackDoesNotTouchAnotherTracksManagedDirectory() async throws {
        let managedRoot = try makeTempDirectory()
        let artworkBlockerPath = try makeTempDirectory().appendingPathComponent("artwork-blocker")
        try Data("blocker".utf8).write(to: artworkBlockerPath)

        // Seed a pre-existing sibling track's managed copy.
        let siblingDir = managedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        let siblingFile = siblingDir.appendingPathComponent("sibling.m4a")
        try Data("sibling".utf8).write(to: siblingFile)

        let store = LibraryStore()
        // Throwing stub: these tests must never reach the default render
        // execution, which reads real RenderSettings/UserDefaults.
        let renderQueue = RenderQueueCoordinator(store: store) { _, _ in throw CancellationError() }
        let pipeline = TrackImportPipeline(
            store: store,
            renderQueue: renderQueue,
            managedLibrary: ManagedAudioLibrary(sourceDirectory: managedRoot),
            artworkStore: AudioArtworkStore(artworkDirectory: artworkBlockerPath),
            artworkFallback: { _ in pngishArtworkData }
        )

        let sourceURL = try makeTempDirectory().appendingPathComponent("song.wav")
        try writeSynthesizedWAV(to: sourceURL)

        _ = await pipeline.enqueue(urls: [sourceURL], managesSecurityScope: false, useArtworkFallback: true).value

        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingFile.path), "an unrelated track's managed files must survive the rollback untouched")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: managedRoot.path)) ?? []
        XCTAssertEqual(contents, [siblingDir.lastPathComponent], "only the sibling directory should remain")
    }

    // MARK: - (c) Prune helper

    func testPruneRemovesTheEmptyUUIDDirectory() throws {
        let root = try makeTempDirectory()
        let uuidDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: uuidDir, withIntermediateDirectories: true)
        let fileURL = uuidDir.appendingPathComponent("source.m4a")
        try Data("source".utf8).write(to: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        ManagedAudioLibrary.pruneEmptySourceDirectory(after: fileURL, root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: uuidDir.path))
    }

    func testPruneLeavesANonEmptyUUIDDirectoryAlone() throws {
        let root = try makeTempDirectory()
        let uuidDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: uuidDir, withIntermediateDirectories: true)
        let fileURL = uuidDir.appendingPathComponent("source.m4a")
        let otherURL = uuidDir.appendingPathComponent("other.m4a")
        try Data("source".utf8).write(to: fileURL)
        try Data("other".utf8).write(to: otherURL)
        try FileManager.default.removeItem(at: fileURL)

        ManagedAudioLibrary.pruneEmptySourceDirectory(after: fileURL, root: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: uuidDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherURL.path))
    }

    func testPruneIgnoresASourceURLNestedDeeperThanADirectChildOfRoot() throws {
        let root = try makeTempDirectory()
        let uuidDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nestedDir = uuidDir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let fileURL = nestedDir.appendingPathComponent("source.m4a")
        try Data("source".utf8).write(to: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        ManagedAudioLibrary.pruneEmptySourceDirectory(after: fileURL, root: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedDir.path), "a source two levels deep is not a direct child of root and must never be pruned")
    }

    func testPruneIgnoresASourceURLOutsideTheManagedRoot() throws {
        let root = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        let fileURL = outsideDir.appendingPathComponent("source.m4a")
        try Data("source".utf8).write(to: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        ManagedAudioLibrary.pruneEmptySourceDirectory(after: fileURL, root: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDir.path), "a source outside the managed tree must never be touched")
    }

    func testPruneNeverRemovesTheRootItselfForASourceURLDirectlyInRoot() throws {
        let root = try makeTempDirectory()
        let fileURL = root.appendingPathComponent("source.m4a")
        try Data("source".utf8).write(to: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        ManagedAudioLibrary.pruneEmptySourceDirectory(after: fileURL, root: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "the managed root itself must never be removed, even when a source lived directly inside it")
    }

    func testPruneTreatsHiddenLitterAsEmpty() throws {
        // Finder drops .DS_Store into browsed directories; hidden litter must
        // not block the prune forever (removeItem deletes it with the dir).
        let root = try makeTempDirectory()
        let uuidDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: uuidDir, withIntermediateDirectories: true)
        try Data().write(to: uuidDir.appendingPathComponent(".DS_Store"))
        let fileURL = uuidDir.appendingPathComponent("song.m4a")

        ManagedAudioLibrary.pruneEmptySourceDirectory(after: fileURL, root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: uuidDir.path), "hidden files alone must not keep the directory alive")
    }

    func testStoreSourceFileRollsBackItsOwnDirectoryWhenTheCopyFails() throws {
        // copyItem throws when the source vanishes (or the disk fills)
        // mid-import; the just-created UUID directory must not strand.
        let managedRoot = try makeTempDirectory()
        let missingSource = try makeTempDirectory().appendingPathComponent("never-written.m4a")

        XCTAssertThrowsError(try ManagedAudioLibrary(sourceDirectory: managedRoot).storeSourceFile(missingSource))

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: managedRoot.path)) ?? ["<missing>"]
        XCTAssertEqual(leftovers, [], "a failed copy must roll back its own directory (COR-012b)")
    }

    // MARK: - (c) deleteTrack prunes end-to-end

    @MainActor
    func testDeleteTrackPrunesTheEmptyManagedDirectory() throws {
        let root = try makeTempDirectory()
        let uuidDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: uuidDir, withIntermediateDirectories: true)
        let sourceURL = uuidDir.appendingPathComponent("song.m4a")
        try Data("audio".utf8).write(to: sourceURL)
        let track = BackbeatTrack(title: "Pruned", duration: 100, status: .imported, sourceURL: sourceURL)
        let store = LibraryStore(tracks: [track])
        store.managedSourceRootForPruning = root

        try store.deleteTrack(id: track.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: uuidDir.path), "deleting the last file must prune the per-track directory (COR-012c)")
    }

    // MARK: - (d) Render-orphan cleanup

    func testFailedDrumlessWriteRemovesTheOrphanedDrumsFile() async throws {
        let root = try makeTempDirectory()
        let rendersRootURL = root.appendingPathComponent("renders", isDirectory: true)
        let sourceURL = root.appendingPathComponent("song.wav")
        try Data("source".utf8).write(to: sourceURL)
        let track = BackbeatTrack(
            title: "Orphan Check",
            duration: 120,
            status: .imported,
            sourceURL: sourceURL
        )
        // Fixed so this test's expected paths and the renderer's actual paths
        // agree exactly — the filename embeds a second-granularity timestamp.
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let drumsOutputURL = BoostedDrumsRenderPlan.drumsOutputURL(for: track, rendersRootURL: rendersRootURL, createdAt: createdAt)
        let drumlessOutputURL = BoostedDrumsRenderPlan.drumlessOutputURL(for: track, rendersRootURL: rendersRootURL, createdAt: createdAt)

        let renderer = BoostedDrumsRenderer(
            separator: StubStemSeparator(),
            rendersRootURL: rendersRootURL,
            stemMixdown: DrumlessFailingStemMixdown()
        )

        do {
            _ = try await renderer.render(track: track, createdAt: createdAt)
            XCTFail("expected the render to throw when the drumless write fails")
        } catch {
            XCTAssertTrue(error is StubMixdownError, "unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: drumsOutputURL.path), "the orphaned drums file must be cleaned up when drumless fails (R3)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drumlessOutputURL.path))
    }

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// A minimal PCM WAV, real enough for AVFoundation to read metadata from
    /// (the import pipeline's dedupe hash + `AudioMetadataReader` both touch
    /// the file). Scoped so `AVAudioFile` finalizes the header before this
    /// helper returns — a caller reading the file immediately after would
    /// otherwise race a still-open writer.
    private func writeSynthesizedWAV(to url: URL) throws {
        let sampleRate = 44_100.0
        let frames = AVAudioFrameCount(sampleRate * 0.2)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ptr[i] = Float((Double(i % 441) / 441.0) - 0.5)
        }
        try file.write(from: buffer)
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

private let pngishArtworkData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

/// Minimal valid stems, mirroring the shape a real `StemSeparating` engine
/// returns — only non-empty enough to pass `requireNonEmptyStems`.
private struct StubStemSeparator: StemSeparating {
    func separate(source: URL, progress: StemSeparationProgress?) async throws -> SeparatedStems {
        let channel = [Float](repeating: 0.1, count: 64)
        let stereo = [channel, channel]
        return SeparatedStems(sampleRate: 44_100, drums: stereo, bass: stereo, other: stereo, vocals: stereo)
    }
}

/// Writes a real drums file (so there's something to orphan) then fails the
/// drumless write, simulating the half-written-pair case (R3).
private struct DrumlessFailingStemMixdown: StemMixing {
    func writeDrums(stems: SeparatedStems, outputURL: URL, bitrate: RenderBitrate) async throws {
        try Data("drums".utf8).write(to: outputURL)
    }

    func writeDrumless(stems: SeparatedStems, outputURL: URL, bitrate: RenderBitrate) async throws {
        throw StubMixdownError.boom
    }
}

private enum StubMixdownError: Error {
    case boom
}
