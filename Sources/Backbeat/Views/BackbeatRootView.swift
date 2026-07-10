import BackbeatCore
import SwiftUI
import UniformTypeIdentifiers

enum BackbeatRoute: Equatable {
    case library
    case player
    case playlist(BackbeatPlaylist.ID)
}

private enum BackbeatImporter {
    case track
    case folder

    var allowedContentTypes: [UTType] {
        switch self {
        case .track:
            AudioImportFilter.supportedContentTypes
        case .folder:
            [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        self == .track
    }
}

struct BackbeatRootView: View {
    private let persistence: LibraryPersistence
    private let libraryWriter: LibrarySnapshotWriter
    private let renderQueue: RenderQueueCoordinator
    @State private var store: LibraryStore
    @State private var playback = AudioPlaybackController()
    @State private var route: BackbeatRoute = .library
    @State private var activeImporter: BackbeatImporter = .track
    @State private var isImporterPresented = false
    @State private var importErrorMessage: String?
    @State private var duplicateWarningMessage: String?
    @State private var dropRejectedMessage: String?
    @State private var isDropTargeted = false
    @State private var loudnessAnalysisTask: Task<Void, Never>?
    @State private var durationBackfillTask: Task<Void, Never>?
    @State private var pendingLibrarySave: Task<Void, Never>?
    // @State (not `let`) so the pipeline's chain instance survives view
    // re-init exactly as the former @State importChain did.
    @State private var pipeline: TrackImportPipeline
    @State private var librarySaveFailureCount = 0
    @State private var librarySaveFailureMessage: String?

    @MainActor
    init(
        store: LibraryStore? = nil,
        persistence: LibraryPersistence = LibraryPersistence(),
        libraryWriter: LibrarySnapshotWriter? = nil,
        renderQueue: RenderQueueCoordinator? = nil
    ) {
        self.persistence = persistence
        self.libraryWriter = libraryWriter ?? LibrarySnapshotWriter(persistence: persistence)
        let resolvedStore = store ?? persistence.loadStoreOrDefault()
        _store = State(initialValue: resolvedStore)
        let resolvedRenderQueue = renderQueue ?? RenderQueueCoordinator(store: resolvedStore)
        self.renderQueue = resolvedRenderQueue
        _pipeline = State(initialValue: TrackImportPipeline(
            store: resolvedStore,
            renderQueue: resolvedRenderQueue,
            artworkFallback: { url in
                // Music-drag imports byte-copy the raw library file, whose artwork
                // lives in Music's database, not the file — the iTunesLibrary lookup
                // stays app-side behind this seam (D-087).
                await MusicLibraryArtworkProvider().artworkData(forFileAt: url)
            }
        ))
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                store: store,
                playback: playback,
                route: $route,
                onImportTrack: { presentImporter(.track) },
                onImportFolder: { presentImporter(.folder) }
            )

            VStack(spacing: 0) {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BackbeatStyle.appBackground)
                    .clipped()

                MiniPlayerView(store: store, playback: playback, route: $route)
                    .layoutPriority(1)
            }
        }
        .background(BackbeatStyle.appBackground)
        .foregroundStyle(BackbeatStyle.text)
        .dropDestination(for: URL.self) { urls, _ in
            let audioURLs = AudioImportFilter.audioFileURLs(from: urls)
            guard !audioURLs.isEmpty else { return false }
            importAudioFiles(audioURLs, managesSecurityScope: true, musicLibraryArtwork: false)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(BackbeatStyle.primary.opacity(0.85), lineWidth: 2)
                    .background(BackbeatStyle.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(14)
            }
        }
        // AppKit shim for Apple Music drags only: Music vends legacy file
        // promises + an iTunes metadata plist, never the plain file URL the
        // SwiftUI dropDestination above requires. Finder drags never match
        // the shim's registered types, so the existing path is untouched.
        .overlay {
            MusicDropShim(
                onTargeted: { isDropTargeted = $0 },
                onImport: { urls in
                    // Music drags import the raw library file, whose artwork lives
                    // in Music's database — enable the pipeline's artwork fallback.
                    // Await through the shared import chain so the promise scratch
                    // directory outlives the copy into the managed library, and a
                    // concurrent Finder drop can't race dedupe.
                    let report = await pipeline.enqueue(urls: urls, managesSecurityScope: false, useArtworkFallback: true).value
                    presentImportReport(report)
                },
                onReject: { message in
                    dropRejectedMessage = message
                }
            )
        }
        // One fileImporter serves both import buttons: two .fileImporter
        // modifiers chained on the same view conflict in SwiftUI and only the
        // last one ever presents, which left Import Track dead at runtime.
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: activeImporter.allowedContentTypes,
            allowsMultipleSelection: activeImporter.allowsMultipleSelection,
            onCompletion: handleImporterCompletion
        )
        .alert("Import failed", isPresented: importFailedBinding) {
            Button("OK", role: .cancel) {
                importErrorMessage = nil
            }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert("Already in library", isPresented: duplicateWarningBinding) {
            Button("OK", role: .cancel) {
                duplicateWarningMessage = nil
            }
        } message: {
            Text(duplicateWarningMessage ?? "")
        }
        .alert("Can't import this track", isPresented: dropRejectedBinding) {
            Button("OK", role: .cancel) {
                dropRejectedMessage = nil
            }
        } message: {
            Text(dropRejectedMessage ?? "")
        }
        .alert("Library could not be fully loaded", isPresented: libraryRecoveryBinding) {
            Button("OK", role: .cancel) {
                store.libraryLoadRecoveryMessage = nil
            }
        } message: {
            Text(store.libraryLoadRecoveryMessage ?? "")
        }
        .alert("Couldn't save your library", isPresented: librarySaveFailureBinding) {
            Button("OK", role: .cancel) {
                librarySaveFailureMessage = nil
            }
        } message: {
            Text(librarySaveFailureMessage ?? "")
        }
        .onChange(of: persistenceSnapshot) { _, newSnapshot in
            scheduleLibrarySave(newSnapshot)
        }
        .onChange(of: route) { oldRoute, newRoute in
            if oldRoute == .player, newRoute != .player {
                playback.resetPracticePlayback(store: store)
            }
        }
        .onChange(of: store.playbackNormalizationSettings.isEnabled) { _, _ in
            // The Normalize toggle lives in the separate Settings scene and can't
            // reach the playing engines; re-apply gain here so the change reaches
            // live playback immediately instead of deferring to the next touch (F4).
            playback.applyOutputGain(store: store)
        }
        .task {
            // Per-file loudness cadence: each committed import re-triggers the
            // sweep immediately — batch-end triggering would be a silent behavior
            // change. Assigned here (post-install) rather than in init so the
            // closure captures the installed @State, and before any drop can land.
            pipeline.onTrackCommitted = { _ in analyzeMissingLoudnessProfiles() }
            // Loudness analysis is independent of the separation model; start it up front.
            // The htdemucs checkpoint ships in the app bundle, so rendering is always
            // available — enqueue any missing renders unconditionally. One-time: purge the
            // orphaned `.th` older builds downloaded into Application Support and the
            // vendored port's stale v1/v2 conversion caches (fail-soft, off the main
            // actor); the custom engine's live v3 cache is kept.
            analyzeMissingLoudnessProfiles()
            backfillImpreciseDurations()
            Task.detached(priority: .utility) { LegacyWeightsCleanup.purgeLegacyArtifacts() }
            renderQueue.enqueueMissingRenders()
        }
        .onDisappear {
            // The callback closure captures this view struct, whose @State
            // wrapper holds the pipeline — a retain cycle while assigned.
            // Clearing on disappear breaks it when the window closes (imports
            // can't start without the window); the .task above re-wires it on
            // every appearance.
            pipeline.onTrackCommitted = nil
        }
    }

    private var persistenceSnapshot: LibrarySnapshot {
        LibrarySnapshot(store: store)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch route {
        case .library:
            LibraryView(
                store: store,
                playback: playback,
                renderQueue: renderQueue,
                route: $route,
                onImportTrack: { presentImporter(.track) },
                onImportFolder: { presentImporter(.folder) },
                onDeleteTracks: deleteTracks
            )
        case .player:
            PlayerView(store: store, playback: playback, renderQueue: renderQueue, route: $route)
        case .playlist(let playlistID):
            PlaylistDetailView(
                playlistID: playlistID,
                store: store,
                playback: playback,
                route: $route
            )
        }
    }

    private var importFailedBinding: Binding<Bool> {
        Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )
    }

    private var duplicateWarningBinding: Binding<Bool> {
        Binding(
            get: { duplicateWarningMessage != nil },
            set: { if !$0 { duplicateWarningMessage = nil } }
        )
    }

    private var dropRejectedBinding: Binding<Bool> {
        Binding(
            get: { dropRejectedMessage != nil },
            set: { if !$0 { dropRejectedMessage = nil } }
        )
    }

    private var libraryRecoveryBinding: Binding<Bool> {
        Binding(
            get: { store.libraryLoadRecoveryMessage != nil },
            set: { if !$0 { store.libraryLoadRecoveryMessage = nil } }
        )
    }

    private var librarySaveFailureBinding: Binding<Bool> {
        Binding(
            get: { librarySaveFailureMessage != nil },
            set: { if !$0 { librarySaveFailureMessage = nil } }
        )
    }

    private func presentImporter(_ importer: BackbeatImporter) {
        activeImporter = importer
        isImporterPresented = true
    }

    private func handleImporterCompletion(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            switch activeImporter {
            case .track:
                importAudioFiles(urls, managesSecurityScope: true, musicLibraryArtwork: false)
            case .folder:
                guard let folderURL = urls.first else { return }
                importAudioFolder(folderURL)
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }

    private func importAudioFolder(_ folderURL: URL) {
        let batch = pipeline.enqueueFolder(folderURL)
        Task { @MainActor in
            presentImportReport(await batch.value)
        }
    }

    // `musicLibraryArtwork` maps to the pipeline's provider-neutral
    // `useArtworkFallback` — the D-087 vocabulary stays app-side.
    private func importAudioFiles(_ urls: [URL], managesSecurityScope: Bool, musicLibraryArtwork: Bool) {
        let batch = pipeline.enqueue(urls: urls, managesSecurityScope: managesSecurityScope, useArtworkFallback: musicLibraryArtwork)
        Task { @MainActor in
            presentImportReport(await batch.value)
        }
    }

    // The alert bindings present on any non-nil value, so these emptiness
    // guards are load-bearing — unguarded writes would pop a spurious empty
    // alert after every clean import.
    private func presentImportReport(_ report: ImportBatchReport) {
        if !report.failureDescriptions.isEmpty {
            importErrorMessage = report.failureDescriptions.joined(separator: "\n")
        }
        if !report.skippedDuplicateTitles.isEmpty {
            let titles = report.skippedDuplicateTitles.joined(separator: "\n")
            duplicateWarningMessage = "Skipped — these tracks are already in your library:\n\(titles)"
        }
    }

    @MainActor
    private func analyzeMissingLoudnessProfiles() {
        loudnessAnalysisTask?.cancel()
        let pendingTracks = store.tracks.filter { track in
            guard let profile = track.loudnessProfile else { return true }
            return profile.analyzerVersion < TrackLoudnessAnalyzerVersion.current
        }
        guard !pendingTracks.isEmpty else { return }

        let settings = store.playbackNormalizationSettings
        loudnessAnalysisTask = Task { @MainActor in
            let analyzer = TrackLoudnessAnalyzer(settings: settings)
            for track in pendingTracks {
                guard !Task.isCancelled else { return }
                do {
                    let profile = try await analyzer.analyze(sourceURL: track.sourceURL)
                    // Commit the finished profile even if a newer import cancelled
                    // this task mid-batch — discarding it here forced a duplicate
                    // full-file decode on the next pass (F15). The pre-analyze
                    // guard above still skips starting work once cancelled.
                    store.setLoudnessProfile(profile, for: track.id)
                    persistLibrary()
                } catch {
                    continue
                }
            }
        }
    }

    // Launch-once: new imports are born resolved (isDurationResolved: true),
    // so only pre-F1 tracks are ever pending, and a quit mid-sweep just
    // leaves them pending for the next launch — safe to cancel and retry.
    @MainActor
    private func backfillImpreciseDurations() {
        durationBackfillTask?.cancel()
        let pendingItems = store.tracks.filter { !$0.isDurationResolved }.map { track in
            TrackDurationBackfill.Item(
                trackID: track.id,
                sourceURL: track.sourceURL,
                currentDuration: track.duration
            )
        }
        guard !pendingItems.isEmpty else { return }

        durationBackfillTask = Task { @MainActor in
            await TrackDurationBackfill().run(
                items: pendingItems,
                probe: { url in try await AudioMetadataReader().preciseDuration(url: url) },
                onResolve: { trackID, outcome in
                    guard store.applyDurationBackfill(id: trackID, outcome: outcome) else { return }
                    persistLibrary()
                }
            )
        }
    }

    private func deleteTracks(_ tracksToDelete: [BackbeatTrack]) throws {
        // Best effort across the batch: one failed removal must not strand
        // the remaining deletions; the first error is rethrown after every
        // track was attempted (the deleteFiles convention).
        var firstError: Error?
        for track in tracksToDelete {
            // Cancel first so an in-flight render job is cancelled and its
            // completion handler sees the track gone.
            renderQueue.cancel(track.id)
            if store.nowPlayingTrackID == track.id {
                playback.stopRender(track: track, store: store)
            }
            do {
                try store.deleteTrack(id: track.id)
            } catch {
                firstError = firstError ?? error
            }
        }
        route = .library
        if let firstError {
            throw firstError
        }
    }

    private func persistLibrary() {
        scheduleLibrarySave(LibrarySnapshot(store: store))
    }

    // Debounced so slider drags coalesce into one save, written off the main
    // actor so the UI never blocks, and generation-stamped so a slow older
    // write can never replace a newer snapshot.
    private func scheduleLibrarySave(_ snapshot: LibrarySnapshot) {
        pendingLibrarySave?.cancel()
        let writer = libraryWriter
        let generation = writer.nextGeneration()
        pendingLibrarySave = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            do {
                try await Task.detached(priority: .utility) {
                    try writer.write(snapshot, generation: generation)
                }.value
                librarySaveFailureCount = 0
            } catch {
                // A persistent failure (disk full / permissions) silently lost
                // every change before this; log it and, after a few consecutive
                // failures, tell the user rather than only print()ing (F12).
                DebugLog.persistence.error("library.save.debounced.failed generation=\(generation) error=\(error.localizedDescription, privacy: .public)")
                librarySaveFailureCount += 1
                if librarySaveFailureCount >= 3, librarySaveFailureMessage == nil {
                    librarySaveFailureMessage = "Backline Boost hasn't been able to save your library for the last \(librarySaveFailureCount) changes (\(error.localizedDescription)). Check that the disk isn't full and that you can write to the app's Application Support folder."
                }
            }
        }
    }
}
