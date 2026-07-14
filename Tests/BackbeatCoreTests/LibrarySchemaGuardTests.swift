import XCTest
@testable import BackbeatCore

/// CLR-004: LibraryPersistence.swift requires five synchronized edits to add
/// a durable field (decl+CodingKeys, init(store:), makeStore, and the two
/// migration functions). These tests pin every durable field so a newly
/// added one fails loudly here — and in the migration structural pass-through
/// test — until its migration decision is made, instead of silently
/// resetting on the next re-migration.
@MainActor
final class LibrarySchemaGuardTests: XCTestCase {
    func testExhaustiveSnapshotRoundTripPreservesEveryDurableField() throws {
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let playlistID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let root = URL(fileURLWithPath: "/tmp/backbeat-schema-guard")
        let snapshot = makeExhaustiveSnapshot(trackID: trackID, playlistID: playlistID, root: root)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LibrarySnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)

        // JSON key-set guard: a newly added durable field fails these until
        // the fixture above (and its migration decision) is updated — that
        // is the point.
        let topLevel = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expectedTopLevelKeys: Set<String> = [
            "schemaVersion", "tracks", "selectedTrackID", "nowPlayingTrackID",
            "selectedPlaybackVariant", "nowPlayingPlaybackVariant", "playlists",
            "selectedPlaylistID", "activeQueue", "selectedPlaybackSource",
            "nowPlayingPlaybackSource", "volume", "playbackNormalizationSettings",
            "isPlaylistsSectionCollapsed", "isTracksSectionCollapsed",
            "isPlaylistOverflowExpanded", "isTracksOverflowExpanded", "librarySortOrder"
        ]
        XCTAssertEqual(Set(topLevel.keys), expectedTopLevelKeys)

        let tracksJSON = try XCTUnwrap(topLevel["tracks"] as? [[String: Any]])
        let trackKeys = try XCTUnwrap(tracksJSON.first).keys
        let expectedTrackKeys: Set<String> = [
            "id", "title", "artist", "album", "duration", "status", "sourceURL",
            "artworkURL", "drumMixSettings", "loudnessProfile", "activeRenders",
            "isDurationResolved", "dateAdded"
        ]
        XCTAssertEqual(Set(trackKeys), expectedTrackKeys)
    }

    func testMigrationPassesEveryDurableFieldThroughStructurally() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-schema-guard-migration-\(UUID().uuidString)", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("legacy-project", isDirectory: true)
        let applicationSupportRoot = root.appendingPathComponent("Application Support/Backbeat", isDirectory: true)
        let managedSourceDirectory = applicationSupportRoot
            .appendingPathComponent("AppAudioLibrary", isDirectory: true)
            .appendingPathComponent("sources", isDirectory: true)
        let renderRootDirectory = applicationSupportRoot.appendingPathComponent("renders", isDirectory: true)
        let snapshotURL = applicationSupportRoot
            .appendingPathComponent("AppAudioLibrary", isDirectory: true)
            .appendingPathComponent("library.json")
        let legacySnapshotURL = legacyRoot
            .appendingPathComponent("AppAudioLibrary", isDirectory: true)
            .appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: legacySnapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Source/render/artwork files are deliberately absent: copyFileIfPresent
        // passes every URL through unchanged, isolating the migration's
        // structural field pass-through (CLR-004) from its file-copy behavior.
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let playlistID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let snapshot = makeExhaustiveSnapshot(trackID: trackID, playlistID: playlistID, root: legacyRoot)
        try LibraryPersistence(snapshotURL: legacySnapshotURL).save(snapshot)

        let persistence = LibraryPersistence(
            snapshotURL: snapshotURL,
            legacySnapshotURL: legacySnapshotURL,
            managedSourceDirectory: managedSourceDirectory,
            renderRootDirectory: renderRootDirectory
        )

        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded, snapshot)
    }

    // MARK: - Fixture

    private func makeExhaustiveTrack(id: UUID, root: URL) -> BackbeatTrack {
        BackbeatTrack(
            id: id,
            title: "Every Field Set",
            artist: "Artist Name",
            album: "Album Name",
            duration: 245.5,
            status: .renderFailed,
            sourceURL: root.appendingPathComponent("sources/source.m4a"),
            artworkURL: root.appendingPathComponent("artwork/artwork.jpg"),
            drumMixSettings: DrumMixSettings(boostDB: 6.5),
            loudnessProfile: TrackLoudnessProfile(
                integratedLUFS: -16.2,
                samplePeakDBFS: -3.1,
                suggestedGainDB: 3.4,
                analyzedAt: Date(timeIntervalSince1970: 1_700_000_000),
                analyzerVersion: 1
            ),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!,
                    variant: .boostedDrums,
                    fileURL: root.appendingPathComponent("renders/boosted_drums.m4a"),
                    boostDB: 5,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                ),
                .drums: RenderRecord(
                    id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!,
                    variant: .drums,
                    fileURL: root.appendingPathComponent("renders/drums.m4a"),
                    boostDB: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_002)
                ),
                .drumless: RenderRecord(
                    id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000003")!,
                    variant: .drumless,
                    fileURL: root.appendingPathComponent("renders/drumless.m4a"),
                    boostDB: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_003)
                )
            ],
            isDurationResolved: true,
            dateAdded: Date(timeIntervalSince1970: 1_699_999_999)
        )
    }

    private func makeExhaustiveSnapshot(trackID: UUID, playlistID: UUID, root: URL) -> LibrarySnapshot {
        let track = makeExhaustiveTrack(id: trackID, root: root)
        let playlist = BackbeatPlaylist(
            id: playlistID,
            name: "Practice",
            trackIDs: [trackID],
            defaultPlaybackSource: .drumless,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_100)
        )
        let queue = PlaybackQueue(
            playlistID: playlistID,
            trackIDs: [trackID],
            currentIndex: 0,
            preferredSource: .drumless,
            repeatMode: .all,
            isShuffleEnabled: true
        )
        let normalizationSettings = PlaybackNormalizationSettings(
            isEnabled: false,
            targetLUFS: -14,
            maxBoostDB: 7,
            maxCutDB: -2.5,
            outputCeilingDBFS: -0.5
        )
        return LibrarySnapshot(
            tracks: [track],
            selectedTrackID: trackID,
            nowPlayingTrackID: trackID,
            selectedPlaybackVariant: .drums,
            nowPlayingPlaybackVariant: .drumless,
            playlists: [playlist],
            selectedPlaylistID: playlistID,
            activeQueue: queue,
            selectedPlaybackSource: .drums,
            nowPlayingPlaybackSource: .drumless,
            playbackNormalizationSettings: normalizationSettings,
            volume: 0.37,
            isPlaylistsSectionCollapsed: true,
            isTracksSectionCollapsed: true,
            isPlaylistOverflowExpanded: true,
            isTracksOverflowExpanded: true,
            librarySortOrder: LibrarySortOrder(field: .artist, ascending: false)
        )
    }
}
