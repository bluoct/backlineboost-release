import Foundation

/// Aggregated result of one import batch: titles of files skipped as
/// byte-identical duplicates of tracks already in the library, and
/// descriptions of files that failed to import outright. The app maps this
/// into user-facing alerts.
public struct ImportBatchReport: Sendable {
    public let skippedDuplicateTitles: [String]
    public let failureDescriptions: [String]

    public init(skippedDuplicateTitles: [String], failureDescriptions: [String]) {
        self.skippedDuplicateTitles = skippedDuplicateTitles
        self.failureDescriptions = failureDescriptions
    }
}

/// Result of the off-actor per-file import stage (dedupe → metadata → artwork →
/// copy). The heavy work runs in a detached task so it never blocks the
/// MainActor; the pipeline only snapshots the library before it and commits after.
private enum ImportOutcome: Sendable {
    case duplicate(existingTitle: String)
    case imported(metadata: AudioMetadata, managedURL: URL, trackID: UUID, artworkURL: URL?)
}

/// The serialized import pipeline moved out of the root view (F2): the
/// dedupe-TOCTOU chain serialization, the detached per-file heavy stage, and
/// batch aggregation into an `ImportBatchReport`. The app maps the report to
/// alerts. `artworkFallback` is the app-target seam for library-specific
/// artwork lookup (e.g. Apple Music) — Core never imports `iTunesLibrary`
/// directly (D-087).
@MainActor
public final class TrackImportPipeline {
    private let store: LibraryStore
    private let renderQueue: RenderQueueCoordinator
    private let managedLibrary: ManagedAudioLibrary
    private let artworkStore: AudioArtworkStore
    private let artworkFallback: (@Sendable (URL) async -> Data?)?
    // Serializes every import batch so two concurrent drops can't both pass
    // the duplicate check before either commits (the dedupe TOCTOU); each
    // batch awaits all prior batches before it snapshots the library.
    private var importChain: Task<ImportBatchReport, Never>?

    /// Fires once per file, right after it commits to the store — not once at
    /// batch end — mirroring `RenderQueueCoordinator.onLibraryChanged`. The
    /// app wires this to the per-file loudness-analysis cadence.
    public var onTrackCommitted: (@MainActor (BackbeatTrack) -> Void)?

    public init(
        store: LibraryStore,
        renderQueue: RenderQueueCoordinator,
        managedLibrary: ManagedAudioLibrary = ManagedAudioLibrary(),
        artworkStore: AudioArtworkStore = AudioArtworkStore(),
        artworkFallback: (@Sendable (URL) async -> Data?)? = nil
    ) {
        self.store = store
        self.renderQueue = renderQueue
        self.managedLibrary = managedLibrary
        self.artworkStore = artworkStore
        self.artworkFallback = artworkFallback
    }

    /// Imports a batch of files, chaining onto any in-flight batch (see
    /// `chainBatch`) so two concurrent drops can't both import the same new
    /// file.
    @discardableResult
    public func enqueue(urls: [URL], managesSecurityScope: Bool, useArtworkFallback: Bool) -> Task<ImportBatchReport, Never> {
        chainBatch { [self] in
            await self.importFiles(urls, managesSecurityScope: managesSecurityScope, useArtworkFallback: useArtworkFallback)
        }
    }

    /// Imports every audio file directly inside `folderURL` (non-recursive),
    /// chaining onto any in-flight batch like `enqueue`. Enumeration failures
    /// are aggregated into the returned report instead of aborting.
    @discardableResult
    public func enqueueFolder(_ folderURL: URL) -> Task<ImportBatchReport, Never> {
        chainBatch { [self] in
            let didAccess = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                let audioURLs = AudioImportFilter.audioFileURLs(from: contents)
                return await self.importFiles(audioURLs, managesSecurityScope: false, useArtworkFallback: false)
            } catch {
                return ImportBatchReport(skippedDuplicateTitles: [], failureDescriptions: ["\(folderURL.lastPathComponent): \(error.localizedDescription)"])
            }
        }
    }

    /// Runs an import batch only after every previously queued batch finishes.
    /// Import dedupe snapshots the library, so serializing batches guarantees
    /// each snapshot already reflects all prior commits — two concurrent drops
    /// can't both import the same new file. Returns the batch task so a caller
    /// whose source files are short-lived (the Music promise scratch dir) can
    /// await the copy before cleaning up.
    @discardableResult
    private func chainBatch(_ work: @escaping @MainActor () async -> ImportBatchReport) -> Task<ImportBatchReport, Never> {
        let previous = importChain
        let task = Task { @MainActor in
            _ = await previous?.value
            return await work()
        }
        importChain = task
        return task
    }

    /// Shared import loop. Completes only after every file is imported (or
    /// skipped), so callers holding short-lived source files — like the
    /// Music drop shim's promise scratch directory — can clean up safely
    /// after awaiting it. Duplicates and per-file failures are aggregated into
    /// the returned `ImportBatchReport` without aborting the rest of the batch.
    /// `useArtworkFallback` is true only for Music-drag imports: it allows the
    /// injected artwork fallback, whose first use triggers the "Media & Apple
    /// Music" consent prompt (D-087) — a prompt Finder and panel imports must
    /// never raise.
    private func importFiles(_ urls: [URL], managesSecurityScope: Bool, useArtworkFallback: Bool) async -> ImportBatchReport {
        var skippedDuplicates: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                if let existingTitle = try await importFile(url, managesSecurityScope: managesSecurityScope, useArtworkFallback: useArtworkFallback) {
                    skippedDuplicates.append(existingTitle)
                }
            } catch {
                // One unreadable file must not abort the rest of the batch.
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return ImportBatchReport(skippedDuplicateTitles: skippedDuplicates, failureDescriptions: failures)
    }

    /// Imports one file, or returns the existing track's title when the file
    /// is byte-identical to an original the library already stores.
    ///
    /// The heavy per-file stage — the dedupe SHA-256 hash, metadata read,
    /// artwork lookup, the byte copy into the managed library, and the artwork
    /// write — runs off the MainActor in one detached task, so a batch or a
    /// cross-volume copy never freezes the UI. The MainActor only snapshots the
    /// library before the stage and commits `importTrack`/`enqueue` after it.
    private func importFile(_ url: URL, managesSecurityScope: Bool, useArtworkFallback: Bool) async throws -> String? {
        let didAccess = managesSecurityScope && url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        DebugLog.importing.notice("import.start file=\(url.lastPathComponent, privacy: .public) ext=\(url.pathExtension, privacy: .public) managesScope=\(managesSecurityScope) accessGranted=\(didAccess)")

        // Snapshot on the MainActor, then do the file work off-actor. Security
        // scope is process-wide (not thread-bound), so the detached read stays
        // valid inside the start/stop bracket above — the defer runs only after
        // `.value` returns.
        let storedSources = store.tracks.map { (title: $0.title, sourceURL: $0.sourceURL) }
        let outcome = try await Task.detached(priority: .userInitiated) { [managedLibrary, artworkStore, artworkFallback] in
            if let match = DuplicateTrackDetector().existingDuplicate(
                of: url,
                among: storedSources.map(\.sourceURL)
            ) {
                let existingTitle = storedSources.first { $0.sourceURL == match }?.title
                    ?? url.deletingPathExtension().lastPathComponent
                return ImportOutcome.duplicate(existingTitle: existingTitle)
            }

            let metadata = try await AudioMetadataReader().read(url: url)
            DebugLog.importing.notice("import.metadata title=\(metadata.resolvedTitle, privacy: .public) artworkBytes=\(metadata.artworkData?.count ?? 0)")
            var artworkData = metadata.artworkData
            var artworkSource = artworkData == nil ? "none" : "embedded"
            if artworkData == nil && useArtworkFallback, let artworkFallback {
                // The injected fallback looks up artwork outside the file
                // itself (e.g. the Music library's database for Music-drag
                // imports); iTunesLibrary must never be imported by this
                // file (D-087).
                artworkData = await artworkFallback(url)
                if artworkData != nil {
                    artworkSource = "musiclibrary"
                }
            }
            let managedURL = try managedLibrary.storeSourceFile(url)
            let trackID = UUID()
            // Metadata carries no artwork type info; the store sniffs magic bytes.
            let artworkURL = try artworkStore.storeArtwork(
                artworkData,
                contentType: nil,
                trackID: trackID
            )
            DebugLog.importing.notice("import.artwork stored=\(artworkURL != nil) source=\(artworkSource, privacy: .public) file=\(artworkURL?.lastPathComponent ?? "none", privacy: .public)")
            return ImportOutcome.imported(
                metadata: metadata,
                managedURL: managedURL,
                trackID: trackID,
                artworkURL: artworkURL
            )
        }.value

        switch outcome {
        case .duplicate(let existingTitle):
            DebugLog.importing.notice("import.duplicate title=\(existingTitle, privacy: .public)")
            return existingTitle
        case .imported(let metadata, let managedURL, let trackID, let artworkURL):
            // The track is playable as Original immediately; the background
            // queue renders Drums/Drumless one track at a time.
            let track = store.importTrack(
                id: trackID,
                from: metadata,
                sourceURL: managedURL,
                artworkURL: artworkURL
            )
            // The separation model is bundled, so a render can start immediately.
            renderQueue.enqueue(track.id)
            onTrackCommitted?(track)
            DebugLog.importing.notice("import.done trackID=\(trackID.uuidString, privacy: .public) title=\(track.title, privacy: .public) hasArtwork=\(artworkURL != nil)")
            return nil
        }
    }
}
