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
    @State private var pendingLibrarySave: Task<Void, Never>?

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
        self.renderQueue = renderQueue ?? RenderQueueCoordinator(store: resolvedStore)
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
                    // Music drags import the raw library file, whose artwork
                    // lives in Music's database — allow the library lookup.
                    await importAudioFilesNow(urls, managesSecurityScope: false, musicLibraryArtwork: true)
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
        .onChange(of: persistenceSnapshot) { _, newSnapshot in
            scheduleLibrarySave(newSnapshot)
        }
        .onChange(of: route) { oldRoute, newRoute in
            if oldRoute == .player, newRoute != .player {
                playback.resetPracticePlayback(store: store)
            }
        }
        .task {
            // Loudness analysis is independent of the separation model; start it up front.
            // The htdemucs checkpoint ships in the app bundle, so rendering is always
            // available — enqueue any missing renders unconditionally. One-time: purge the
            // orphaned `.th` older builds downloaded into Application Support and the
            // vendored port's stale v1/v2 conversion caches (fail-soft, off the main
            // actor); the custom engine's live v3 cache is kept.
            analyzeMissingLoudnessProfiles()
            Task.detached(priority: .utility) { LegacyWeightsCleanup.purgeLegacyArtifacts() }
            renderQueue.enqueueMissingRenders()
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
                onDeleteTrack: deleteTrack
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
        Task {
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
                await importAudioFilesNow(audioURLs, managesSecurityScope: false, musicLibraryArtwork: false)
            } catch {
                await MainActor.run {
                    importErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func importAudioFiles(_ urls: [URL], managesSecurityScope: Bool, musicLibraryArtwork: Bool) {
        Task {
            await importAudioFilesNow(urls, managesSecurityScope: managesSecurityScope, musicLibraryArtwork: musicLibraryArtwork)
        }
    }

    /// Shared import loop. Completes only after every file is imported (or
    /// skipped), so callers holding short-lived source files — like the
    /// Music drop shim's promise scratch directory — can clean up safely
    /// after awaiting it. Duplicates are skipped and reported in one warning.
    /// `musicLibraryArtwork` is true only for Music-drag imports: it allows
    /// the Music-library artwork lookup, whose first use triggers the
    /// "Media & Apple Music" consent prompt (D-087) — a prompt Finder and
    /// panel imports must never raise.
    private func importAudioFilesNow(_ urls: [URL], managesSecurityScope: Bool, musicLibraryArtwork: Bool) async {
        var skippedDuplicates: [String] = []
        do {
            for url in urls {
                if let existingTitle = try await importAudioFile(url, managesSecurityScope: managesSecurityScope, musicLibraryArtwork: musicLibraryArtwork) {
                    skippedDuplicates.append(existingTitle)
                }
            }
        } catch {
            await MainActor.run {
                importErrorMessage = error.localizedDescription
            }
        }
        if !skippedDuplicates.isEmpty {
            let titles = skippedDuplicates.joined(separator: "\n")
            await MainActor.run {
                duplicateWarningMessage = "Skipped — these tracks are already in your library:\n\(titles)"
            }
        }
    }

    /// Imports one file, or returns the existing track's title when the file
    /// is byte-identical to an original the library already stores.
    private func importAudioFile(_ url: URL, managesSecurityScope: Bool, musicLibraryArtwork: Bool) async throws -> String? {
        let didAccess = managesSecurityScope && url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        DebugLog.importing.notice("import.start file=\(url.lastPathComponent, privacy: .public) ext=\(url.pathExtension, privacy: .public) managesScope=\(managesSecurityScope) accessGranted=\(didAccess)")

        let storedSources = await MainActor.run {
            store.tracks.map { (title: $0.title, sourceURL: $0.sourceURL) }
        }
        if let match = DuplicateTrackDetector().existingDuplicate(
            of: url,
            among: storedSources.map(\.sourceURL)
        ) {
            let existingTitle = storedSources.first { $0.sourceURL == match }?.title
            DebugLog.importing.notice("import.duplicate title=\(existingTitle ?? "?", privacy: .public)")
            return existingTitle ?? url.deletingPathExtension().lastPathComponent
        }

        let metadata = try await AudioMetadataReader().read(url: url)
        DebugLog.importing.notice("import.metadata title=\(metadata.resolvedTitle, privacy: .public) artworkBytes=\(metadata.artworkData?.count ?? 0)")
        var artworkData = metadata.artworkData
        var artworkSource = artworkData == nil ? "none" : "embedded"
        if artworkData == nil && musicLibraryArtwork {
            // Music-drag imports byte-copy the raw library file, whose
            // artwork lives in Music's database, not the file (D-087).
            artworkData = await MusicLibraryArtworkProvider().artworkData(forFileAt: url)
            if artworkData != nil {
                artworkSource = "musiclibrary"
            }
        }
        let managedURL = try ManagedAudioLibrary().storeSourceFile(url)
        let trackID = UUID()
        // Metadata carries no artwork type info; the store sniffs magic bytes.
        let artworkURL = try AudioArtworkStore().storeArtwork(
            artworkData,
            contentType: nil,
            trackID: trackID
        )
        DebugLog.importing.notice("import.artwork stored=\(artworkURL != nil) source=\(artworkSource, privacy: .public) file=\(artworkURL?.lastPathComponent ?? "none", privacy: .public)")
        await MainActor.run {
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
            analyzeMissingLoudnessProfiles()
            DebugLog.importing.notice("import.done trackID=\(trackID.uuidString, privacy: .public) title=\(track.title, privacy: .public) hasArtwork=\(artworkURL != nil)")
        }
        return nil
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
                    guard !Task.isCancelled else { return }
                    store.setLoudnessProfile(profile, for: track.id)
                    persistLibrary()
                } catch {
                    continue
                }
            }
        }
    }

    private func deleteTrack(_ track: BackbeatTrack) throws {
        // Cancel first so an in-flight render job is cancelled and its
        // completion handler sees the track gone.
        renderQueue.cancel(track.id)
        if store.nowPlayingTrackID == track.id {
            playback.stopRender(track: track, store: store)
        }
        try store.deleteTrack(id: track.id)
        route = .library
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
        pendingLibrarySave = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            do {
                try await Task.detached(priority: .utility) {
                    try writer.write(snapshot, generation: generation)
                }.value
            } catch {
                print("Backbeat library save failed: \(error.localizedDescription)")
            }
        }
    }
}
