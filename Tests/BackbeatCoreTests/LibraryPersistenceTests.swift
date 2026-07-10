import XCTest
@testable import BackbeatCore

@MainActor
final class LibraryPersistenceTests: XCTestCase {
    func testSaveAndLoadLibrarySnapshotRoundTripsTrackRenderAndPreviewState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let renderID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let render = RenderRecord(
            id: renderID,
            variant: .boostedDrums,
            fileURL: root.appendingPathComponent("renders/boosted_drums/sample_song.m4a"),
            boostDB: 5.5,
            createdAt: Date(timeIntervalSince1970: 1_234)
        )
        let drumlessRender = RenderRecord(
            id: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            variant: .drumless,
            fileURL: root.appendingPathComponent("renders/drumless/sample_song.m4a"),
            boostDB: 5.5,
            createdAt: Date(timeIntervalSince1970: 1_235)
        )
        let track = BackbeatTrack(
            id: trackID,
            title: "Sample Song",
            artist: "Prince",
            album: "The very best of",
            duration: 271.666,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/sample_song.m4a"),
            artworkURL: root.appendingPathComponent("artwork/sample_song.jpg"),
            activeRenders: [.boostedDrums: render, .drumless: drumlessRender]
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: trackID,
            nowPlayingTrackID: trackID,
            selectedPlaybackVariant: .drumless,
            nowPlayingPlaybackVariant: .boostedDrums,
            volume: 0.7
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)

        try persistence.save(snapshot)
        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded, snapshot)
    }

    func testSnapshotRoundTripsTwoTrackPracticeRendersMixSettingsAndDrumBoostSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-two-track-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let drumsRender = RenderRecord(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            variant: .drums,
            fileURL: root.appendingPathComponent("renders/drums/sample_song.m4a"),
            boostDB: 0,
            createdAt: Date(timeIntervalSince1970: 1_234)
        )
        let drumlessRender = RenderRecord(
            id: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            variant: .drumless,
            fileURL: root.appendingPathComponent("renders/drumless/sample_song.m4a"),
            boostDB: 0,
            createdAt: Date(timeIntervalSince1970: 1_235)
        )
        let track = BackbeatTrack(
            id: trackID,
            title: "Sample Song",
            artist: "Prince",
            duration: 271.666,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/sample_song.m4a"),
            drumMixSettings: DrumMixSettings(boostDB: 6),
            activeRenders: [.drums: drumsRender, .drumless: drumlessRender]
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: trackID,
            nowPlayingTrackID: trackID,
            selectedPlaybackVariant: .drums,
            nowPlayingPlaybackVariant: .drums,
            selectedPlaybackSource: .drumBoost,
            nowPlayingPlaybackSource: .drumBoost,
            volume: 0.8
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)

        try persistence.save(snapshot)
        let loaded = try XCTUnwrap(persistence.load())
        let loadedTrack = try XCTUnwrap(loaded.tracks.first)

        XCTAssertEqual(loadedTrack.drumMixSettings, DrumMixSettings(boostDB: 6))
        XCTAssertEqual(loadedTrack.activeRender(for: .drums), drumsRender)
        XCTAssertEqual(loadedTrack.activeRender(for: .drumless), drumlessRender)
        XCTAssertEqual(loaded.selectedPlaybackSource, .drumBoost)
        XCTAssertEqual(loaded.nowPlayingPlaybackSource, .drumBoost)
    }

    func testSnapshotRoundTripsLoudnessProfileAndNormalizationSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-loudness-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let profile = TrackLoudnessProfile(
            integratedLUFS: -17.8,
            samplePeakDBFS: -4.2,
            suggestedGainDB: 4.8,
            analyzedAt: Date(timeIntervalSince1970: 4_000),
            analyzerVersion: 1
        )
        let track = BackbeatTrack(
            id: trackID,
            title: "Every Little Thing She Does Is Magic",
            artist: "The Police",
            duration: 260,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/police.m4a"),
            loudnessProfile: profile
        )
        let settings = PlaybackNormalizationSettings(
            isEnabled: false,
            targetLUFS: -12,
            maxBoostDB: 6,
            maxCutDB: -1.5,
            outputCeilingDBFS: -1
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: trackID,
            playbackNormalizationSettings: settings,
            volume: 0.8
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)

        try persistence.save(snapshot)
        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded.playbackNormalizationSettings, settings)
        XCTAssertEqual(loaded.tracks.first?.loudnessProfile, profile)
    }

    func testSnapshotRoundTripsDurationResolvedMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-duration-resolved-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Sample Song",
            duration: 271.666,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/sample_song.m4a"),
            isDurationResolved: true
        )
        let snapshot = LibrarySnapshot(tracks: [track], selectedTrackID: trackID, volume: 0.8)
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)

        try persistence.save(snapshot)
        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded.tracks.first?.isDurationResolved, true)
    }

    func testOlderSnapshotTrackDefaultsDurationUnresolved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-duration-unresolved-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Sample Song",
            duration: 271.666,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/sample_song.m4a"),
            isDurationResolved: true
        )
        let snapshot = LibrarySnapshot(tracks: [track], selectedTrackID: trackID, volume: 0.8)
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        try persistence.save(snapshot)

        // Simulate a legacy snapshot written before the marker existed by
        // stripping the key a pre-F1 save would never have written.
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        )
        var tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        tracks[0].removeValue(forKey: "isDurationResolved")
        json["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: json).write(to: snapshotURL)

        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded.tracks.first?.isDurationResolved, false)
    }

    func testOlderSnapshotDefaultsPlaybackNormalizationSettings() throws {
        let data = """
        {
          "schemaVersion" : 1,
          "tracks" : [],
          "selectedTrackID" : null,
          "selectedPlaybackVariant" : "boostedDrums",
          "nowPlayingPlaybackVariant" : "boostedDrums",
          "boostDB" : 4,
          "previewClip" : {
            "startTime" : 0,
            "duration" : 28,
            "index" : 0
          },
          "volume" : 0.8
        }
        """.data(using: .utf8)!

        let loaded = try JSONDecoder().decode(LibrarySnapshot.self, from: data)

        XCTAssertEqual(loaded.playbackNormalizationSettings, .default)
    }

    func testSnapshotRoundTripsSidebarSectionCollapseState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = LibrarySnapshot(
            tracks: [],
            selectedTrackID: nil,
            volume: 0.8,
            isPlaylistsSectionCollapsed: true,
            isTracksSectionCollapsed: true,
            isPlaylistOverflowExpanded: true,
            isTracksOverflowExpanded: true
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)

        try persistence.save(snapshot)
        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded, snapshot)
        XCTAssertTrue(loaded.makeStore().isPlaylistsSectionCollapsed)
        XCTAssertTrue(loaded.makeStore().isTracksSectionCollapsed)
        XCTAssertTrue(loaded.makeStore().isPlaylistOverflowExpanded)
        XCTAssertTrue(loaded.makeStore().isTracksOverflowExpanded)
    }

    func testOlderSnapshotDefaultsSidebarSectionCollapseState() throws {
        let data = """
        {
          "schemaVersion" : 1,
          "tracks" : [],
          "selectedTrackID" : null,
          "selectedPlaybackVariant" : "boostedDrums",
          "nowPlayingPlaybackVariant" : "boostedDrums",
          "volume" : 0.8
        }
        """.data(using: .utf8)!

        let loaded = try JSONDecoder().decode(LibrarySnapshot.self, from: data)

        XCTAssertFalse(loaded.isPlaylistsSectionCollapsed)
        XCTAssertFalse(loaded.isTracksSectionCollapsed)
        XCTAssertFalse(loaded.isPlaylistOverflowExpanded)
        XCTAssertFalse(loaded.isTracksOverflowExpanded)
    }

    func testLoadReturnsNilWhenSnapshotDoesNotExist() throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-backbeat-\(UUID().uuidString)")
            .appendingPathComponent("library.json")
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)

        XCTAssertNil(try persistence.load())
    }

    func testLoadMigratesLegacyProjectSnapshotIntoApplicationSupportLocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-storage-migration-\(UUID().uuidString)", isDirectory: true)
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
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: legacySnapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let renderID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let legacySourceURL = legacyRoot
            .appendingPathComponent("AppAudioLibrary/sources/source-folder", isDirectory: true)
            .appendingPathComponent("legacy.m4a")
        let legacyRenderURL = legacyRoot
            .appendingPathComponent("renders/boosted_drums", isDirectory: true)
            .appendingPathComponent("legacy_boosted.m4a")
        try FileManager.default.createDirectory(at: legacySourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyRenderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("source-audio".utf8).write(to: legacySourceURL)
        try Data("render-audio".utf8).write(to: legacyRenderURL)

        let render = RenderRecord(
            id: renderID,
            variant: .boostedDrums,
            fileURL: legacyRenderURL,
            boostDB: 4,
            createdAt: Date(timeIntervalSince1970: 1_234)
        )
        let profile = TrackLoudnessProfile(
            integratedLUFS: -17.8,
            samplePeakDBFS: -4.2,
            suggestedGainDB: 4.8,
            analyzedAt: Date(timeIntervalSince1970: 4_000),
            analyzerVersion: 1
        )
        let track = BackbeatTrack(
            id: trackID,
            title: "Legacy",
            duration: 180,
            status: .ready,
            sourceURL: legacySourceURL,
            drumMixSettings: DrumMixSettings(boostDB: 6.5),
            loudnessProfile: profile,
            activeRenders: [.boostedDrums: render]
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: trackID,
            nowPlayingTrackID: trackID,
            selectedPlaybackVariant: .boostedDrums,
            volume: 0.8
        )
        try LibraryPersistence(snapshotURL: legacySnapshotURL).save(snapshot)

        let persistence = LibraryPersistence(
            snapshotURL: snapshotURL,
            legacySnapshotURL: legacySnapshotURL,
            managedSourceDirectory: managedSourceDirectory,
            renderRootDirectory: renderRootDirectory
        )

        let loaded = try XCTUnwrap(persistence.load())
        let migratedTrack = try XCTUnwrap(loaded.tracks.first)
        let migratedRender = try XCTUnwrap(migratedTrack.activeRender(for: .boostedDrums))

        XCTAssertEqual(migratedTrack.id, trackID)
        XCTAssertEqual(migratedTrack.drumMixSettings, DrumMixSettings(boostDB: 6.5))
        XCTAssertEqual(migratedTrack.loudnessProfile, profile)
        XCTAssertEqual(migratedRender.id, renderID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertEqual(migratedTrack.sourceURL.deletingLastPathComponent(), managedSourceDirectory.appendingPathComponent(trackID.uuidString, isDirectory: true))
        XCTAssertEqual(migratedTrack.sourceURL.lastPathComponent, "legacy.m4a")
        XCTAssertEqual(try Data(contentsOf: migratedTrack.sourceURL), Data("source-audio".utf8))
        XCTAssertEqual(migratedRender.fileURL.deletingLastPathComponent(), renderRootDirectory.appendingPathComponent("boosted_drums", isDirectory: true))
        XCTAssertEqual(migratedRender.fileURL.lastPathComponent, "legacy_boosted.m4a")
        XCTAssertEqual(try Data(contentsOf: migratedRender.fileURL), Data("render-audio".utf8))
    }

    func testLoadDefaultsPlaybackVariantForOlderSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-legacy-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let track = BackbeatTrack(
            title: "Legacy Song",
            duration: 180,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/legacy.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: root.appendingPathComponent("renders/boosted_drums/legacy.m4a"),
                    boostDB: 4,
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ]
        )
        let legacySnapshot = LegacyLibrarySnapshot(
            schemaVersion: 1,
            tracks: [track],
            selectedTrackID: track.id,
            nowPlayingTrackID: track.id,
            boostDB: 4,
            previewClip: LegacyPreviewClip(startTime: 30, duration: 28),
            previewCandidates: [],
            volume: 0.8
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacySnapshot).write(to: snapshotURL)

        let loaded = try XCTUnwrap(LibraryPersistence(snapshotURL: snapshotURL).load())

        XCTAssertEqual(loaded.selectedPlaybackVariant, .boostedDrums)
        XCTAssertEqual(loaded.nowPlayingPlaybackVariant, .boostedDrums)
        XCTAssertEqual(loaded.tracks, [track])
    }

    func testLoadStoreOrDefaultFiltersDanglingQueueIDsAndReanchorsCurrentIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let keptTrack = BackbeatTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Kept",
            duration: 200,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/kept.m4a")
        )
        let danglingID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let snapshot = LibrarySnapshot(
            tracks: [keptTrack],
            selectedTrackID: keptTrack.id,
            activeQueue: PlaybackQueue(
                trackIDs: [danglingID, keptTrack.id],
                currentIndex: 1,
                preferredSource: .drumless
            ),
            volume: 0.8
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        try persistence.save(snapshot)

        let store = persistence.loadStoreOrDefault()

        XCTAssertEqual(store.activeQueue?.trackIDs, [keptTrack.id])
        XCTAssertEqual(
            store.activeQueue?.currentIndex,
            0,
            "currentIndex must re-anchor to the surviving current track"
        )
        XCTAssertEqual(store.activeQueue?.preferredSource, .drumless)
    }

    func testMakeStoreDropsQueueWhenNoQueuedTrackResolves() throws {
        let snapshot = LibrarySnapshot(
            tracks: [],
            selectedTrackID: nil,
            activeQueue: PlaybackQueue(
                trackIDs: [
                    UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
                ],
                currentIndex: 0,
                preferredSource: .drumBoost
            ),
            volume: 0.8
        )

        let store = snapshot.makeStore()

        XCTAssertNil(store.activeQueue)
    }

    func testSnapshotFromStoreRestoresStoreState() throws {
        let store = LibraryStore(
            tracks: [
                BackbeatTrack(
                    title: "Paper Crown",
                    duration: 311,
                    status: .imported,
                    sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
                )
            ],
            selectedTrackID: nil,
            nowPlayingTrackID: nil,
            selectedPlaybackVariant: .boostedDrums,
            nowPlayingPlaybackVariant: .drumless,
            volume: 0.55
        )
        store.selectedTrackID = store.tracks.first?.id

        let restored = LibrarySnapshot(store: store).makeStore()

        XCTAssertEqual(restored.tracks, store.tracks)
        XCTAssertEqual(restored.selectedTrackID, store.selectedTrackID)
        XCTAssertEqual(restored.selectedPlaybackVariant, store.selectedPlaybackVariant)
        XCTAssertEqual(restored.nowPlayingPlaybackVariant, store.nowPlayingPlaybackVariant)
        XCTAssertEqual(restored.volume, 0.55)
    }

    func testSnapshotFromStoreDoesNotPersistPracticeState() throws {
        let track = BackbeatTrack(
            title: "Paper Crown",
            duration: 311,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )
        let store = LibraryStore(tracks: [track], selectedTrackID: track.id)
        store.setPracticeSpeed(0.75)
        store.setPracticeSectionLoop(start: 16, end: 24, duration: track.duration)

        let snapshot = LibrarySnapshot(store: store)
        let data = try JSONEncoder.backbeatTestEncoder.encode(snapshot)
        let json = String(decoding: data, as: UTF8.self)
        let restored = snapshot.makeStore()

        XCTAssertFalse(json.contains("practiceSpeed"))
        XCTAssertFalse(json.contains("practiceLoopMode"))
        XCTAssertFalse(json.contains("practiceLoopRange"))
        XCTAssertEqual(restored.practiceSpeed, 1)
        XCTAssertEqual(restored.practiceLoopMode, .off)
        XCTAssertNil(restored.practiceLoopRange)
        XCTAssertFalse(restored.isPracticeZoomVisible)
    }

    func testSnapshotRoundTripsPlaylistsQueueAndPlaybackSources() throws {
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let playlistID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Paper Crown",
            duration: 311,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )
        let playlist = BackbeatPlaylist(
            id: playlistID,
            name: "Practice",
            trackIDs: [trackID],
            defaultPlaybackSource: .drumless,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let queue = PlaybackQueue(
            playlistID: playlistID,
            trackIDs: [trackID],
            currentIndex: 0,
            preferredSource: .drumless
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: trackID,
            nowPlayingTrackID: trackID,
            selectedPlaybackVariant: .boostedDrums,
            nowPlayingPlaybackVariant: .boostedDrums,
            playlists: [playlist],
            selectedPlaylistID: playlistID,
            activeQueue: queue,
            selectedPlaybackSource: .original,
            nowPlayingPlaybackSource: .drumless,
            volume: 0.8
        )

        let data = try JSONEncoder.backbeatTestEncoder.encode(snapshot)
        let decoded = try JSONDecoder.backbeatTestDecoder.decode(LibrarySnapshot.self, from: data)

        XCTAssertEqual(decoded.playlists, [playlist])
        XCTAssertEqual(decoded.selectedPlaylistID, playlistID)
        XCTAssertEqual(decoded.activeQueue, queue)
        XCTAssertEqual(decoded.selectedPlaybackSource, .original)
        XCTAssertEqual(decoded.nowPlayingPlaybackSource, .drumless)
    }

    func testOlderSnapshotDefaultsPlaylistQueueAndPlaybackSources() throws {
        let track = BackbeatTrack(
            title: "Legacy",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/legacy.m4a")
        )
        let legacy = LegacyPlaylistlessSnapshot(
            schemaVersion: 1,
            tracks: [track],
            selectedTrackID: track.id,
            nowPlayingTrackID: track.id,
            selectedPlaybackVariant: .drumless,
            boostDB: 4,
            previewClip: LegacyPreviewClip(startTime: 30, duration: 28),
            previewCandidates: [],
            volume: 0.8
        )

        let data = try JSONEncoder.backbeatTestEncoder.encode(legacy)
        let loaded = try JSONDecoder.backbeatTestDecoder.decode(LibrarySnapshot.self, from: data)

        XCTAssertEqual(loaded.playlists, [])
        XCTAssertNil(loaded.selectedPlaylistID)
        XCTAssertNil(loaded.activeQueue)
        XCTAssertEqual(loaded.selectedPlaybackSource, .drumless)
        XCTAssertEqual(loaded.nowPlayingPlaybackSource, .drumless)
    }

    func testSnapshotRoundTripsLibrarySortOrderAndDateAdded() throws {
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let track = BackbeatTrack(
            title: "Dated",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/dated.m4a"),
            dateAdded: importedAt
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: track.id,
            volume: 0.8,
            librarySortOrder: LibrarySortOrder(field: .artist, ascending: false)
        )

        let data = try JSONEncoder.backbeatTestEncoder.encode(snapshot)
        let decoded = try JSONDecoder.backbeatTestDecoder.decode(LibrarySnapshot.self, from: data)

        XCTAssertEqual(decoded.librarySortOrder, LibrarySortOrder(field: .artist, ascending: false))
        XCTAssertEqual(decoded.tracks.first?.dateAdded, importedAt)
        XCTAssertEqual(decoded.makeStore().librarySortOrder, LibrarySortOrder(field: .artist, ascending: false))
    }

    func testSnapshotWithoutSortOrderOrDateAddedKeysDefaultsSilently() throws {
        // A pre-D-102 library file has neither key: the sort preference must
        // default and every track must decode dateAdded == nil, with ZERO
        // lossy-load diagnostics (missing keys are forward-compat, not damage).
        let track = BackbeatTrack(
            title: "Legacy",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/legacy.m4a")
        )
        let snapshot = LibrarySnapshot(tracks: [track], selectedTrackID: track.id, volume: 0.8)
        let data = try JSONEncoder.backbeatTestEncoder.encode(snapshot)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "librarySortOrder")
        var tracksJSON = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        tracksJSON[0].removeValue(forKey: "dateAdded")
        json["tracks"] = tracksJSON
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let diagnostics = LibraryDecodeDiagnostics()
        let decoder = JSONDecoder.backbeatTestDecoder
        decoder.userInfo[LibrarySnapshot.decodeDiagnosticsKey] = diagnostics
        let decoded = try decoder.decode(LibrarySnapshot.self, from: strippedData)

        XCTAssertEqual(decoded.librarySortOrder, .default)
        XCTAssertNil(decoded.tracks.first?.dateAdded)
        XCTAssertEqual(diagnostics.defaultedFieldCount, 0)
        XCTAssertEqual(diagnostics.droppedTrackCount, 0)
    }

    func testUnknownSortFieldValueDegradesWithoutDiagnostics() throws {
        // A future build may persist a sort field this build doesn't know.
        // The preference must degrade member-wise (unknown field → default
        // field, the still-valid direction survives) WITHOUT tripping the
        // lossy-load diagnostics — a sort pref must never raise the
        // corruption banner or trigger a .corrupt backup.
        let snapshot = LibrarySnapshot(tracks: [], selectedTrackID: nil, volume: 0.8)
        let data = try JSONEncoder.backbeatTestEncoder.encode(snapshot)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["librarySortOrder"] = ["field": "albumArtist", "ascending": false]
        let futureData = try JSONSerialization.data(withJSONObject: json)

        let diagnostics = LibraryDecodeDiagnostics()
        let decoder = JSONDecoder.backbeatTestDecoder
        decoder.userInfo[LibrarySnapshot.decodeDiagnosticsKey] = diagnostics
        let decoded = try decoder.decode(LibrarySnapshot.self, from: futureData)

        XCTAssertEqual(decoded.librarySortOrder, LibrarySortOrder(field: .dateAdded, ascending: false))
        XCTAssertEqual(diagnostics.defaultedFieldCount, 0)
    }

    func testLoadStoreOrDefaultPreservesUnreadableSnapshotAndStartsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: snapshotURL)

        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        let store = persistence.loadStoreOrDefault()

        XCTAssertTrue(store.tracks.isEmpty)
        XCTAssertNotNil(store.libraryLoadRecoveryMessage)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(backups.first)),
            Data("not json at all".utf8)
        )
    }

    func testLoadStoreOrDefaultDropsMalformedTrackAndKeepsRest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let keptTrack = BackbeatTrack(
            title: "Kept",
            duration: 200,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/kept.m4a")
        )
        let snapshot = LibrarySnapshot(
            tracks: [keptTrack],
            selectedTrackID: keptTrack.id,
            volume: 0.8
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        try persistence.save(snapshot)

        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        )
        var tracks = try XCTUnwrap(json["tracks"] as? [Any])
        tracks.append(["bogus": true])
        json["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: json).write(to: snapshotURL)

        let store = persistence.loadStoreOrDefault()

        XCTAssertEqual(store.tracks.map(\.id), [keptTrack.id])
        XCTAssertNotNil(store.libraryLoadRecoveryMessage)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        XCTAssertEqual(backups.count, 1)
    }

    func testSnapshotWriterSkipsStaleGenerations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let track = BackbeatTrack(
            title: "Gen",
            duration: 100,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/gen.m4a")
        )
        let older = LibrarySnapshot(tracks: [track], selectedTrackID: track.id, volume: 0.5)
        let newer = LibrarySnapshot(tracks: [track], selectedTrackID: track.id, volume: 0.9)

        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        let writer = LibrarySnapshotWriter(persistence: persistence)
        let olderGeneration = writer.nextGeneration()
        let newerGeneration = writer.nextGeneration()

        try writer.write(newer, generation: newerGeneration)
        try writer.write(older, generation: olderGeneration)

        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertEqual(loaded.volume, 0.9)
    }

    func testLoadStoreOrDefaultBacksUpOriginalLegacyFileWhenTracksAreDropped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        let legacyURL = root.appendingPathComponent("legacy-library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let keptTrack = BackbeatTrack(
            title: "Kept",
            duration: 200,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/kept.m4a")
        )
        let snapshot = LibrarySnapshot(
            tracks: [keptTrack],
            selectedTrackID: keptTrack.id,
            volume: 0.8
        )
        try LibraryPersistence(snapshotURL: legacyURL).save(snapshot)

        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as? [String: Any]
        )
        var tracks = try XCTUnwrap(json["tracks"] as? [Any])
        tracks.append(["bogus": true])
        json["tracks"] = tracks
        let originalLegacyData = try JSONSerialization.data(withJSONObject: json)
        try originalLegacyData.write(to: legacyURL)

        let persistence = LibraryPersistence(snapshotURL: snapshotURL, legacySnapshotURL: legacyURL)
        let store = persistence.loadStoreOrDefault()

        XCTAssertEqual(store.tracks.map(\.id), [keptTrack.id])
        XCTAssertNotNil(store.libraryLoadRecoveryMessage)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("legacy-library.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(backups.first)),
            originalLegacyData,
            "the backup must preserve the original legacy bytes, not the pruned migrated snapshot"
        )
    }

    func testLoadStoreOrDefaultReportsDefaultedSettingsWithoutLosingTracks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let track = BackbeatTrack(
            title: "Settings",
            duration: 150,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/settings.m4a")
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: track.id,
            volume: 0.7
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        try persistence.save(snapshot)

        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        )
        json["volume"] = "not-a-number"
        try JSONSerialization.data(withJSONObject: json).write(to: snapshotURL)

        let store = persistence.loadStoreOrDefault()

        XCTAssertEqual(store.tracks.map(\.id), [track.id])
        XCTAssertEqual(store.volume, 0.8, "malformed volume falls back to the default")
        XCTAssertNotNil(store.libraryLoadRecoveryMessage)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        XCTAssertEqual(backups.count, 1)
    }

    func testLoadStoreOrDefaultReportsMigrationFailureWithoutCorruptBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        // A regular file where the snapshot's parent directory must go makes
        // the post-migration save fail while the legacy file stays readable.
        let blockerURL = root.appendingPathComponent("blocked")
        let snapshotURL = blockerURL.appendingPathComponent("library.json")
        let legacyURL = root.appendingPathComponent("legacy-library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: blockerURL)

        let track = BackbeatTrack(
            title: "Legacy",
            duration: 120,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/legacy.m4a")
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: track.id,
            volume: 0.8
        )
        try LibraryPersistence(snapshotURL: legacyURL).save(snapshot)
        let originalLegacyData = try Data(contentsOf: legacyURL)

        let persistence = LibraryPersistence(snapshotURL: snapshotURL, legacySnapshotURL: legacyURL)
        let store = persistence.loadStoreOrDefault()

        XCTAssertTrue(store.tracks.isEmpty)
        let message = try XCTUnwrap(store.libraryLoadRecoveryMessage)
        XCTAssertTrue(message.contains("migrated"), "migration failures must not be reported as unreadable files")
        XCTAssertFalse(message.contains("could not be read"))
        XCTAssertEqual(try Data(contentsOf: legacyURL), originalLegacyData, "the legacy file must be untouched")
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        XCTAssertTrue(backups.isEmpty, "a healthy legacy file must not be backed up under a corrupt name")
    }

    func testSnapshotSavedMidPreviewLoadsCleanlyWithTrackReadyToRender() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let track = BackbeatTrack(
            title: "Mid Preview",
            duration: 180,
            status: .imported,
            sourceURL: root.appendingPathComponent("sources/mid.m4a")
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: track.id,
            volume: 0.8
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        try persistence.save(snapshot)

        // Rewrite the file the way a pre-preview-removal build would have
        // saved it: the retired status value plus the retired snapshot keys.
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        )
        var tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        tracks[0]["status"] = "choosingDrumLevel"
        json["tracks"] = tracks
        json["boostDB"] = 5.5
        json["previewClip"] = ["startTime": 30, "duration": 28, "index": 0]
        json["previewCandidates"] = [["startTime": 30, "duration": 28, "index": 0]]
        try JSONSerialization.data(withJSONObject: json).write(to: snapshotURL)

        let store = persistence.loadStoreOrDefault()

        XCTAssertEqual(store.tracks.map(\.id), [track.id], "a mid-preview track must never be dropped")
        XCTAssertEqual(
            store.tracks.first?.status, .imported,
            "the retired choosingDrumLevel status aliases to imported so the launch scan re-renders it"
        )
        XCTAssertNil(store.libraryLoadRecoveryMessage, "legacy preview keys are ignored, not recovery-worthy")
    }

    func testLoadStoreOrDefaultTreatsNewerSchemaVersionAsUnreadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let track = BackbeatTrack(
            title: "Future",
            duration: 180,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/future.m4a")
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: track.id,
            volume: 0.8
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        try persistence.save(snapshot)

        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        )
        json["schemaVersion"] = LibrarySnapshot.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: snapshotURL)

        let store = persistence.loadStoreOrDefault()

        XCTAssertTrue(store.tracks.isEmpty)
        XCTAssertNotNil(store.libraryLoadRecoveryMessage)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        XCTAssertEqual(backups.count, 1)
    }

    func testLoadStoreOrDefaultDropsMalformedPlaylistAndKeepsRest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let track = BackbeatTrack(
            title: "Kept",
            duration: 200,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/kept.m4a")
        )
        let playlist = BackbeatPlaylist(
            name: "Practice",
            trackIDs: [track.id],
            defaultPlaybackSource: .drumless,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let snapshot = LibrarySnapshot(
            tracks: [track],
            selectedTrackID: track.id,
            playlists: [playlist],
            volume: 0.8
        )
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        try persistence.save(snapshot)

        // Inject a bogus playlist element. Before F6 one malformed playlist threw
        // the whole decode, wiping the healthy library.
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        )
        var playlists = try XCTUnwrap(json["playlists"] as? [Any])
        playlists.append(["bogus": true])
        json["playlists"] = playlists
        try JSONSerialization.data(withJSONObject: json).write(to: snapshotURL)

        let store = persistence.loadStoreOrDefault()

        XCTAssertEqual(store.tracks.map(\.id), [track.id], "the track must survive a malformed playlist")
        XCTAssertEqual(store.playlists.map(\.id), [playlist.id], "the healthy playlist must survive; only the bogus one is skipped")
        XCTAssertNotNil(store.libraryLoadRecoveryMessage)
    }

    func testLoadStoreOrDefaultToleratesMalformedScalarWithoutWipingLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-persistence-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let track = BackbeatTrack(
            title: "Scalar",
            duration: 150,
            status: .ready,
            sourceURL: root.appendingPathComponent("sources/scalar.m4a")
        )
        let snapshot = LibrarySnapshot(tracks: [track], selectedTrackID: track.id, volume: 0.7)
        let persistence = LibraryPersistence(snapshotURL: snapshotURL)
        try persistence.save(snapshot)

        // A present-but-type-mismatched Bool scalar. Before F6 this threw the
        // whole init(from:) and reset to an empty library over one bad field;
        // now it defaults, is recorded, and the tracks survive.
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        )
        json["isPlaylistsSectionCollapsed"] = "not-a-bool"
        try JSONSerialization.data(withJSONObject: json).write(to: snapshotURL)

        let store = persistence.loadStoreOrDefault()

        XCTAssertEqual(store.tracks.map(\.id), [track.id], "a malformed scalar must not wipe the library")
        XCTAssertFalse(store.isPlaylistsSectionCollapsed, "the malformed Bool falls back to its default")
        XCTAssertNotNil(store.libraryLoadRecoveryMessage)
    }
}

// Retired schema keys: legacy fixtures still carry preview state so the
// decoder's ignore-unknown-keys behavior stays covered.
private struct LegacyPreviewClip: Encodable {
    let startTime: Double
    let duration: Double
    var index: Int = 0
}

private struct LegacyLibrarySnapshot: Encodable {
    let schemaVersion: Int
    let tracks: [BackbeatTrack]
    let selectedTrackID: BackbeatTrack.ID?
    let nowPlayingTrackID: BackbeatTrack.ID?
    let boostDB: Double
    let previewClip: LegacyPreviewClip
    let previewCandidates: [LegacyPreviewClip]
    let volume: Double
}

private struct LegacyPlaylistlessSnapshot: Encodable {
    let schemaVersion: Int
    let tracks: [BackbeatTrack]
    let selectedTrackID: BackbeatTrack.ID?
    let nowPlayingTrackID: BackbeatTrack.ID?
    let selectedPlaybackVariant: RenderVariant
    let boostDB: Double
    let previewClip: LegacyPreviewClip
    let previewCandidates: [LegacyPreviewClip]
    let volume: Double
}

private extension JSONEncoder {
    static var backbeatTestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var backbeatTestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
