import Foundation

public final class LibraryDecodeDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var droppedTracks = 0
    private var droppedPlaylists = 0
    private var defaultedFields = 0

    public var droppedTrackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedTracks
    }

    public var droppedPlaylistCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedPlaylists
    }

    public var defaultedFieldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return defaultedFields
    }

    public init() {}

    func recordDroppedTrack() {
        lock.lock()
        defer { lock.unlock() }
        droppedTracks += 1
    }

    func recordDroppedPlaylist() {
        lock.lock()
        defer { lock.unlock() }
        droppedPlaylists += 1
    }

    func recordDefaultedField() {
        lock.lock()
        defer { lock.unlock() }
        defaultedFields += 1
    }
}

// Decodes any value without inspecting it, so a lossy array can skip past a
// malformed element and keep the container index advancing.
private struct SkippedCodableValue: Decodable {
    init(from decoder: Decoder) throws {}
}

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let decodeDiagnosticsKey = CodingUserInfoKey(rawValue: "backbeat.libraryDecodeDiagnostics")!

    public let schemaVersion: Int
    public let tracks: [BackbeatTrack]
    public let selectedTrackID: BackbeatTrack.ID?
    public let nowPlayingTrackID: BackbeatTrack.ID?
    public let selectedPlaybackVariant: RenderVariant
    public let nowPlayingPlaybackVariant: RenderVariant
    public let playlists: [BackbeatPlaylist]
    public let selectedPlaylistID: BackbeatPlaylist.ID?
    public let activeQueue: PlaybackQueue?
    public let selectedPlaybackSource: PlaybackSource
    public let nowPlayingPlaybackSource: PlaybackSource
    public let volume: Double
    public let playbackNormalizationSettings: PlaybackNormalizationSettings
    public let isPlaylistsSectionCollapsed: Bool
    public let isTracksSectionCollapsed: Bool
    public let isPlaylistOverflowExpanded: Bool
    public let isTracksOverflowExpanded: Bool
    public let librarySortOrder: LibrarySortOrder

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tracks
        case selectedTrackID
        case nowPlayingTrackID
        case selectedPlaybackVariant
        case nowPlayingPlaybackVariant
        case playlists
        case selectedPlaylistID
        case activeQueue
        case selectedPlaybackSource
        case nowPlayingPlaybackSource
        case volume
        case playbackNormalizationSettings
        case isPlaylistsSectionCollapsed
        case isTracksSectionCollapsed
        case isPlaylistOverflowExpanded
        case isTracksOverflowExpanded
        case librarySortOrder
    }

    public init(
        schemaVersion: Int = 1,
        tracks: [BackbeatTrack],
        selectedTrackID: BackbeatTrack.ID?,
        nowPlayingTrackID: BackbeatTrack.ID? = nil,
        selectedPlaybackVariant: RenderVariant = .boostedDrums,
        nowPlayingPlaybackVariant: RenderVariant? = nil,
        playlists: [BackbeatPlaylist] = [],
        selectedPlaylistID: BackbeatPlaylist.ID? = nil,
        activeQueue: PlaybackQueue? = nil,
        selectedPlaybackSource: PlaybackSource? = nil,
        nowPlayingPlaybackSource: PlaybackSource? = nil,
        playbackNormalizationSettings: PlaybackNormalizationSettings = .default,
        volume: Double,
        isPlaylistsSectionCollapsed: Bool = false,
        isTracksSectionCollapsed: Bool = false,
        isPlaylistOverflowExpanded: Bool = false,
        isTracksOverflowExpanded: Bool = false,
        librarySortOrder: LibrarySortOrder = .default
    ) {
        self.schemaVersion = schemaVersion
        self.tracks = tracks
        self.selectedTrackID = selectedTrackID
        self.nowPlayingTrackID = nowPlayingTrackID
        self.selectedPlaybackVariant = selectedPlaybackVariant
        self.nowPlayingPlaybackVariant = nowPlayingPlaybackVariant ?? selectedPlaybackVariant
        self.playlists = playlists
        self.selectedPlaylistID = selectedPlaylistID
        self.activeQueue = activeQueue
        self.selectedPlaybackSource = selectedPlaybackSource ?? PlaybackSource(renderVariant: selectedPlaybackVariant)
        self.nowPlayingPlaybackSource = nowPlayingPlaybackSource ?? PlaybackSource(renderVariant: self.nowPlayingPlaybackVariant)
        self.volume = volume
        self.playbackNormalizationSettings = playbackNormalizationSettings
        self.isPlaylistsSectionCollapsed = isPlaylistsSectionCollapsed
        self.isTracksSectionCollapsed = isTracksSectionCollapsed
        self.isPlaylistOverflowExpanded = isPlaylistOverflowExpanded
        self.isTracksOverflowExpanded = isTracksOverflowExpanded
        self.librarySortOrder = librarySortOrder
    }

    // Missing keys default silently (forward compatibility); a key that is
    // present but malformed is defaulted AND recorded, so the load path can
    // back up the file and tell the user instead of silently rewriting it.
    private static func decodeTolerantly<T: Decodable>(
        _ type: T.Type,
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        diagnostics: LibraryDecodeDiagnostics?
    ) -> T? {
        do {
            return try container.decodeIfPresent(type, forKey: key)
        } catch {
            diagnostics?.recordDefaultedField()
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Library snapshot schema version \(schemaVersion) is newer than the supported version \(Self.currentSchemaVersion)."
            )
        }

        let diagnostics = decoder.userInfo[Self.decodeDiagnosticsKey] as? LibraryDecodeDiagnostics
        var tracksContainer = try container.nestedUnkeyedContainer(forKey: .tracks)
        var decodedTracks: [BackbeatTrack] = []
        while !tracksContainer.isAtEnd {
            do {
                decodedTracks.append(try tracksContainer.decode(BackbeatTrack.self))
            } catch {
                _ = try tracksContainer.decode(SkippedCodableValue.self)
                diagnostics?.recordDroppedTrack()
            }
        }
        tracks = decodedTracks
        // Every non-track field is now tolerant: a single present-but-malformed
        // scalar used to throw the whole init out to the empty-library recovery
        // path, wiping a healthy library over one bad value (F6). Scalars default
        // (and are recorded); playlists skip per element like tracks.
        selectedTrackID = Self.decodeTolerantly(BackbeatTrack.ID.self, in: container, forKey: .selectedTrackID, diagnostics: diagnostics)
        nowPlayingTrackID = Self.decodeTolerantly(BackbeatTrack.ID.self, in: container, forKey: .nowPlayingTrackID, diagnostics: diagnostics)
        selectedPlaybackVariant = Self.decodeTolerantly(RenderVariant.self, in: container, forKey: .selectedPlaybackVariant, diagnostics: diagnostics) ?? .boostedDrums
        nowPlayingPlaybackVariant = Self.decodeTolerantly(RenderVariant.self, in: container, forKey: .nowPlayingPlaybackVariant, diagnostics: diagnostics) ?? selectedPlaybackVariant

        var decodedPlaylists: [BackbeatPlaylist] = []
        if container.contains(.playlists) {
            do {
                var playlistsContainer = try container.nestedUnkeyedContainer(forKey: .playlists)
                while !playlistsContainer.isAtEnd {
                    do {
                        decodedPlaylists.append(try playlistsContainer.decode(BackbeatPlaylist.self))
                    } catch {
                        _ = try playlistsContainer.decode(SkippedCodableValue.self)
                        diagnostics?.recordDroppedPlaylist()
                    }
                }
            } catch {
                // `.playlists` is present but not an array — drop the field.
                diagnostics?.recordDefaultedField()
            }
        }
        playlists = decodedPlaylists

        selectedPlaylistID = Self.decodeTolerantly(BackbeatPlaylist.ID.self, in: container, forKey: .selectedPlaylistID, diagnostics: diagnostics)
        activeQueue = Self.decodeTolerantly(PlaybackQueue.self, in: container, forKey: .activeQueue, diagnostics: diagnostics)
        selectedPlaybackSource = Self.decodeTolerantly(PlaybackSource.self, in: container, forKey: .selectedPlaybackSource, diagnostics: diagnostics)
            ?? PlaybackSource(renderVariant: selectedPlaybackVariant)
        nowPlayingPlaybackSource = Self.decodeTolerantly(PlaybackSource.self, in: container, forKey: .nowPlayingPlaybackSource, diagnostics: diagnostics)
            ?? PlaybackSource(renderVariant: nowPlayingPlaybackVariant)
        volume = Self.decodeTolerantly(Double.self, in: container, forKey: .volume, diagnostics: diagnostics) ?? 0.8
        playbackNormalizationSettings = Self.decodeTolerantly(PlaybackNormalizationSettings.self, in: container, forKey: .playbackNormalizationSettings, diagnostics: diagnostics) ?? .default
        isPlaylistsSectionCollapsed = Self.decodeTolerantly(Bool.self, in: container, forKey: .isPlaylistsSectionCollapsed, diagnostics: diagnostics) ?? false
        isTracksSectionCollapsed = Self.decodeTolerantly(Bool.self, in: container, forKey: .isTracksSectionCollapsed, diagnostics: diagnostics) ?? false
        isPlaylistOverflowExpanded = Self.decodeTolerantly(Bool.self, in: container, forKey: .isPlaylistOverflowExpanded, diagnostics: diagnostics) ?? false
        isTracksOverflowExpanded = Self.decodeTolerantly(Bool.self, in: container, forKey: .isTracksOverflowExpanded, diagnostics: diagnostics) ?? false
        // LibrarySortOrder's own decoder already degrades unknown values to
        // the default without throwing, so this wrapper only catches a
        // structurally malformed value (e.g. not a dictionary).
        librarySortOrder = Self.decodeTolerantly(LibrarySortOrder.self, in: container, forKey: .librarySortOrder, diagnostics: diagnostics) ?? .default
    }

    @MainActor
    public init(store: LibraryStore) {
        self.init(
            tracks: store.tracks,
            selectedTrackID: store.selectedTrackID,
            nowPlayingTrackID: store.nowPlayingTrackID,
            selectedPlaybackVariant: store.selectedPlaybackVariant,
            nowPlayingPlaybackVariant: store.nowPlayingPlaybackVariant,
            playlists: store.playlists,
            selectedPlaylistID: store.selectedPlaylistID,
            activeQueue: store.activeQueue,
            selectedPlaybackSource: store.selectedPlaybackSource,
            nowPlayingPlaybackSource: store.nowPlayingPlaybackSource,
            playbackNormalizationSettings: store.playbackNormalizationSettings,
            volume: store.volume,
            isPlaylistsSectionCollapsed: store.isPlaylistsSectionCollapsed,
            isTracksSectionCollapsed: store.isTracksSectionCollapsed,
            isPlaylistOverflowExpanded: store.isPlaylistOverflowExpanded,
            isTracksOverflowExpanded: store.isTracksOverflowExpanded,
            librarySortOrder: store.librarySortOrder
        )
    }

    @MainActor
    public func makeStore() -> LibraryStore {
        // A lossy decode can drop tracks while the queue decodes verbatim, so
        // scrub dangling queue IDs before they reach the store.
        let validIDs = Set(tracks.map(\.id))
        let sanitizedQueue: PlaybackQueue? = activeQueue.flatMap { queue in
            let keptIDs = queue.trackIDs.filter { validIDs.contains($0) }
            guard !keptIDs.isEmpty else { return nil }
            var sanitized = queue
            sanitized.trackIDs = keptIDs
            sanitized.currentIndex = queue.currentTrackID.flatMap { keptIDs.firstIndex(of: $0) }
                ?? min(queue.currentIndex, keptIDs.count - 1)
            return sanitized
        }
        return LibraryStore(
            tracks: tracks,
            selectedTrackID: selectedTrackID,
            nowPlayingTrackID: nowPlayingTrackID,
            selectedPlaybackVariant: selectedPlaybackVariant,
            nowPlayingPlaybackVariant: nowPlayingPlaybackVariant,
            playlists: playlists,
            selectedPlaylistID: selectedPlaylistID,
            activeQueue: sanitizedQueue,
            selectedPlaybackSource: selectedPlaybackSource,
            nowPlayingPlaybackSource: nowPlayingPlaybackSource,
            playbackElapsed: 0,
            playbackProgress: 0,
            isPlaybackPlaying: false,
            volume: volume,
            playbackNormalizationSettings: playbackNormalizationSettings,
            renderFailureMessage: nil,
            isPlaylistsSectionCollapsed: isPlaylistsSectionCollapsed,
            isTracksSectionCollapsed: isTracksSectionCollapsed,
            isPlaylistOverflowExpanded: isPlaylistOverflowExpanded,
            isTracksOverflowExpanded: isTracksOverflowExpanded,
            librarySortOrder: librarySortOrder
        )
    }
}

// Serializes snapshot writes and skips stale ones, so a slow in-flight write
// of an older snapshot can never replace a newer one on disk — including the
// synchronous flush at app termination racing a background debounced save.
public final class LibrarySnapshotWriter: @unchecked Sendable {
    private let persistence: LibraryPersistence
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var scheduledGeneration = 0
    private var writtenGeneration = 0

    public init(persistence: LibraryPersistence) {
        self.persistence = persistence
    }

    public func nextGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        scheduledGeneration += 1
        return scheduledGeneration
    }

    public func write(_ snapshot: LibrarySnapshot, generation: Int) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isStale(generation) else { return }
        try persistence.save(snapshot)
        recordWritten(generation)
    }

    private func isStale(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation <= writtenGeneration
    }

    private func recordWritten(_ generation: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        writtenGeneration = generation
    }
}

public enum LibraryPersistenceError: Error {
    case migrationFailed(underlying: Error)
}

public struct LibraryPersistence: Sendable {
    public let snapshotURL: URL
    private let legacySnapshotURL: URL?
    private let managedSourceDirectory: URL
    private let renderRootDirectory: URL
    private let artworkDirectory: URL

    public init(
        snapshotURL: URL = BackbeatFileLocations.librarySnapshotURL,
        legacySnapshotURL: URL? = nil,
        managedSourceDirectory: URL = BackbeatFileLocations.managedSourceDirectory,
        renderRootDirectory: URL = BackbeatFileLocations.renderRootDirectory,
        artworkDirectory: URL = BackbeatFileLocations.artworkDirectory
    ) {
        self.snapshotURL = snapshotURL
        if let legacySnapshotURL {
            self.legacySnapshotURL = legacySnapshotURL
        } else if snapshotURL.standardizedFileURL == BackbeatFileLocations.librarySnapshotURL.standardizedFileURL {
            self.legacySnapshotURL = BackbeatFileLocations.legacyLibrarySnapshotURL
        } else {
            self.legacySnapshotURL = nil
        }
        self.managedSourceDirectory = managedSourceDirectory
        self.renderRootDirectory = renderRootDirectory
        self.artworkDirectory = artworkDirectory
    }

    public func save(_ snapshot: LibrarySnapshot) throws {
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    struct LibraryLoadResult {
        let snapshot: LibrarySnapshot
        let droppedTrackCount: Int
        let droppedPlaylistCount: Int
        let defaultedFieldCount: Int
        let sourceURL: URL

        var isLossy: Bool {
            droppedTrackCount > 0 || droppedPlaylistCount > 0 || defaultedFieldCount > 0
        }
    }

    public func load() throws -> LibrarySnapshot? {
        try loadReportingRecovery()?.snapshot
    }

    func loadReportingRecovery() throws -> LibraryLoadResult? {
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            return try decodeSnapshot(at: snapshotURL)
        }

        guard
            let legacySnapshotURL,
            FileManager.default.fileExists(atPath: legacySnapshotURL.path)
        else {
            return nil
        }

        let legacyResult = try decodeSnapshot(at: legacySnapshotURL)
        do {
            let migratedSnapshot = try migrateLegacySnapshot(legacyResult.snapshot)
            try save(migratedSnapshot)
            return LibraryLoadResult(
                snapshot: migratedSnapshot,
                droppedTrackCount: legacyResult.droppedTrackCount,
                droppedPlaylistCount: legacyResult.droppedPlaylistCount,
                defaultedFieldCount: legacyResult.defaultedFieldCount,
                sourceURL: legacyResult.sourceURL
            )
        } catch {
            // The legacy file decoded fine; this is a disk/migration failure,
            // not corruption — it must not be reported (or backed up) as such.
            throw LibraryPersistenceError.migrationFailed(underlying: error)
        }
    }

    private func decodeSnapshot(at url: URL) throws -> LibraryLoadResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let diagnostics = LibraryDecodeDiagnostics()
        decoder.userInfo[LibrarySnapshot.decodeDiagnosticsKey] = diagnostics
        let data = try Data(contentsOf: url)
        let snapshot = try decoder.decode(LibrarySnapshot.self, from: data)
        return LibraryLoadResult(
            snapshot: snapshot,
            droppedTrackCount: diagnostics.droppedTrackCount,
            droppedPlaylistCount: diagnostics.droppedPlaylistCount,
            defaultedFieldCount: diagnostics.defaultedFieldCount,
            sourceURL: url
        )
    }

    private func migrateLegacySnapshot(_ snapshot: LibrarySnapshot) throws -> LibrarySnapshot {
        let migratedTracks = try snapshot.tracks.map(migrateLegacyTrack(_:))
        return LibrarySnapshot(
            schemaVersion: snapshot.schemaVersion,
            tracks: migratedTracks,
            selectedTrackID: snapshot.selectedTrackID,
            nowPlayingTrackID: snapshot.nowPlayingTrackID,
            selectedPlaybackVariant: snapshot.selectedPlaybackVariant,
            nowPlayingPlaybackVariant: snapshot.nowPlayingPlaybackVariant,
            playlists: snapshot.playlists,
            selectedPlaylistID: snapshot.selectedPlaylistID,
            activeQueue: snapshot.activeQueue,
            selectedPlaybackSource: snapshot.selectedPlaybackSource,
            nowPlayingPlaybackSource: snapshot.nowPlayingPlaybackSource,
            playbackNormalizationSettings: snapshot.playbackNormalizationSettings,
            volume: snapshot.volume,
            isPlaylistsSectionCollapsed: snapshot.isPlaylistsSectionCollapsed,
            isTracksSectionCollapsed: snapshot.isTracksSectionCollapsed,
            isPlaylistOverflowExpanded: snapshot.isPlaylistOverflowExpanded,
            isTracksOverflowExpanded: snapshot.isTracksOverflowExpanded,
            // Explicit pass-through (never the memberwise default): a
            // re-migration must not silently reset the sort preference.
            librarySortOrder: snapshot.librarySortOrder
        )
    }

    private func migrateLegacyTrack(_ track: BackbeatTrack) throws -> BackbeatTrack {
        let sourceURL = try copyFileIfPresent(
            from: track.sourceURL,
            to: managedSourceDirectory
                .appendingPathComponent(track.id.uuidString, isDirectory: true)
                .appendingPathComponent(track.sourceURL.lastPathComponent)
        )
        let activeRenders = try track.activeRenders.reduce(into: [RenderVariant: RenderRecord]()) { partialResult, pair in
            let render = pair.value
            let migratedFileURL = try copyFileIfPresent(
                from: render.fileURL,
                to: renderRootDirectory
                    .appendingPathComponent(folderName(for: render.variant), isDirectory: true)
                    .appendingPathComponent(render.fileURL.lastPathComponent)
            )
            partialResult[pair.key] = RenderRecord(
                id: render.id,
                variant: render.variant,
                fileURL: migratedFileURL,
                boostDB: render.boostDB,
                createdAt: render.createdAt
            )
        }
        return BackbeatTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            status: track.status,
            sourceURL: sourceURL,
            artworkURL: try migrateArtworkURL(track.artworkURL),
            drumMixSettings: track.drumMixSettings,
            loudnessProfile: track.loudnessProfile,
            activeRenders: activeRenders,
            isDurationResolved: track.isDurationResolved,
            // Explicit pass-through (never the memberwise default): a
            // re-migration must not silently drop the import date.
            dateAdded: track.dateAdded
        )
    }

    private func migrateArtworkURL(_ url: URL?) throws -> URL? {
        guard let url else { return nil }
        return try copyFileIfPresent(
            from: url,
            to: artworkDirectory.appendingPathComponent(url.lastPathComponent)
        )
    }

    private func copyFileIfPresent(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return sourceURL
        }
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return destinationURL
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func folderName(for variant: RenderVariant) -> String {
        switch variant {
        case .boostedDrums:
            "boosted_drums"
        case .drums:
            "drums"
        case .drumless:
            "drumless"
        }
    }

    @MainActor
    public func save(store: LibraryStore) throws {
        try save(LibrarySnapshot(store: store))
    }

    @MainActor
    public func loadStoreOrDefault() -> LibraryStore {
        do {
            guard let loaded = try loadReportingRecovery() else {
                return InitialLibrary.makeDevelopmentStore()
            }
            let store = loaded.snapshot.makeStore()
            if loaded.isLossy {
                let backupURL = backUpLibraryFile(at: loaded.sourceURL)
                store.libraryLoadRecoveryMessage = lossyLoadMessage(result: loaded, backupURL: backupURL)
            }
            return store
        } catch LibraryPersistenceError.migrationFailed(let underlying) {
            let store = InitialLibrary.makeDevelopmentStore()
            store.libraryLoadRecoveryMessage = "Your library could not be migrated to its new location (\(underlying.localizedDescription)). The original library file was left untouched; Backbeat will retry on the next launch."
            return store
        } catch {
            let unreadableURL = existingLibraryFileURL
            let backupURL = unreadableURL.flatMap(backUpLibraryFile(at:))
            let store = InitialLibrary.makeDevelopmentStore()
            store.libraryLoadRecoveryMessage = unreadableLibraryMessage(
                error: error,
                unreadableURL: unreadableURL,
                backupURL: backupURL
            )
            return store
        }
    }

    // The file a failed load actually came from, mirroring load order.
    private var existingLibraryFileURL: URL? {
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            return snapshotURL
        }
        if let legacySnapshotURL, FileManager.default.fileExists(atPath: legacySnapshotURL.path) {
            return legacySnapshotURL
        }
        return nil
    }

    // Copies the decoded file aside before the next save can overwrite it, so
    // a decode failure never destroys the user's library data.
    private func backUpLibraryFile(at url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = url
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(formatter.string(from: Date())).json")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: url, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    private func lossyLoadMessage(result: LibraryLoadResult, backupURL: URL?) -> String {
        var parts: [String] = []
        if result.droppedTrackCount == 1 {
            parts.append("1 track could not be read from your library file and was skipped.")
        } else if result.droppedTrackCount > 1 {
            parts.append("\(result.droppedTrackCount) tracks could not be read from your library file and were skipped.")
        }
        if result.droppedPlaylistCount == 1 {
            parts.append("1 playlist could not be read and was skipped.")
        } else if result.droppedPlaylistCount > 1 {
            parts.append("\(result.droppedPlaylistCount) playlists could not be read and were skipped.")
        }
        if result.defaultedFieldCount > 0 {
            parts.append("Some settings could not be read and were reset to defaults.")
        }
        if let backupURL {
            parts.append("The original file was preserved at \(backupURL.path).")
        } else {
            parts.append("The original file is at \(result.sourceURL.path).")
        }
        return parts.joined(separator: " ")
    }

    private func unreadableLibraryMessage(error: Error, unreadableURL: URL?, backupURL: URL?) -> String {
        var message = "Your library file could not be read, so Backbeat started with an empty library. (\(error.localizedDescription))"
        if let backupURL {
            message += " The unreadable file was preserved at \(backupURL.path)."
        } else if let unreadableURL {
            message += " The unreadable file is still at \(unreadableURL.path)."
        }
        return message
    }
}
