import Observation
import XCTest
@testable import BackbeatCore

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testPracticeStateDefaultsToNeutral() {
        let store = LibraryStore()

        XCTAssertEqual(store.practiceSpeed, 1)
        XCTAssertEqual(store.practiceLoopMode, .off)
        XCTAssertNil(store.practiceLoopRange)
        XCTAssertFalse(store.isPracticeZoomVisible)
    }

    func testPracticeSpeedClampsToPracticeRange() {
        let store = LibraryStore()

        store.setPracticeSpeed(0.2)
        XCTAssertEqual(store.practiceSpeed, 0.5)

        store.setPracticeSpeed(1.25)
        XCTAssertEqual(store.practiceSpeed, 1.25)

        store.setPracticeSpeed(2.5)
        XCTAssertEqual(store.practiceSpeed, 1.5)

        store.setPracticeSpeed(.nan)
        XCTAssertEqual(store.practiceSpeed, 1)
    }

    func testPracticeSectionLoopClampsOrdersAndKeepsMinimumRange() throws {
        let store = LibraryStore()

        store.setPracticeSectionLoop(start: 20, end: -5, duration: 30)
        var range = try XCTUnwrap(store.practiceLoopRange)
        XCTAssertEqual(store.practiceLoopMode, .section)
        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.end, 20)
        XCTAssertTrue(store.isPracticeZoomVisible)

        store.setPracticeSectionLoop(start: 29.99, end: 29.991, duration: 30)
        range = try XCTUnwrap(store.practiceLoopRange)
        XCTAssertEqual(range.start, 29.95, accuracy: 0.0001)
        XCTAssertEqual(range.end, 30, accuracy: 0.0001)
    }

    func testClearingPracticeLoopRemovesMarkersAndZoomButKeepsSpeed() {
        let store = LibraryStore()
        store.setPracticeSpeed(0.75)
        store.setPracticeSectionLoop(start: 8, end: 12, duration: 30)

        store.clearPracticeLoop()

        XCTAssertEqual(store.practiceSpeed, 0.75)
        XCTAssertEqual(store.practiceLoopMode, .off)
        XCTAssertNil(store.practiceLoopRange)
        XCTAssertFalse(store.isPracticeZoomVisible)
    }

    func testStoppingPlaybackResetsPracticeState() {
        let store = LibraryStore()
        store.setPracticeSpeed(0.75)
        store.setPracticeSectionLoop(start: 8, end: 12, duration: 30)

        store.stopPlayback(duration: 30)

        XCTAssertEqual(store.practiceSpeed, 1)
        XCTAssertEqual(store.practiceLoopMode, .off)
        XCTAssertNil(store.practiceLoopRange)
        XCTAssertFalse(store.isPracticeZoomVisible)
    }

    func testImportCreatesImportedTrackFromFullSongMetadata() {
        let store = LibraryStore()
        let sourceURL = URL(fileURLWithPath: "/tmp/sample-song.m4a")
        let artworkURL = URL(fileURLWithPath: "/tmp/backbeat-artwork/sample-song.jpg")
        let metadata = AudioMetadata(
            fileName: "sample-song",
            title: "Sample Song",
            artist: "Prince",
            album: "The very best of",
            duration: 271.666,
            sampleRate: 44_100,
            channelCount: 2
        )

        let track = store.importTrack(from: metadata, sourceURL: sourceURL, artworkURL: artworkURL)

        XCTAssertEqual(track.title, "Sample Song")
        XCTAssertEqual(track.artist, "Prince")
        XCTAssertEqual(track.album, "The very best of")
        XCTAssertEqual(track.artworkURL, artworkURL)
        XCTAssertEqual(track.duration, 271.666)
        XCTAssertEqual(track.status, .imported)
        XCTAssertEqual(track.sourceURL, sourceURL)
        XCTAssertEqual(store.selectedTrackID, track.id)
        XCTAssertTrue(track.isDurationResolved, "new imports already read precise duration")
        XCTAssertNotNil(track.dateAdded, "new imports stamp their import date (D-102)")
    }

    func testImportStampsInjectedDateAdded() {
        let store = LibraryStore()
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = AudioMetadata(fileName: "Stamped", duration: 200, sampleRate: 44_100, channelCount: 2)

        let track = store.importTrack(
            from: metadata,
            sourceURL: URL(fileURLWithPath: "/tmp/stamped.m4a"),
            dateAdded: importedAt
        )

        XCTAssertEqual(track.dateAdded, importedAt)
    }

    func testSetLibrarySortOrderGuardsUnchangedWrites() {
        let store = LibraryStore()
        XCTAssertEqual(store.librarySortOrder, .default)

        let order = LibrarySortOrder(field: .artist, ascending: false)
        store.setLibrarySortOrder(order)
        XCTAssertEqual(store.librarySortOrder, order)

        // Setting the same value again must be a no-op write (F14 guard);
        // observable behavior: the value is unchanged.
        store.setLibrarySortOrder(order)
        XCTAssertEqual(store.librarySortOrder, order)
    }

    func testImportFallsBackToFileNameWhenTitleMetadataIsMissing() {
        let store = LibraryStore()
        let metadata = AudioMetadata(
            fileName: "Paper Crown",
            title: nil,
            artist: nil,
            album: nil,
            duration: 311,
            sampleRate: 44_100,
            channelCount: 2
        )

        let track = store.importTrack(
            from: metadata,
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )

        XCTAssertEqual(track.title, "Paper Crown")
        XCTAssertNil(track.artist)
        XCTAssertNil(track.album)
        XCTAssertNil(track.artworkURL)
    }

    func testDeleteTrackRemovesSourceArtworkAndActiveRenderFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-delete-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let sourceURL = root.appendingPathComponent("sources/paper.m4a")
        let artworkURL = root.appendingPathComponent("artwork/paper.jpg")
        let boostedURL = root.appendingPathComponent("renders/boosted_drums/paper_boosted.m4a")
        let drumsURL = root.appendingPathComponent("renders/drums/paper_drums.m4a")
        let drumlessURL = root.appendingPathComponent("renders/drumless/paper_drumless.m4a")
        for url in [sourceURL, artworkURL, boostedURL, drumsURL, drumlessURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Paper Crown",
            duration: 311,
            status: .ready,
            sourceURL: sourceURL,
            artworkURL: artworkURL,
            activeRenders: [
                .boostedDrums: RenderRecord(variant: .boostedDrums, fileURL: boostedURL, boostDB: 4),
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 4)
            ]
        )
        let store = LibraryStore(
            tracks: [track],
            selectedTrackID: trackID,
            nowPlayingTrackID: trackID,
            isPlaybackPlaying: true
        )

        try store.deleteTrack(id: trackID)

        XCTAssertTrue(store.tracks.isEmpty)
        XCTAssertNil(store.selectedTrackID)
        XCTAssertNil(store.nowPlayingTrackID)
        XCTAssertFalse(store.isPlaybackPlaying)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: boostedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drumsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drumlessURL.path))
    }

    func testDeleteTrackSelectsRemainingTrackAndIgnoresMissingFiles() throws {
        let deletedTrack = BackbeatTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Missing",
            duration: 100,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/backbeat-missing-source.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/backbeat-missing-render.m4a"),
                    boostDB: 4
                )
            ]
        )
        let remainingTrack = BackbeatTrack(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            title: "Remaining",
            duration: 120,
            status: .imported,
            sourceURL: URL(fileURLWithPath: "/tmp/remaining.m4a")
        )
        let store = LibraryStore(
            tracks: [deletedTrack, remainingTrack],
            selectedTrackID: deletedTrack.id
        )

        try store.deleteTrack(id: deletedTrack.id)

        XCTAssertEqual(store.tracks, [remainingTrack])
        XCTAssertEqual(store.selectedTrackID, remainingTrack.id)
    }

    func testDeleteTrackRemovesTrackFromLibraryEvenWhenFileDeletionFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-delete-locked-\(UUID().uuidString)", isDirectory: true)
        let lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
        let sourceURL = lockedDirectory.appendingPathComponent("paper.m4a")
        let drumsURL = root.appendingPathComponent("renders/drums/paper_drums.m4a")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path)
            try? FileManager.default.removeItem(at: root)
        }
        for url in [sourceURL, drumsURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDirectory.path)

        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Paper Crown",
            duration: 311,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(
            tracks: [track],
            selectedTrackID: trackID,
            nowPlayingTrackID: trackID,
            isPlaybackPlaying: true
        )

        XCTAssertThrowsError(try store.deleteTrack(id: trackID))

        XCTAssertTrue(store.tracks.isEmpty)
        XCTAssertNil(store.selectedTrackID)
        XCTAssertNil(store.nowPlayingTrackID)
        XCTAssertFalse(store.isPlaybackPlaying)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceURL.path),
            "the undeletable source file stays behind"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: drumsURL.path),
            "deletable files must still be removed after an earlier failure"
        )
    }

    func testNowPlayingTrackIsNilWhenNothingWasStarted() throws {
        let renderedTrack = BackbeatTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Rendered",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/rendered.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/rendered.m4a"),
                    boostDB: 4
                )
            ]
        )
        let playingTrack = BackbeatTrack(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            title: "Playing",
            duration: 200,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/backbeat-missing-playing.m4a")
        )
        let store = LibraryStore(tracks: [renderedTrack, playingTrack])

        XCTAssertNil(store.nowPlayingTrack)

        store.nowPlayingTrackID = playingTrack.id
        try store.deleteTrack(id: playingTrack.id)

        XCTAssertNil(store.nowPlayingTrackID)
        XCTAssertNil(
            store.nowPlayingTrack,
            "deleting the now-playing track must not resurrect another rendered track"
        )
    }

    func testSelectingRenderedTrackForPlaybackUpdatesSelectionAndNowPlaying() {
        let firstTrackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondTrackID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let firstTrack = BackbeatTrack(
            id: firstTrackID,
            title: "First",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/first.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/first.m4a"),
                    boostDB: 4
                )
            ]
        )
        let secondTrack = BackbeatTrack(
            id: secondTrackID,
            title: "Second",
            duration: 220,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/second.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/second.m4a"),
                    boostDB: 4
                )
            ]
        )
        let store = LibraryStore(
            tracks: [firstTrack, secondTrack],
            selectedTrackID: secondTrackID,
            nowPlayingTrackID: secondTrackID
        )

        store.selectTrackForPlayback(firstTrackID)

        XCTAssertEqual(store.selectedTrackID, firstTrackID)
        XCTAssertEqual(store.nowPlayingTrackID, firstTrackID)
        XCTAssertEqual(store.nowPlayingTrack?.id, firstTrackID)
    }

    func testSelectingRenderedTrackForInspectionDoesNotChangeNowPlayingSession() {
        let firstTrackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondTrackID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let firstTrack = BackbeatTrack(
            id: firstTrackID,
            title: "First",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/first.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/first.m4a"),
                    boostDB: 4
                )
            ]
        )
        let secondTrack = BackbeatTrack(
            id: secondTrackID,
            title: "Second",
            duration: 220,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/second.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/second.m4a"),
                    boostDB: 4
                )
            ]
        )
        let store = LibraryStore(
            tracks: [firstTrack, secondTrack],
            selectedTrackID: secondTrackID,
            nowPlayingTrackID: secondTrackID,
            playbackElapsed: 92,
            playbackProgress: 0.42,
            isPlaybackPlaying: true
        )

        XCTAssertTrue(store.selectRenderedTrackForInspection(firstTrackID))

        XCTAssertEqual(store.selectedTrackID, firstTrackID)
        XCTAssertEqual(store.nowPlayingTrackID, secondTrackID)
        XCTAssertEqual(store.playbackElapsed, 92)
        XCTAssertEqual(store.playbackProgress, 0.42)
        XCTAssertTrue(store.isPlaybackPlaying)
    }

    func testSelectingDifferentRenderedTrackForPlaybackResetsStalePlaybackPosition() {
        let firstTrackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondTrackID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let firstTrack = BackbeatTrack(
            id: firstTrackID,
            title: "First",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/first.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/first.m4a"),
                    boostDB: 4
                )
            ]
        )
        let secondTrack = BackbeatTrack(
            id: secondTrackID,
            title: "Second",
            duration: 220,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/second.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/second.m4a"),
                    boostDB: 4
                )
            ]
        )
        let store = LibraryStore(
            tracks: [firstTrack, secondTrack],
            selectedTrackID: secondTrackID,
            nowPlayingTrackID: secondTrackID,
            playbackElapsed: 220,
            playbackProgress: 1
        )

        store.selectTrackForPlayback(firstTrackID)

        XCTAssertEqual(store.nowPlayingTrackID, firstTrackID)
        XCTAssertEqual(store.playbackElapsed, 0)
        XCTAssertEqual(store.playbackProgress, 0)
    }

    func testSelectingRenderedTrackForPlaybackCanRestartCurrentTrackFromBeginning() {
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "First",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/first.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/first.m4a"),
                    boostDB: 4
                )
            ]
        )
        let store = LibraryStore(
            tracks: [track],
            selectedTrackID: trackID,
            nowPlayingTrackID: trackID,
            playbackElapsed: 72,
            playbackProgress: 0.4
        )

        store.selectTrackForPlayback(trackID, restart: true)

        XCTAssertEqual(store.nowPlayingTrackID, trackID)
        XCTAssertEqual(store.playbackElapsed, 0)
        XCTAssertEqual(store.playbackProgress, 0)
    }

    func testCompleteBoostedRenderKeepsOnlyNewestBoostedRender() {
        let store = LibraryStore()
        let track = store.importTrack(
            from: AudioMetadata(fileName: "Paper Crown", duration: 311, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )

        store.completeBoostedRender(
            for: track.id,
            fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/old.m4a"),
            boostDB: 4,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        store.completeBoostedRender(
            for: track.id,
            fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/new.m4a"),
            boostDB: 6,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let updated = store.track(id: track.id)
        XCTAssertEqual(updated?.status, .ready)
        XCTAssertEqual(updated?.activeRenders.count, 1)
        XCTAssertEqual(updated?.activeRender(for: .boostedDrums)?.fileURL.lastPathComponent, "new.m4a")
        XCTAssertEqual(store.nowPlayingTrackID, track.id)
    }

    func testCompletePracticeRenderPromotesDrumsAndDrumlessWithoutLegacyBoostedRender() throws {
        let store = LibraryStore()
        let track = store.importTrack(
            from: AudioMetadata(fileName: "Paper Crown", duration: 311, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )
        let result = PracticeRenderResult(
            drumsURL: URL(fileURLWithPath: "/tmp/renders/drums/paper_drums.m4a"),
            drumlessURL: URL(fileURLWithPath: "/tmp/renders/drumless/paper_drumless.m4a")
        )

        store.setDrumMixBoostDB(6, for: track.id)
        store.completePracticeRender(
            for: track.id,
            result: result,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let updated = store.track(id: track.id)
        XCTAssertEqual(updated?.status, .ready)
        XCTAssertEqual(updated?.activeRenders.count, 2)
        XCTAssertNil(updated?.activeRender(for: .boostedDrums))
        XCTAssertEqual(updated?.activeRender(for: .drums)?.fileURL.lastPathComponent, "paper_drums.m4a")
        XCTAssertEqual(updated?.activeRender(for: .drums)?.boostDB, 0)
        XCTAssertEqual(updated?.activeRender(for: .drumless)?.fileURL.lastPathComponent, "paper_drumless.m4a")
        XCTAssertEqual(updated?.activeRender(for: .drumless)?.boostDB, 0)
        XCTAssertEqual(updated?.drumMixSettings, DrumMixSettings(boostDB: 6), "completion must preserve the live-tuned drum mix")
        XCTAssertEqual(store.nowPlayingTrackID, track.id)
        XCTAssertEqual(store.selectedPlaybackSource, .drumBoost)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .drumBoost)
        XCTAssertEqual(store.selectedPlaybackVariant, .drums)
        XCTAssertEqual(store.nowPlayingPlaybackVariant, .drums)
        XCTAssertEqual(store.detailRender(for: updated!)?.variant, .drums)
        XCTAssertEqual(store.playbackRender(for: updated!)?.variant, .drums)
        let mixAsset = try XCTUnwrap(store.twoTrackMixAsset(for: updated!, preferredSource: .drumBoost))
        XCTAssertEqual(mixAsset.trackID, track.id)
        XCTAssertEqual(mixAsset.drumsURL, result.drumsURL)
        XCTAssertEqual(mixAsset.drumlessURL, result.drumlessURL)
        XCTAssertEqual(mixAsset.duration, track.duration)
        XCTAssertEqual(mixAsset.settings, DrumMixSettings(boostDB: 6))
        let playbackAsset = try XCTUnwrap(store.playbackAsset(for: updated!, preferredSource: .drumBoost))
        XCTAssertEqual(playbackAsset.effectiveSource, .drumBoost)
        XCTAssertEqual(playbackAsset.fileURL, updated?.sourceURL)

        store.selectDetailPlaybackVariant(.drumless, for: store.track(id: track.id))

        XCTAssertEqual(store.selectedPlaybackVariant, .drumless)
        XCTAssertEqual(store.nowPlayingPlaybackVariant, .drums)
        XCTAssertEqual(store.detailRender(for: updated!)?.variant, .drumless)
        XCTAssertEqual(store.playbackRender(for: updated!)?.variant, .drums)
    }

    func testCompletePracticeRenderClearsExistingLegacyBoostedRender() throws {
        let store = LibraryStore()
        let track = store.importTrack(
            from: AudioMetadata(fileName: "Paper Crown", duration: 311, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )
        store.completeBoostedRender(
            for: track.id,
            fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/legacy_boosted.m4a"),
            boostDB: 4,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = PracticeRenderResult(
            drumsURL: URL(fileURLWithPath: "/tmp/renders/drums/paper_drums.m4a"),
            drumlessURL: URL(fileURLWithPath: "/tmp/renders/drumless/paper_drumless.m4a")
        )
        store.completePracticeRender(
            for: track.id,
            result: result,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let updated = store.track(id: track.id)
        XCTAssertNil(updated?.activeRender(for: .boostedDrums))
        XCTAssertEqual(updated?.activeRenders.count, 2)
        XCTAssertEqual(updated?.activeRender(for: .drums)?.fileURL.lastPathComponent, "paper_drums.m4a")
        XCTAssertEqual(updated?.activeRender(for: .drumless)?.fileURL.lastPathComponent, "paper_drumless.m4a")
        XCTAssertEqual(store.selectedPlaybackSource, .drumBoost)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .drumBoost)
        let playbackAsset = try XCTUnwrap(store.playbackAsset(for: updated!, preferredSource: store.selectedPlaybackSource))
        XCTAssertEqual(playbackAsset.effectiveSource, .drumBoost)
        XCTAssertEqual(playbackAsset.fileURL, updated?.sourceURL)
    }

    func testCompletePracticeRenderDoesNotHijackDifferentNowPlayingTrack() {
        let renderedTrack = BackbeatTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Rendered",
            duration: 200,
            status: .rendering,
            sourceURL: URL(fileURLWithPath: "/tmp/rendered.m4a")
        )
        let playingTrack = BackbeatTrack(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            title: "Playing",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/playing.m4a")
        )
        let store = LibraryStore(
            tracks: [renderedTrack, playingTrack],
            selectedTrackID: playingTrack.id,
            nowPlayingTrackID: playingTrack.id,
            selectedPlaybackVariant: .drumless,
            nowPlayingPlaybackVariant: .drumless,
            selectedPlaybackSource: .original,
            nowPlayingPlaybackSource: .original,
            playbackElapsed: 42,
            isPlaybackPlaying: true
        )

        store.completePracticeRender(
            for: renderedTrack.id,
            result: PracticeRenderResult(
                drumsURL: URL(fileURLWithPath: "/tmp/renders/drums/rendered.m4a"),
                drumlessURL: URL(fileURLWithPath: "/tmp/renders/drumless/rendered.m4a")
            )
        )

        XCTAssertEqual(store.selectedTrackID, playingTrack.id)
        XCTAssertEqual(store.nowPlayingTrackID, playingTrack.id)
        XCTAssertTrue(store.isPlaybackPlaying)
        XCTAssertEqual(store.playbackElapsed, 42)
        XCTAssertEqual(store.selectedPlaybackSource, .original)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .original)
        XCTAssertEqual(store.selectedPlaybackVariant, .drumless)
        XCTAssertEqual(store.nowPlayingPlaybackVariant, .drumless)
        let updated = store.track(id: renderedTrack.id)
        XCTAssertEqual(updated?.activeRender(for: .drums)?.fileURL.lastPathComponent, "rendered.m4a")
        XCTAssertEqual(updated?.activeRender(for: .drumless)?.fileURL.lastPathComponent, "rendered.m4a")
        XCTAssertEqual(updated?.drumMixSettings, DrumMixSettings(), "completion must not touch the track's drum mix")
    }

    func testCompletePracticeRenderDoesNotInterruptActivePlaybackOfSameTrack() {
        let track = BackbeatTrack(
            id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
            title: "Playing While Rendering",
            duration: 200,
            status: .rendering,
            sourceURL: URL(fileURLWithPath: "/tmp/playing-while-rendering.m4a")
        )
        let store = LibraryStore(
            tracks: [track],
            selectedTrackID: track.id,
            nowPlayingTrackID: track.id,
            selectedPlaybackSource: .original,
            nowPlayingPlaybackSource: .original,
            playbackElapsed: 42,
            isPlaybackPlaying: true
        )

        store.completePracticeRender(
            for: track.id,
            result: PracticeRenderResult(
                drumsURL: URL(fileURLWithPath: "/tmp/renders/drums/pwr.m4a"),
                drumlessURL: URL(fileURLWithPath: "/tmp/renders/drumless/pwr.m4a")
            )
        )

        // The user is listening to this track as Original mid-render; a
        // background completion must not reset or retarget live playback.
        XCTAssertTrue(store.isPlaybackPlaying)
        XCTAssertEqual(store.playbackElapsed, 42)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .original)
        // The selection-side source still upgrades so the Player offers the mix.
        XCTAssertEqual(store.selectedPlaybackSource, .drumBoost)
        XCTAssertEqual(store.track(id: track.id)?.status, .ready)
    }

    func testRevertRenderingToImportedOnlyAffectsRenderingTracks() {
        let store = LibraryStore()
        let rendering = store.importTrack(
            from: AudioMetadata(fileName: "Rendering", duration: 100, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/rendering.m4a")
        )
        let ready = store.importTrack(
            from: AudioMetadata(fileName: "Ready", duration: 100, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/ready.m4a")
        )
        store.beginRendering(for: rendering.id)
        store.completePracticeRender(
            for: ready.id,
            result: PracticeRenderResult(
                drumsURL: URL(fileURLWithPath: "/tmp/renders/drums/ready.m4a"),
                drumlessURL: URL(fileURLWithPath: "/tmp/renders/drumless/ready.m4a")
            )
        )

        store.revertRenderingToImported(for: rendering.id)
        store.revertRenderingToImported(for: ready.id)

        XCTAssertEqual(store.track(id: rendering.id)?.status, .imported)
        XCTAssertEqual(store.track(id: ready.id)?.status, .ready, "revert must only touch tracks that are mid-render")
    }

    func testTwoTrackMixAssetRequiresDrumsAndDrumlessPairForDrumBoost() throws {
        let completeTrack = BackbeatTrack(
            title: "Complete",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/complete-original.m4a"),
            drumMixSettings: DrumMixSettings(boostDB: 5.5),
            activeRenders: [
                .drums: RenderRecord(
                    variant: .drums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/drums/complete.m4a"),
                    boostDB: 0
                ),
                .drumless: RenderRecord(
                    variant: .drumless,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/drumless/complete.m4a"),
                    boostDB: 0
                )
            ]
        )
        let incompleteTrack = BackbeatTrack(
            title: "Incomplete",
            duration: 181,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/incomplete-original.m4a"),
            activeRenders: [
                .drumless: RenderRecord(
                    variant: .drumless,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/drumless/incomplete.m4a"),
                    boostDB: 0
                )
            ]
        )
        let legacyTrack = BackbeatTrack(
            title: "Legacy",
            duration: 182,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/legacy-original.m4a"),
            activeRenders: [
                .drumless: RenderRecord(
                    variant: .drumless,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/drumless/legacy.m4a"),
                    boostDB: 0
                ),
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/legacy.m4a"),
                    boostDB: 4
                )
            ]
        )
        let store = LibraryStore(tracks: [completeTrack, incompleteTrack, legacyTrack])

        let completeMix = try XCTUnwrap(store.twoTrackMixAsset(for: completeTrack, preferredSource: .drumBoost))
        XCTAssertEqual(completeMix.drumsURL.lastPathComponent, "complete.m4a")
        XCTAssertEqual(completeMix.drumlessURL.lastPathComponent, "complete.m4a")
        XCTAssertNil(store.twoTrackMixAsset(for: completeTrack, preferredSource: .drums))
        XCTAssertNil(store.twoTrackMixAsset(for: incompleteTrack, preferredSource: .drumBoost))
        XCTAssertEqual(
            store.playbackAsset(for: incompleteTrack, preferredSource: .drumBoost)?.effectiveSource,
            .original
        )
        let legacyAsset = try XCTUnwrap(store.playbackAsset(for: legacyTrack, preferredSource: .drumBoost))
        XCTAssertEqual(legacyAsset.effectiveSource, .drumBoost)
        XCTAssertEqual(legacyAsset.fileURL.lastPathComponent, "legacy.m4a")
    }

    func testDrumsPlaybackSourceUsesDrumsRenderWhenPresent() throws {
        let drumsURL = URL(fileURLWithPath: "/tmp/renders/drums/paper.m4a")
        let track = BackbeatTrack(
            title: "Paper",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/original.m4a"),
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        let asset = try XCTUnwrap(store.playbackAsset(for: track, preferredSource: .drums))

        XCTAssertEqual(asset.preferredSource, .drums)
        XCTAssertEqual(asset.effectiveSource, .drums)
        XCTAssertEqual(asset.fileURL, drumsURL)
    }

    func testDrumsPlaybackSourceFallsBackToOriginalWhenDrumsRenderIsMissing() throws {
        let track = BackbeatTrack(
            title: "Paper",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/original.m4a")
        )
        let store = LibraryStore(tracks: [track])

        let asset = try XCTUnwrap(store.playbackAsset(for: track, preferredSource: .drums))

        XCTAssertEqual(asset.preferredSource, .drums)
        XCTAssertEqual(asset.effectiveSource, .original)
        XCTAssertEqual(asset.fileURL, track.sourceURL)
    }

    func testSetDrumMixBoostDBStoresClampedPerTrackSettings() {
        let store = LibraryStore()
        let track = store.importTrack(
            from: AudioMetadata(fileName: "Paper Crown", duration: 311, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )

        store.setDrumMixBoostDB(7.5, for: track.id)
        XCTAssertEqual(store.track(id: track.id)?.drumMixSettings, DrumMixSettings(boostDB: 7.5))

        store.setDrumMixBoostDB(12, for: track.id)
        XCTAssertEqual(store.track(id: track.id)?.drumMixSettings, DrumMixSettings(boostDB: 8))
    }

    func testSetLoudnessProfileStoresPerTrackNormalizationGain() {
        let store = LibraryStore()
        let track = store.importTrack(
            from: AudioMetadata(fileName: "Every Little Thing She Does Is Magic", duration: 260, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/police.m4a")
        )
        let profile = TrackLoudnessProfile(
            integratedLUFS: -16,
            samplePeakDBFS: -8,
            suggestedGainDB: 4,
            analyzedAt: Date(timeIntervalSince1970: 100),
            analyzerVersion: 1
        )

        store.setLoudnessProfile(profile, for: track.id)

        let updated = store.track(id: track.id)
        XCTAssertEqual(updated?.loudnessProfile, profile)
        XCTAssertEqual(updated.map { store.normalizationGainDB(for: $0) }, 4)

        store.setPlaybackNormalizationEnabled(false)
        XCTAssertEqual(updated.map { store.normalizationGainDB(for: $0) }, 0)
    }

    func testDetailAndNowPlayingPlaybackVariantsAreIndependent() {
        let detailTrack = dualRenderedTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Detail"
        )
        let nowPlayingTrack = dualRenderedTrack(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            title: "Now Playing"
        )
        let store = LibraryStore(
            tracks: [detailTrack, nowPlayingTrack],
            selectedTrackID: detailTrack.id,
            nowPlayingTrackID: nowPlayingTrack.id,
            selectedPlaybackVariant: .boostedDrums,
            nowPlayingPlaybackVariant: .drumless
        )

        XCTAssertEqual(store.detailRender(for: detailTrack)?.variant, .boostedDrums)
        XCTAssertEqual(store.playbackRender(for: nowPlayingTrack)?.variant, .drumless)

        XCTAssertTrue(store.selectDetailPlaybackVariant(.drumless, for: detailTrack))

        XCTAssertEqual(store.selectedPlaybackVariant, .drumless)
        XCTAssertEqual(store.nowPlayingPlaybackVariant, .drumless)
        XCTAssertEqual(store.playbackRender(for: nowPlayingTrack)?.variant, .drumless)

        XCTAssertTrue(store.selectNowPlayingPlaybackVariant(.boostedDrums, for: nowPlayingTrack))

        XCTAssertEqual(store.selectedPlaybackVariant, .drumless)
        XCTAssertEqual(store.nowPlayingPlaybackVariant, .boostedDrums)
        XCTAssertEqual(store.detailRender(for: detailTrack)?.variant, .drumless)
        XCTAssertEqual(store.playbackRender(for: nowPlayingTrack)?.variant, .boostedDrums)
    }

    func testSelectingMissingPlaybackVariantKeepsCurrentVariant() {
        let store = LibraryStore()
        let track = store.importTrack(
            from: AudioMetadata(fileName: "Paper Crown", duration: 311, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )
        store.completeBoostedRender(
            for: track.id,
            fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/current.m4a"),
            boostDB: 4,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        store.selectDetailPlaybackVariant(.drumless, for: store.track(id: track.id))

        XCTAssertEqual(store.selectedPlaybackVariant, .boostedDrums)
        XCTAssertEqual(store.detailRender(for: store.track(id: track.id)!)?.variant, .boostedDrums)
    }

    func testSelectTrackForPlaybackWithoutRenderLeavesSelectionUntouched() {
        let readyTrack = BackbeatTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Ready",
            duration: 200,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/ready.m4a"),
            activeRenders: [.boostedDrums: RenderRecord(
                variant: .boostedDrums,
                fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/ready.m4a"),
                boostDB: 4
            )]
        )
        let renderlessTrack = BackbeatTrack(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            title: "Imported",
            duration: 180,
            status: .imported,
            sourceURL: URL(fileURLWithPath: "/tmp/imported.m4a")
        )
        let store = LibraryStore(
            tracks: [readyTrack, renderlessTrack],
            selectedTrackID: readyTrack.id
        )

        XCTAssertFalse(store.selectTrackForPlayback(renderlessTrack.id))

        XCTAssertEqual(store.selectedTrackID, readyTrack.id)
        XCTAssertNil(store.nowPlayingTrackID)
    }

    func testCompletePracticeRenderDeletesSupersededRenderFiles() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let oldBoosted = temporaryRoot.appendingPathComponent("old_boosted.m4a")
        let oldDrums = temporaryRoot.appendingPathComponent("old_drums.m4a")
        let oldDrumless = temporaryRoot.appendingPathComponent("old_drumless.m4a")
        let siblingDrums = temporaryRoot.appendingPathComponent("sibling_drums.m4a")
        for url in [oldBoosted, oldDrums, oldDrumless, siblingDrums] {
            try Data("render".utf8).write(to: url)
        }

        let track = BackbeatTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Paper Crown",
            duration: 311,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(variant: .boostedDrums, fileURL: oldBoosted, boostDB: 4),
                .drums: RenderRecord(variant: .drums, fileURL: oldDrums, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: oldDrumless, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        let result = PracticeRenderResult(
            drumsURL: temporaryRoot.appendingPathComponent("new_drums.m4a"),
            drumlessURL: temporaryRoot.appendingPathComponent("new_drumless.m4a")
        )
        store.completePracticeRender(for: track.id, result: result)

        // The track's superseded files are deleted by their recorded URLs.
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBoosted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDrums.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDrumless.path))
        // Files not referenced by this track's records are never touched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingDrums.path))
        XCTAssertEqual(store.track(id: track.id)?.activeRender(for: .drums)?.fileURL, result.drumsURL)
        XCTAssertEqual(store.track(id: track.id)?.activeRender(for: .drumless)?.fileURL, result.drumlessURL)
    }

    func testMarkRenderFailedStoresFailureMessageWithoutReplacingExistingRender() {
        let store = LibraryStore()
        let track = store.importTrack(
            from: AudioMetadata(fileName: "Paper Crown", duration: 311, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/paper.m4a")
        )
        store.completeBoostedRender(
            for: track.id,
            fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/current.m4a"),
            boostDB: 4,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        store.markRenderFailed(for: track.id, message: "Demucs is not installed.")

        let updated = store.track(id: track.id)
        XCTAssertEqual(updated?.status, .renderFailed)
        XCTAssertEqual(updated?.activeRender(for: .boostedDrums)?.fileURL.lastPathComponent, "current.m4a")
        XCTAssertEqual(store.renderFailureMessage, "Demucs is not installed.")
    }

    func testMarkRenderFailedDoesNotChangeSelection() {
        let failingTrack = BackbeatTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Failing",
            duration: 200,
            status: .rendering,
            sourceURL: URL(fileURLWithPath: "/tmp/failing.m4a")
        )
        let selectedTrack = BackbeatTrack(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            title: "Selected",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/selected.m4a")
        )
        let store = LibraryStore(
            tracks: [failingTrack, selectedTrack],
            selectedTrackID: selectedTrack.id
        )

        store.markRenderFailed(for: failingTrack.id, message: "Demucs exited unexpectedly.")

        XCTAssertEqual(store.selectedTrackID, selectedTrack.id)
        XCTAssertEqual(store.track(id: failingTrack.id)?.status, .renderFailed)
        XCTAssertEqual(store.renderFailureMessage, "Demucs exited unexpectedly.")
    }

    func testPlaybackProgressLabelsAreDerivedFromElapsedTime() {
        let store = LibraryStore()
        let track = store.importTrack(
            from: AudioMetadata(fileName: "sample-song", duration: 271.666, sampleRate: 44_100, channelCount: 2),
            sourceURL: URL(fileURLWithPath: "/tmp/sample-song.m4a")
        )

        store.setPlaybackElapsed(90, duration: track.duration)
        XCTAssertEqual(store.playbackElapsedLabel, "1:30")
        XCTAssertEqual(store.playbackRemainingLabel(for: track), "-3:02")
    }

    func testSeekPlaybackToProgressUpdatesElapsedAndProgress() {
        let store = LibraryStore()

        store.seekPlayback(toProgress: 0.25, duration: 240)

        XCTAssertEqual(store.playbackElapsed, 60)
        XCTAssertEqual(store.playbackProgress, 0.25)
    }

    func testSetPlaybackElapsedNotifiesObserversOnlyWhenValueChanges() {
        let store = LibraryStore()
        store.setPlaybackElapsed(30, duration: 60)

        let flag = ObservationChangeFlag()
        withObservationTracking {
            _ = store.playbackElapsed
            _ = store.playbackProgress
        } onChange: {
            flag.mark()
        }

        store.setPlaybackElapsed(30, duration: 60)
        XCTAssertFalse(flag.didChange, "an unchanged playback tick must not notify observers")

        store.setPlaybackElapsed(31, duration: 60)
        XCTAssertTrue(flag.didChange)
    }

    func testSetPlaybackPlayingNotifiesObserversOnlyWhenValueChanges() {
        let store = LibraryStore()

        let flag = ObservationChangeFlag()
        withObservationTracking {
            _ = store.isPlaybackPlaying
        } onChange: {
            flag.mark()
        }

        store.setPlaybackPlaying(false)
        XCTAssertFalse(flag.didChange, "an unchanged playing flag must not notify observers")

        store.setPlaybackPlaying(true)
        XCTAssertTrue(flag.didChange)
    }

    func testSetVolumeNotifiesObserversOnlyWhenValueChanges() {
        let store = LibraryStore(volume: 0.5)

        let flag = ObservationChangeFlag()
        withObservationTracking {
            _ = store.volume
        } onChange: {
            flag.mark()
        }

        store.setVolume(toProgress: 0.5)
        XCTAssertFalse(flag.didChange, "an unchanged volume must not fire @Observable invalidation on every slider tick (F14)")

        store.setVolume(toProgress: 0.6)
        XCTAssertTrue(flag.didChange)
    }

    func testSetDrumMixBoostDBNotifiesObserversOnlyWhenValueChanges() {
        let track = BackbeatTrack(
            title: "Boost",
            duration: 100,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/boost.m4a"),
            drumMixSettings: DrumMixSettings(boostDB: 4)
        )
        let store = LibraryStore(tracks: [track], selectedTrackID: track.id)

        let flag = ObservationChangeFlag()
        withObservationTracking {
            _ = store.tracks
        } onChange: {
            flag.mark()
        }

        store.setDrumMixBoostDB(4, for: track.id)
        XCTAssertFalse(flag.didChange, "an unchanged drum boost must not fire @Observable invalidation on every slider tick (F14)")

        store.setDrumMixBoostDB(6, for: track.id)
        XCTAssertTrue(flag.didChange)
    }

    func testSetVolumeClampsProgress() {
        let store = LibraryStore(volume: 0.8)

        store.setVolume(toProgress: -0.25)
        XCTAssertEqual(store.volume, 0)

        store.setVolume(toProgress: 0.45)
        XCTAssertEqual(store.volume, 0.45)

        store.setVolume(toProgress: 1.4)
        XCTAssertEqual(store.volume, 1)
    }

    private func dualRenderedTrack(id: BackbeatTrack.ID, title: String) -> BackbeatTrack {
        BackbeatTrack(
            id: id,
            title: title,
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/\(title).m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(
                    variant: .boostedDrums,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/\(title)-boosted.m4a"),
                    boostDB: 4
                ),
                .drumless: RenderRecord(
                    variant: .drumless,
                    fileURL: URL(fileURLWithPath: "/tmp/renders/\(title)-drumless.m4a"),
                    boostDB: 4
                )
            ]
        )
    }

    func testRecoverMissingRenderFilesRevertsReadyTrackAndDropsDanglingRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-recover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let drumsURL = root.appendingPathComponent("drums.m4a")
        let drumlessURL = root.appendingPathComponent("drumless.m4a")
        try Data("drums".utf8).write(to: drumsURL)
        // drumless is intentionally never written — it "vanished" from disk.

        let track = BackbeatTrack(
            title: "Deleted Render",
            duration: 100,
            status: .ready,
            sourceURL: root.appendingPathComponent("source.m4a"),
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track], selectedTrackID: track.id)

        XCTAssertTrue(store.recoverMissingRenderFiles(for: track.id))

        let recovered = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(recovered.status, .imported, "a ready track that lost a render file must revert so the scan re-renders it")
        XCTAssertNil(recovered.activeRender(for: .drumless), "the dangling record must be dropped")
        XCTAssertNotNil(recovered.activeRender(for: .drums), "a render whose file still exists is kept")
    }

    func testRecoverMissingRenderFilesIsNoOpWhenAllFilesExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-recover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let drumsURL = root.appendingPathComponent("drums.m4a")
        let drumlessURL = root.appendingPathComponent("drumless.m4a")
        try Data("drums".utf8).write(to: drumsURL)
        try Data("drumless".utf8).write(to: drumlessURL)

        let track = BackbeatTrack(
            title: "Intact",
            duration: 100,
            status: .ready,
            sourceURL: root.appendingPathComponent("source.m4a"),
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track], selectedTrackID: track.id)

        XCTAssertFalse(store.recoverMissingRenderFiles(for: track.id))
        XCTAssertEqual(store.track(id: track.id)?.status, .ready)
        XCTAssertNotNil(store.track(id: track.id)?.activeRender(for: .drums))
        XCTAssertNotNil(store.track(id: track.id)?.activeRender(for: .drumless))
    }

    // MARK: - applyDurationBackfill (Phase A launch sweep)

    private func legacyPendingTrack(title: String = "Legacy", duration: TimeInterval = 200) -> BackbeatTrack {
        // Constructed directly (not via importTrack, which marks new imports
        // resolved) so isDurationResolved starts false, like a pre-F1 track.
        BackbeatTrack(
            title: title,
            duration: duration,
            status: .imported,
            sourceURL: URL(fileURLWithPath: "/tmp/\(title).m4a")
        )
    }

    func testApplyDurationBackfillKeptEstimateMarksResolvedWithoutChangingDuration() throws {
        let track = legacyPendingTrack()
        let store = LibraryStore(tracks: [track], selectedTrackID: track.id)

        XCTAssertTrue(store.applyDurationBackfill(id: track.id, outcome: .keptEstimate))

        let updated = try XCTUnwrap(store.track(id: track.id))
        XCTAssertTrue(updated.isDurationResolved)
        XCTAssertEqual(updated.duration, 200)
    }

    func testApplyDurationBackfillUpdatedMutatesDurationAndMarksResolved() throws {
        let track = legacyPendingTrack()
        let store = LibraryStore(tracks: [track], selectedTrackID: track.id)

        XCTAssertTrue(store.applyDurationBackfill(id: track.id, outcome: .updated(215.4)))

        let updated = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(updated.duration, 215.4)
        XCTAssertTrue(updated.isDurationResolved)
    }

    func testApplyDurationBackfillUpdatedOnNowPlayingAndPlayingTrackStaysPending() throws {
        let track = legacyPendingTrack(title: "Live")
        let store = LibraryStore(
            tracks: [track],
            selectedTrackID: track.id,
            nowPlayingTrackID: track.id,
            isPlaybackPlaying: true
        )

        XCTAssertFalse(store.applyDurationBackfill(id: track.id, outcome: .updated(215.4)))

        let unchanged = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(unchanged.duration, 200, "the live transport scale must not be mutated mid-playback")
        XCTAssertFalse(unchanged.isDurationResolved, "must stay pending so it heals on the next launch")
    }

    func testApplyDurationBackfillUpdatedAppliesWhileADifferentTrackIsPlaying() throws {
        let pending = legacyPendingTrack(title: "Pending")
        let playing = legacyPendingTrack(title: "Playing")
        let store = LibraryStore(
            tracks: [pending, playing],
            selectedTrackID: pending.id,
            nowPlayingTrackID: playing.id,
            isPlaybackPlaying: true
        )

        XCTAssertTrue(store.applyDurationBackfill(id: pending.id, outcome: .updated(215.4)))

        let updated = try XCTUnwrap(store.track(id: pending.id))
        XCTAssertEqual(updated.duration, 215.4)
        XCTAssertTrue(
            updated.isDurationResolved,
            "the skip is per-track (nowPlayingTrackID == id), not global — playback of another track must not defer this track's heal"
        )
    }

    func testApplyDurationBackfillUpdatedOnNowPlayingButPausedTrackApplies() throws {
        let track = legacyPendingTrack(title: "Paused")
        let store = LibraryStore(
            tracks: [track],
            selectedTrackID: track.id,
            nowPlayingTrackID: track.id,
            isPlaybackPlaying: false
        )

        XCTAssertTrue(store.applyDurationBackfill(id: track.id, outcome: .updated(215.4)))

        let updated = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(updated.duration, 215.4)
        XCTAssertTrue(updated.isDurationResolved)
    }

    func testApplyDurationBackfillUnknownIDReturnsFalse() {
        let store = LibraryStore()
        XCTAssertFalse(store.applyDurationBackfill(id: UUID(), outcome: .keptEstimate))
    }

    func testApplyDurationBackfillUpdatedWithinToleranceMarksResolvedWithoutMutatingDuration() throws {
        let track = legacyPendingTrack(title: "CloseEnough")
        let store = LibraryStore(tracks: [track], selectedTrackID: track.id)

        // The service already thresholds updated vs. keptEstimate; this
        // exercises the store's own defensive no-op guard (F14) in case an
        // `.updated` with a sub-tolerance delta is ever passed through.
        XCTAssertTrue(store.applyDurationBackfill(id: track.id, outcome: .updated(200.02)))

        let updated = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(updated.duration, 200, "a sub-tolerance updated(...) must not perturb the persisted duration")
        XCTAssertTrue(updated.isDurationResolved)
    }
}

// withObservationTracking's onChange closure is @Sendable, so the fired flag
// needs a lock-guarded box rather than a captured var.
private final class ObservationChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var didChange: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mark() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}
