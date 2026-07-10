import Foundation
import Observation

@MainActor
@Observable
public final class LibraryStore {
    public var tracks: [BackbeatTrack]
    public var selectedTrackID: BackbeatTrack.ID?
    public var nowPlayingTrackID: BackbeatTrack.ID?
    public var selectedPlaybackVariant: RenderVariant
    public var nowPlayingPlaybackVariant: RenderVariant
    public var playlists: [BackbeatPlaylist]
    public var selectedPlaylistID: BackbeatPlaylist.ID?
    public var activeQueue: PlaybackQueue?
    public var selectedPlaybackSource: PlaybackSource
    public var nowPlayingPlaybackSource: PlaybackSource
    public var playbackElapsed: TimeInterval
    public var playbackProgress: Double
    public var isPlaybackPlaying: Bool
    public var volume: Double
    public var playbackNormalizationSettings: PlaybackNormalizationSettings
    public var renderFailureMessage: String?
    public var playbackErrorMessage: String?
    public var libraryLoadRecoveryMessage: String?
    public var practiceSpeed: Double
    public var practiceLoopMode: PracticeLoopMode
    public var practiceLoopRange: PracticeLoopRange?
    public var isPracticeZoomVisible: Bool
    // Sidebar section chrome. Unlike `isPracticeZoomVisible` (bound to an active
    // practice session) these are durable view preferences, so they persist.
    public var isPlaylistsSectionCollapsed: Bool
    public var isTracksSectionCollapsed: Bool
    public var isPlaylistOverflowExpanded: Bool
    public var isTracksOverflowExpanded: Bool
    // Library display order (D-102). A durable view preference like the
    // sidebar chrome above, so it persists.
    public var librarySortOrder: LibrarySortOrder

    public init(
        tracks: [BackbeatTrack] = [],
        selectedTrackID: BackbeatTrack.ID? = nil,
        nowPlayingTrackID: BackbeatTrack.ID? = nil,
        selectedPlaybackVariant: RenderVariant = .boostedDrums,
        nowPlayingPlaybackVariant: RenderVariant = .boostedDrums,
        playlists: [BackbeatPlaylist] = [],
        selectedPlaylistID: BackbeatPlaylist.ID? = nil,
        activeQueue: PlaybackQueue? = nil,
        selectedPlaybackSource: PlaybackSource? = nil,
        nowPlayingPlaybackSource: PlaybackSource? = nil,
        playbackElapsed: TimeInterval = 0,
        playbackProgress: Double = 0,
        isPlaybackPlaying: Bool = false,
        volume: Double = 0.8,
        playbackNormalizationSettings: PlaybackNormalizationSettings = .default,
        renderFailureMessage: String? = nil,
        isPlaylistsSectionCollapsed: Bool = false,
        isTracksSectionCollapsed: Bool = false,
        isPlaylistOverflowExpanded: Bool = false,
        isTracksOverflowExpanded: Bool = false,
        librarySortOrder: LibrarySortOrder = .default
    ) {
        self.tracks = tracks
        self.selectedTrackID = selectedTrackID
        self.nowPlayingTrackID = nowPlayingTrackID
        self.selectedPlaybackVariant = selectedPlaybackVariant
        self.nowPlayingPlaybackVariant = nowPlayingPlaybackVariant
        self.playlists = playlists
        self.selectedPlaylistID = selectedPlaylistID
        self.activeQueue = activeQueue
        self.selectedPlaybackSource = selectedPlaybackSource ?? PlaybackSource(renderVariant: selectedPlaybackVariant)
        self.nowPlayingPlaybackSource = nowPlayingPlaybackSource ?? PlaybackSource(renderVariant: nowPlayingPlaybackVariant)
        self.playbackElapsed = playbackElapsed
        self.playbackProgress = playbackProgress
        self.isPlaybackPlaying = isPlaybackPlaying
        self.volume = volume
        self.playbackNormalizationSettings = playbackNormalizationSettings
        self.renderFailureMessage = renderFailureMessage
        self.playbackErrorMessage = nil
        self.libraryLoadRecoveryMessage = nil
        self.practiceSpeed = 1
        self.practiceLoopMode = .off
        self.practiceLoopRange = nil
        self.isPracticeZoomVisible = false
        self.isPlaylistsSectionCollapsed = isPlaylistsSectionCollapsed
        self.isTracksSectionCollapsed = isTracksSectionCollapsed
        self.isPlaylistOverflowExpanded = isPlaylistOverflowExpanded
        self.isTracksOverflowExpanded = isTracksOverflowExpanded
        self.librarySortOrder = librarySortOrder
    }

    public func setLibrarySortOrder(_ order: LibrarySortOrder) {
        guard librarySortOrder != order else { return }
        librarySortOrder = order
    }

    public var selectedTrack: BackbeatTrack? {
        guard let selectedTrackID else { return tracks.first }
        return track(id: selectedTrackID)
    }

    public var nowPlayingTrack: BackbeatTrack? {
        guard let nowPlayingTrackID else { return nil }
        return track(id: nowPlayingTrackID)
    }

    public var selectedPlaylist: BackbeatPlaylist? {
        guard let selectedPlaylistID else { return nil }
        return playlist(id: selectedPlaylistID)
    }

    public var canPlayPreviousInQueue: Bool {
        guard let activeQueue, activeQueue.trackIDs.count > 1 else { return false }
        return activeQueue.currentIndex > 0 || playbackElapsed > 3 || activeQueue.repeatMode == .all
    }

    public var canPlayNextInQueue: Bool {
        guard let activeQueue, activeQueue.trackIDs.count > 1 else { return false }
        return activeQueue.currentIndex < activeQueue.trackIDs.count - 1 || activeQueue.repeatMode == .all
    }

    @discardableResult
    public func selectDetailPlaybackSource(_ source: PlaybackSource, for track: BackbeatTrack?) -> Bool {
        guard let track, playbackAsset(for: track, preferredSource: source) != nil else { return false }
        selectedPlaybackSource = source
        return true
    }

    @discardableResult
    public func selectNowPlayingPlaybackSource(_ source: PlaybackSource, for track: BackbeatTrack?) -> Bool {
        guard let track, playbackAsset(for: track, preferredSource: source) != nil else { return false }
        applyNowPlayingSource(source)
        return true
    }

    // Single write path for the nowPlayingPlaybackSource <-> queue
    // preferredSource invariant.
    private func applyNowPlayingSource(_ source: PlaybackSource) {
        nowPlayingPlaybackSource = source
        if var queue = activeQueue {
            queue.preferredSource = source
            activeQueue = queue
        }
    }

    // O(n) by design: practice-scale libraries make an ID index unjustified;
    // revisit only if libraries reach thousands of tracks.
    public func track(id: BackbeatTrack.ID) -> BackbeatTrack? {
        tracks.first(where: { $0.id == id })
    }

    public func playlist(id: BackbeatPlaylist.ID) -> BackbeatPlaylist? {
        playlists.first(where: { $0.id == id })
    }

    private func playlistIndex(id: BackbeatPlaylist.ID) -> Int? {
        playlists.firstIndex(where: { $0.id == id })
    }

    @discardableResult
    public func importTrack(
        id: BackbeatTrack.ID = UUID(),
        from metadata: AudioMetadata,
        sourceURL: URL,
        artworkURL: URL? = nil,
        dateAdded: Date = Date()
    ) -> BackbeatTrack {
        let track = BackbeatTrack(
            id: id,
            title: metadata.resolvedTitle,
            artist: metadata.artist,
            album: metadata.album,
            duration: metadata.duration,
            status: .imported,
            sourceURL: sourceURL,
            artworkURL: artworkURL,
            // New imports already read precise duration; only pre-existing
            // library entries are pending the launch backfill sweep.
            isDurationResolved: true,
            dateAdded: dateAdded
        )
        tracks.append(track)
        selectedTrackID = track.id
        return track
    }

    public func selectTrack(_ id: BackbeatTrack.ID) {
        selectedTrackID = id
    }

    @discardableResult
    public func selectRenderedTrackForInspection(_ id: BackbeatTrack.ID) -> Bool {
        guard let track = track(id: id) else { return false }
        selectedTrackID = id
        return detailRender(for: track) != nil
    }

    @discardableResult
    public func selectTrackForPlayback(_ id: BackbeatTrack.ID, restart: Bool = false) -> Bool {
        guard let track = track(id: id) else { return false }
        guard let render = detailRender(for: track) else { return false }
        let previousNowPlayingTrackID = nowPlayingTrackID
        selectedTrackID = id
        nowPlayingTrackID = id
        nowPlayingPlaybackVariant = render.variant
        if restart || previousNowPlayingTrackID != id || playbackProgress >= 1 {
            setPlaybackElapsed(0, duration: track.duration)
        }
        return true
    }

    public func deleteTrack(id: BackbeatTrack.ID) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let track = tracks[index]

        // Mutate all library state before touching the filesystem so a failed
        // file removal can never leave a half-deleted track in the library.
        tracks.remove(at: index)

        if selectedTrackID == id {
            selectedTrackID = tracks.first?.id
        }
        if nowPlayingTrackID == id {
            nowPlayingTrackID = nil
            nowPlayingPlaybackVariant = .boostedDrums
            isPlaybackPlaying = false
            playbackElapsed = 0
            playbackProgress = 0
            resetPracticeState()
        }

        for index in playlists.indices {
            playlists[index].trackIDs.removeAll { $0 == id }
            playlists[index].updatedAt = Date()
        }

        if var queue = activeQueue {
            queue.trackIDs.removeAll { $0 == id }
            if queue.trackIDs.isEmpty {
                activeQueue = nil
            } else {
                queue.currentIndex = min(queue.currentIndex, queue.trackIDs.count - 1)
                activeQueue = queue
            }
        }

        try deleteFiles(for: track)
    }

    @discardableResult
    public func createPlaylist(
        id: BackbeatPlaylist.ID = UUID(),
        name: String = "New Playlist",
        defaultPlaybackSource: PlaybackSource = .drumBoost,
        createdAt: Date = Date()
    ) -> BackbeatPlaylist {
        let playlist = BackbeatPlaylist(
            id: id,
            name: name,
            defaultPlaybackSource: defaultPlaybackSource,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        playlists.append(playlist)
        selectedPlaylistID = playlist.id
        return playlist
    }

    public func renamePlaylist(
        _ playlistID: BackbeatPlaylist.ID,
        to name: String,
        updatedAt: Date = Date()
    ) {
        guard let index = playlistIndex(id: playlistID) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[index].name = trimmedName.isEmpty ? "Untitled Playlist" : trimmedName
        playlists[index].updatedAt = updatedAt
    }

    public func setPlaylistDefaultPlaybackSource(
        _ source: PlaybackSource,
        for playlistID: BackbeatPlaylist.ID,
        updatedAt: Date = Date()
    ) {
        guard let index = playlistIndex(id: playlistID) else { return }
        guard playlists[index].defaultPlaybackSource != source else { return }
        playlists[index].defaultPlaybackSource = source
        playlists[index].updatedAt = updatedAt
    }

    public func addTracks(
        _ trackIDs: [BackbeatTrack.ID],
        to playlistID: BackbeatPlaylist.ID,
        updatedAt: Date = Date()
    ) {
        guard let index = playlistIndex(id: playlistID) else { return }
        var existingIDs = Set(playlists[index].trackIDs)
        let newIDs = trackIDs.filter { existingIDs.insert($0).inserted }
        guard !newIDs.isEmpty else { return }
        playlists[index].trackIDs.append(contentsOf: newIDs)
        playlists[index].updatedAt = updatedAt
    }

    public func removeTrack(
        _ trackID: BackbeatTrack.ID,
        from playlistID: BackbeatPlaylist.ID,
        updatedAt: Date = Date()
    ) {
        guard let index = playlistIndex(id: playlistID) else { return }
        let originalIDs = playlists[index].trackIDs
        playlists[index].trackIDs.removeAll { $0 == trackID }
        guard playlists[index].trackIDs != originalIDs else { return }
        playlists[index].updatedAt = updatedAt
    }

    public func deletePlaylist(_ playlistID: BackbeatPlaylist.ID) {
        guard let index = playlistIndex(id: playlistID) else { return }
        playlists.remove(at: index)

        if selectedPlaylistID == playlistID {
            selectedPlaylistID = nil
        }

        if activeQueue?.playlistID == playlistID {
            activeQueue = nil
            nowPlayingTrackID = nil
            isPlaybackPlaying = false
            playbackElapsed = 0
            playbackProgress = 0
            resetPracticeState()
        }
    }

    @discardableResult
    public func startPlaylist(
        _ playlistID: BackbeatPlaylist.ID,
        at startingTrackID: BackbeatTrack.ID? = nil,
        restart: Bool = true
    ) -> BackbeatTrack? {
        guard let playlist = playlist(id: playlistID) else { return nil }
        let playableTrackIDs = playlist.trackIDs.filter { track(id: $0) != nil }
        guard !playableTrackIDs.isEmpty else {
            playbackErrorMessage = "Playlist has no playable tracks."
            return nil
        }
        let startIndex: Int
        if let startingTrackID {
            guard let requestedIndex = playableTrackIDs.firstIndex(of: startingTrackID) else {
                playbackErrorMessage = "Track is not in this playlist."
                return nil
            }
            startIndex = requestedIndex
        } else {
            startIndex = 0
        }
        guard let firstTrack = track(id: playableTrackIDs[startIndex]) else { return nil }
        selectedPlaylistID = playlist.id
        resetPracticeState()
        activeQueue = PlaybackQueue(
            playlistID: playlist.id,
            trackIDs: playableTrackIDs,
            currentIndex: startIndex,
            preferredSource: playlist.defaultPlaybackSource
        )
        selectedTrackID = firstTrack.id
        nowPlayingTrackID = firstTrack.id
        nowPlayingPlaybackSource = playlist.defaultPlaybackSource
        if restart {
            setPlaybackElapsed(0, duration: firstTrack.duration)
        }
        playbackErrorMessage = nil
        return firstTrack
    }

    /// Starts a queue over the library's visible order (the D-102 hybrid
    /// double-click). `playlistID` stays nil, so playlist teardown
    /// (`deletePlaylist`) and playlist-order un-shuffle never apply; the
    /// caller passes the exact filtered+sorted IDs it is displaying and the
    /// queue snapshots them — clearing the search later does not widen it.
    @discardableResult
    public func startLibraryQueue(
        _ trackIDs: [BackbeatTrack.ID],
        startingAt startingTrackID: BackbeatTrack.ID,
        restart: Bool = true
    ) -> BackbeatTrack? {
        let playableTrackIDs = trackIDs.filter { track(id: $0) != nil }
        guard !playableTrackIDs.isEmpty else {
            playbackErrorMessage = "No playable tracks."
            return nil
        }
        guard let startIndex = playableTrackIDs.firstIndex(of: startingTrackID),
              let firstTrack = track(id: playableTrackIDs[startIndex]) else {
            playbackErrorMessage = "Track is not in the current list."
            return nil
        }
        resetPracticeState()
        activeQueue = PlaybackQueue(
            playlistID: nil,
            trackIDs: playableTrackIDs,
            currentIndex: startIndex,
            preferredSource: .drumBoost
        )
        selectedTrackID = firstTrack.id
        nowPlayingTrackID = firstTrack.id
        nowPlayingPlaybackSource = .drumBoost
        if restart {
            setPlaybackElapsed(0, duration: firstTrack.duration)
        }
        playbackErrorMessage = nil
        return firstTrack
    }

    @discardableResult
    public func startSingleTrackQueue(
        _ trackID: BackbeatTrack.ID,
        preferredSource: PlaybackSource,
        restart: Bool = true
    ) -> BackbeatTrack? {
        guard let track = track(id: trackID), playbackAsset(for: track, preferredSource: preferredSource) != nil else {
            playbackErrorMessage = "Track is not playable."
            return nil
        }
        resetPracticeState()
        activeQueue = PlaybackQueue(
            playlistID: nil,
            trackIDs: [trackID],
            currentIndex: 0,
            preferredSource: preferredSource
        )
        selectedTrackID = trackID
        nowPlayingTrackID = trackID
        nowPlayingPlaybackSource = preferredSource
        if restart {
            setPlaybackElapsed(0, duration: track.duration)
        }
        playbackErrorMessage = nil
        return track
    }

    @discardableResult
    public func advanceQueue(repeatingCurrentIfNeeded: Bool = true) -> BackbeatTrack? {
        guard var queue = activeQueue else { return nil }
        if repeatingCurrentIfNeeded, queue.repeatMode == .one, let currentTrackID = queue.currentTrackID {
            guard let currentTrack = track(id: currentTrackID) else { return nil }
            selectedTrackID = currentTrack.id
            nowPlayingTrackID = currentTrack.id
            nowPlayingPlaybackSource = queue.preferredSource
            setPlaybackElapsed(0, duration: currentTrack.duration)
            return currentTrack
        }

        // Bounded skip over dangling queue entries: a queue whose IDs no
        // longer resolve (e.g. after a lossy load) must terminate instead of
        // recursing forever when repeat-all wraps the index.
        var attempts = 0
        while attempts < queue.trackIDs.count {
            attempts += 1
            var nextIndex = queue.currentIndex + 1
            if nextIndex >= queue.trackIDs.count, queue.repeatMode == .all, !queue.trackIDs.isEmpty {
                nextIndex = 0
            }
            guard nextIndex < queue.trackIDs.count else { break }
            queue.currentIndex = nextIndex
            guard let nextTrack = track(id: queue.trackIDs[nextIndex]) else { continue }
            activeQueue = queue
            resetPracticeState()
            selectedTrackID = nextTrack.id
            nowPlayingTrackID = nextTrack.id
            nowPlayingPlaybackSource = queue.preferredSource
            setPlaybackElapsed(0, duration: nextTrack.duration)
            return nextTrack
        }

        activeQueue = queue
        isPlaybackPlaying = false
        if let currentTrack = nowPlayingTrack {
            stopPlayback(duration: currentTrack.duration)
        }
        return nil
    }

    @discardableResult
    public func retreatQueue() -> BackbeatTrack? {
        guard var queue = activeQueue else { return nowPlayingTrack }
        if playbackElapsed > 3 {
            if let currentTrack = nowPlayingTrack {
                setPlaybackElapsed(0, duration: currentTrack.duration)
            }
            return nowPlayingTrack
        }
        guard !queue.trackIDs.isEmpty else { return nil }
        let previousIndex: Int
        if queue.currentIndex == 0, queue.repeatMode == .all, queue.trackIDs.count > 1 {
            previousIndex = queue.trackIDs.count - 1
        } else {
            previousIndex = max(0, queue.currentIndex - 1)
        }
        queue.currentIndex = previousIndex
        activeQueue = queue
        guard let previousTrack = track(id: queue.trackIDs[previousIndex]) else {
            return nil
        }
        if previousTrack.id != nowPlayingTrackID {
            resetPracticeState()
        }
        selectedTrackID = previousTrack.id
        nowPlayingTrackID = previousTrack.id
        nowPlayingPlaybackSource = queue.preferredSource
        setPlaybackElapsed(0, duration: previousTrack.duration)
        return previousTrack
    }

    public func setActiveQueueSource(_ source: PlaybackSource) {
        applyNowPlayingSource(source)
    }

    public func cycleRepeatMode() {
        guard var queue = activeQueue else { return }
        switch queue.repeatMode {
        case .off:
            queue.repeatMode = .all
        case .all:
            queue.repeatMode = .one
        case .one:
            queue.repeatMode = .off
        }
        activeQueue = queue
    }

    public func toggleShuffleMode() {
        setShuffleEnabled(!(activeQueue?.isShuffleEnabled ?? false))
    }

    public func setShuffleEnabled(_ isEnabled: Bool) {
        guard var queue = activeQueue, queue.isShuffleEnabled != isEnabled else { return }
        let currentTrackID = queue.currentTrackID

        queue.isShuffleEnabled = isEnabled
        if isEnabled {
            if let currentTrackID {
                let remainingIDs = queue.trackIDs.filter { $0 != currentTrackID }.shuffled()
                queue.trackIDs = [currentTrackID] + remainingIDs
                queue.currentIndex = 0
            } else {
                queue.trackIDs.shuffle()
                queue.currentIndex = 0
            }
        } else if let playlistID = queue.playlistID, let playlist = playlist(id: playlistID) {
            let queuedIDs = Set(queue.trackIDs)
            queue.trackIDs = playlist.trackIDs.filter { queuedIDs.contains($0) && track(id: $0) != nil }
            if let currentTrackID, let restoredIndex = queue.trackIDs.firstIndex(of: currentTrackID) {
                queue.currentIndex = restoredIndex
            } else {
                queue.currentIndex = min(queue.currentIndex, max(0, queue.trackIDs.count - 1))
            }
        } else {
            // Library (and orphaned-playlist) queues have no playlist order to
            // restore; the persisted sort is their canonical order. Without
            // this branch, un-shuffle is a silent no-op for nil-playlistID
            // queues and the shuffled order is stranded permanently.
            let queuedIDs = Set(queue.trackIDs)
            queue.trackIDs = LibraryTrackQuery.visibleTracks(
                in: tracks.filter { queuedIDs.contains($0.id) },
                sort: librarySortOrder,
                searchText: ""
            ).map(\.id)
            if let currentTrackID, let restoredIndex = queue.trackIDs.firstIndex(of: currentTrackID) {
                queue.currentIndex = restoredIndex
            } else {
                queue.currentIndex = min(queue.currentIndex, max(0, queue.trackIDs.count - 1))
            }
        }

        activeQueue = queue
    }

    // Renders run from the background queue; starting one must never steal
    // the user's current selection.
    public func beginRendering(for id: BackbeatTrack.ID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].status = .rendering
    }

    public func markRenderFailed(for id: BackbeatTrack.ID, message: String? = nil) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].status = .renderFailed
        renderFailureMessage = message
    }

    /// A cancelled background render returns the track to the imported state
    /// so the next launch re-enqueues it.
    public func revertRenderingToImported(for id: BackbeatTrack.ID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }), tracks[index].status == .rendering else { return }
        tracks[index].status = .imported
    }

    /// Recovers a track whose recorded render files were deleted on disk. Such a
    /// `.ready` track is otherwise stuck forever — resolution hands back a
    /// dangling URL and playback surfaces a raw Foundation error with no path to
    /// re-render (F7). Drops any render whose file is gone and, if that leaves a
    /// `.ready` track without its renders, reverts it to `.imported` so the
    /// launch/enqueue scan re-renders it and playback falls back to Original.
    /// Returns true when it changed state.
    @discardableResult
    public func recoverMissingRenderFiles(for id: BackbeatTrack.ID) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        let missingVariants = tracks[index].activeRenders.compactMap { variant, record in
            FileManager.default.fileExists(atPath: record.fileURL.path) ? nil : variant
        }
        guard !missingVariants.isEmpty else { return false }
        for variant in missingVariants {
            tracks[index].removeRender(for: variant)
        }
        if tracks[index].status == .ready {
            tracks[index].status = .imported
        }
        return true
    }

    /// Legacy single-file boosted-render completion. The current pipeline
    /// completes renders via `completePracticeRender`; this helper remains to
    /// simulate pre-two-stem (legacy-format) libraries in tests.
    public func completeBoostedRender(
        for id: BackbeatTrack.ID,
        fileURL: URL,
        boostDB: Double,
        createdAt: Date = Date()
    ) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let render = RenderRecord(
            variant: .boostedDrums,
            fileURL: fileURL,
            boostDB: boostDB,
            createdAt: createdAt
        )
        tracks[index].promote(render: render)
        renderFailureMessage = nil
        if selectedTrackID == id {
            selectedPlaybackVariant = .boostedDrums
        }
        if nowPlayingTrackID == id || nowPlayingTrackID == nil {
            nowPlayingTrackID = id
            nowPlayingPlaybackVariant = .boostedDrums
            isPlaybackPlaying = false
            playbackElapsed = 0
            playbackProgress = 0
        }
    }

    public func completePracticeRender(
        for id: BackbeatTrack.ID,
        result: PracticeRenderResult,
        createdAt: Date = Date()
    ) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        // Capture the previous renders' files before the records are replaced;
        // deleting by recorded URL (not by name) is what keeps a same-title
        // sibling's files safe, including pre-UUID-named legacy renders.
        let supersededRenderURLs = [
            tracks[index].activeRender(for: .boostedDrums)?.fileURL,
            tracks[index].activeRender(for: .drums)?.fileURL,
            tracks[index].activeRender(for: .drumless)?.fileURL
        ].compactMap { $0 }.filter { $0 != result.drumsURL && $0 != result.drumlessURL }
        let drumsRender = RenderRecord(
            variant: .drums,
            fileURL: result.drumsURL,
            boostDB: 0,
            createdAt: createdAt
        )
        let drumlessRender = RenderRecord(
            variant: .drumless,
            fileURL: result.drumlessURL,
            boostDB: 0,
            createdAt: createdAt
        )
        // drumMixSettings is deliberately untouched: fresh imports carry the
        // 4 dB default, and a re-render must preserve the user's live-tuned
        // boost from the Player.
        tracks[index].removeRender(for: .boostedDrums)
        tracks[index].promote(render: drumsRender)
        tracks[index].promote(render: drumlessRender)
        renderFailureMessage = nil
        if selectedTrackID == id {
            selectedPlaybackSource = .drumBoost
            selectedPlaybackVariant = .drums
        }
        // Adopt the rendered track only when nothing is actively playing — a
        // background render completing while the user listens (even to this
        // track as Original) must never reset live playback state.
        if nowPlayingTrackID == nil || (nowPlayingTrackID == id && !isPlaybackPlaying) {
            nowPlayingTrackID = id
            nowPlayingPlaybackSource = .drumBoost
            nowPlayingPlaybackVariant = .drums
            isPlaybackPlaying = false
            playbackElapsed = 0
            playbackProgress = 0
        }
        for url in supersededRenderURLs where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func setDrumMixBoostDB(_ boostDB: Double, for trackID: BackbeatTrack.ID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        // Guard against unchanged writes so a slider drag doesn't fire @Observable
        // invalidation app-wide ~60-120×/s when the value hasn't moved — matching
        // the store's own equality-guard convention (setPlaybackElapsed) (F14).
        let settings = DrumMixSettings(boostDB: boostDB)
        guard tracks[index].drumMixSettings != settings else { return }
        tracks[index].drumMixSettings = settings
    }

    public func setPlaybackNormalizationEnabled(_ isEnabled: Bool) {
        playbackNormalizationSettings.isEnabled = isEnabled
    }

    public func setLoudnessProfile(_ profile: TrackLoudnessProfile, for trackID: BackbeatTrack.ID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].loudnessProfile = profile
    }

    /// Applies one `TrackDurationBackfill` resolution (Phase A launch sweep).
    /// Single MainActor entry point so the sweep never touches `tracks`
    /// directly. Returns true when it changed state, so the caller can skip a
    /// persist cycle on a no-op apply (F14 no-op-guard convention).
    @discardableResult
    public func applyDurationBackfill(id: BackbeatTrack.ID, outcome: TrackDurationBackfill.Outcome) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        switch outcome {
        case .keptEstimate:
            tracks[index].isDurationResolved = true
            return true
        case .updated(let duration):
            // The now-playing AND currently-playing track's live transport
            // scale comes from the engine's file-derived duration, not
            // `track.duration` (A1) — but this conjunct still matters:
            // `nowPlayingTrackID` is persisted and restored at launch with
            // `isPlaybackPlaying: false`, so a bare id check would
            // permanently skip the user's last-played track on every launch.
            // Leave it pending here; it heals on the next launch's sweep.
            if nowPlayingTrackID == id && isPlaybackPlaying {
                return false
            }
            // The service already thresholds `updated` vs `keptEstimate`;
            // this guard is defense against a caller passing an `updated`
            // whose value happens to match what's already persisted (F14).
            if abs(tracks[index].duration - duration) > 0.05 {
                tracks[index].duration = duration
            }
            tracks[index].isDurationResolved = true
            return true
        }
    }

    public func setPracticeSpeed(_ speed: Double) {
        practiceSpeed = speed.isFinite ? min(1.5, max(0.5, speed)) : 1
    }

    public func stepPracticeSpeed(by delta: Double) {
        setPracticeSpeed(practiceSpeed + delta)
    }

    public func setPracticeLoopMode(_ mode: PracticeLoopMode, duration: TimeInterval) {
        switch mode {
        case .off:
            clearPracticeLoop()
        case .song:
            practiceLoopMode = .song
            practiceLoopRange = nil
            isPracticeZoomVisible = false
        case .section:
            practiceLoopMode = .section
            if practiceLoopRange == nil {
                let start = min(max(0, playbackElapsed), max(0, duration))
                let end = min(max(0, duration), start + min(4, max(0, duration)))
                practiceLoopRange = PracticeLoopRange(start: start, end: end, duration: duration)
            }
            isPracticeZoomVisible = true
        }
    }

    public func setPracticeSectionLoop(start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        practiceLoopMode = .section
        practiceLoopRange = PracticeLoopRange(start: start, end: end, duration: duration)
        isPracticeZoomVisible = true
    }

    public func setPracticeLoopStart(_ elapsed: TimeInterval, duration: TimeInterval) {
        let end = practiceLoopRange?.end ?? min(max(0, duration), elapsed + 4)
        setPracticeSectionLoop(start: elapsed, end: end, duration: duration)
    }

    public func setPracticeLoopEnd(_ elapsed: TimeInterval, duration: TimeInterval) {
        let start = practiceLoopRange?.start ?? max(0, elapsed - 4)
        setPracticeSectionLoop(start: start, end: elapsed, duration: duration)
    }

    public func clearPracticeLoop() {
        practiceLoopMode = .off
        practiceLoopRange = nil
        isPracticeZoomVisible = false
    }

    public func setPracticeZoomVisible(_ isVisible: Bool) {
        isPracticeZoomVisible = isVisible && practiceLoopMode == .section
    }

    public func resetPracticeState() {
        practiceSpeed = 1
        clearPracticeLoop()
    }

    public func setPlaybackElapsed(_ elapsed: TimeInterval, duration: TimeInterval) {
        // Called on every 5Hz playback tick: write only on change so
        // observers are not notified for identical values.
        let newElapsed = min(max(0, elapsed), max(0, duration))
        let newProgress = duration > 0 ? min(1, max(0, newElapsed / duration)) : 0
        if playbackElapsed != newElapsed {
            playbackElapsed = newElapsed
        }
        if playbackProgress != newProgress {
            playbackProgress = newProgress
        }
    }

    public func seekPlayback(toProgress progress: Double, duration: TimeInterval) {
        setPlaybackElapsed(PlaybackScrubPosition.elapsed(progress: progress, duration: duration), duration: duration)
    }

    @discardableResult
    public func selectDetailPlaybackVariant(_ variant: RenderVariant, for track: BackbeatTrack?) -> Bool {
        applyPlaybackVariant(variant, for: track, into: \.selectedPlaybackVariant)
    }

    @discardableResult
    public func selectNowPlayingPlaybackVariant(_ variant: RenderVariant, for track: BackbeatTrack?) -> Bool {
        applyPlaybackVariant(variant, for: track, into: \.nowPlayingPlaybackVariant)
    }

    @discardableResult
    private func applyPlaybackVariant(
        _ variant: RenderVariant,
        for track: BackbeatTrack?,
        into keyPath: ReferenceWritableKeyPath<LibraryStore, RenderVariant>
    ) -> Bool {
        guard track?.activeRender(for: variant) != nil else { return false }
        self[keyPath: keyPath] = variant
        return true
    }

    public func setVolume(toProgress progress: Double) {
        let clamped = min(1, max(0, progress))
        guard volume != clamped else { return }
        volume = clamped
    }

    public func setPlaybackPlaying(_ isPlaying: Bool) {
        if isPlaybackPlaying != isPlaying {
            isPlaybackPlaying = isPlaying
        }
    }

    public func stopPlayback(duration: TimeInterval) {
        isPlaybackPlaying = false
        setPlaybackElapsed(0, duration: duration)
        resetPracticeState()
    }

    private func deleteFiles(for track: BackbeatTrack) throws {
        var seenPaths = Set<String>()
        let urls = [track.sourceURL, track.artworkURL].compactMap { $0 }
            + track.activeRenders.values.map(\.fileURL)

        // Best effort: one failed removal must not strand the remaining
        // files; the first error is rethrown after everything was attempted.
        var firstError: Error?
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }
}
