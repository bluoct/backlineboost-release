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
    @State private var durationBackfillTask: Task<Void, Never>?
    @State private var persistenceCoordinator: LibraryPersistenceCoordinator
    // @State (not `let`) so the pipeline's chain instance survives view
    // re-init exactly as the former @State importChain did.
    @State private var pipeline: TrackImportPipeline
    // Same @State-survives-re-init reasoning as `pipeline`.
    @State private var loudnessAnalysisQueue: LoudnessAnalysisQueue

    @MainActor
    init(
        store: LibraryStore? = nil,
        persistence: LibraryPersistence = LibraryPersistence(),
        libraryWriter: LibrarySnapshotWriter? = nil,
        renderQueue: RenderQueueCoordinator? = nil,
        // Required, not defaulted: a fallback here would duplicate
        // BackbeatApp.init's wiring verbatim (and drift from it), and an
        // exercised fallback would build a second writer whose generation
        // counter shares no stale-guard with the app's coordinator.
        persistenceCoordinator: LibraryPersistenceCoordinator,
        loudnessAnalysisQueue: LoudnessAnalysisQueue
    ) {
        self.persistence = persistence
        self.libraryWriter = libraryWriter ?? LibrarySnapshotWriter(persistence: persistence)
        let resolvedStore = store ?? persistence.loadStoreOrDefault()
        _store = State(initialValue: resolvedStore)
        let resolvedRenderQueue = renderQueue ?? RenderQueueCoordinator(store: resolvedStore)
        self.renderQueue = resolvedRenderQueue
        _persistenceCoordinator = State(initialValue: persistenceCoordinator)
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
        _loudnessAnalysisQueue = State(initialValue: loudnessAnalysisQueue)
    }

    var body: some View {
        // Split from the modifier chain below: SwiftUI's type-checker times
        // out on the combined chain (too many stacked .alert/.onChange calls
        // in one expression).
        rootContent
            .alert("Playback failed", isPresented: playbackFailureBinding) {
                Button("OK", role: .cancel) {
                    store.playbackFailure = nil
                }
            } message: {
                Text(store.playbackFailure?.userMessage ?? "")
            }
            .onChange(of: persistenceSnapshot) { _, _ in
                persistenceCoordinator.noteLibraryChanged()
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
                // Statuses must be honest before anything consumes them: the loudness
                // sweep would decode dead paths and the launch scan would skip a stale
                // `.ready` whose files are gone (D-107).
                store.reconcileLibraryFiles()
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

    private var rootContent: some View {
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
                persistenceCoordinator.saveFailureMessage = nil
            }
        } message: {
            Text(persistenceCoordinator.saveFailureMessage ?? "")
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
            get: { persistenceCoordinator.saveFailureMessage != nil },
            set: { if !$0 { persistenceCoordinator.saveFailureMessage = nil } }
        )
    }

    private var playbackFailureBinding: Binding<Bool> {
        Binding(
            get: { store.playbackFailure != nil },
            set: { if !$0 { store.playbackFailure = nil } }
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

    // Serial + deduplicated (EFF-001): builds the current "missing a profile"
    // snapshot and hands it to `loudnessAnalysisQueue`, which drops anything
    // already pending or in flight rather than cancelling and restarting it.
    // Safe to call on every trigger (launch + every per-file commit) for the
    // same reason the old cancel-and-restart sweep was — the queue is the
    // single source of truth for what's actually running.
    @MainActor
    private func analyzeMissingLoudnessProfiles() {
        let pendingTracks = store.tracks.filter { track in
            guard track.status != .sourceMissing else { return false }
            guard let profile = track.loudnessProfile else { return true }
            return profile.analyzerVersion < TrackLoudnessAnalyzerVersion.current
        }
        guard !pendingTracks.isEmpty else { return }

        let settings = store.playbackNormalizationSettings
        let items = pendingTracks.map { track in
            LoudnessAnalysisQueue.Item(trackID: track.id, sourceURL: track.sourceURL, settings: settings)
        }
        Task { await loudnessAnalysisQueue.enqueue(items) }
    }

    // Launch-once: new imports are born resolved (isDurationResolved: true),
    // so only pre-F1 tracks are ever pending, and a quit mid-sweep just
    // leaves them pending for the next launch — safe to cancel and retry.
    @MainActor
    private func backfillImpreciseDurations() {
        durationBackfillTask?.cancel()
        // Same .sourceMissing skip as the loudness sweep: probing a dead path
        // would burn the one-shot isDurationResolved flag on a .keptEstimate.
        let pendingItems = store.tracks.filter { !$0.isDurationResolved && $0.status != .sourceMissing }.map { track in
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
                    persistenceCoordinator.noteLibraryChanged()
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
}
