import XCTest
@testable import BackbeatCore

@MainActor
final class LibraryStorePlaylistTests: XCTestCase {
    func testCreatePlaylistSelectsItAndStoresDefaultSource() {
        let store = LibraryStore()

        let playlist = store.createPlaylist(name: "Practice")

        XCTAssertEqual(store.playlists, [playlist])
        XCTAssertEqual(store.selectedPlaylistID, playlist.id)
        XCTAssertEqual(playlist.name, "Practice")
        XCTAssertEqual(playlist.trackIDs, [])
        XCTAssertEqual(playlist.defaultPlaybackSource, .drumBoost)
    }

    func testRenamePlaylistUpdatesNameAndTimestamp() {
        let created = Date(timeIntervalSince1970: 10)
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Old",
            createdAt: created,
            updatedAt: created
        )
        let store = LibraryStore(playlists: [playlist], selectedPlaylistID: playlist.id)

        store.renamePlaylist(playlist.id, to: "New", updatedAt: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.playlists.first?.name, "New")
        XCTAssertEqual(store.playlists.first?.createdAt, created)
        XCTAssertEqual(store.playlists.first?.updatedAt, Date(timeIntervalSince1970: 20))
    }

    func testSetPlaylistDefaultPlaybackSourceUpdatesSourceAndTimestamp() {
        let created = Date(timeIntervalSince1970: 10)
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Practice",
            createdAt: created,
            updatedAt: created
        )
        let store = LibraryStore(playlists: [playlist])

        store.setPlaylistDefaultPlaybackSource(.drumless, for: playlist.id, updatedAt: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.playlists.first?.defaultPlaybackSource, .drumless)
        XCTAssertEqual(store.playlists.first?.updatedAt, Date(timeIntervalSince1970: 20))

        // Re-setting the same source is a no-op and must not churn updatedAt.
        store.setPlaylistDefaultPlaybackSource(.drumless, for: playlist.id, updatedAt: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(store.playlists.first?.updatedAt, Date(timeIntervalSince1970: 20))
    }

    func testAddTracksIgnoresDuplicatesAndPreservesOrder() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let playlist = BackbeatPlaylist(name: "Practice", trackIDs: [firstID])
        let store = LibraryStore(playlists: [playlist])

        store.addTracks([firstID, secondID], to: playlist.id, updatedAt: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(store.playlists.first?.trackIDs, [firstID, secondID])
        XCTAssertEqual(store.playlists.first?.updatedAt, Date(timeIntervalSince1970: 30))
    }

    func testRemoveTrackDeletesAllMatchingEntriesFromPlaylist() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let playlist = BackbeatPlaylist(name: "Practice", trackIDs: [firstID, secondID])
        let store = LibraryStore(playlists: [playlist])

        store.removeTrack(firstID, from: playlist.id, updatedAt: Date(timeIntervalSince1970: 40))

        XCTAssertEqual(store.playlists.first?.trackIDs, [secondID])
        XCTAssertEqual(store.playlists.first?.updatedAt, Date(timeIntervalSince1970: 40))
    }

    func testDeletePlaylistRemovesPlaylistPreservesTracksAndStopsDeletedQueue() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let firstTrack = BackbeatTrack(id: firstID, title: "First", duration: 90, status: .ready, sourceURL: URL(fileURLWithPath: "/tmp/first.m4a"))
        let secondTrack = BackbeatTrack(id: secondID, title: "Second", duration: 120, status: .ready, sourceURL: URL(fileURLWithPath: "/tmp/second.m4a"))
        let deletedPlaylist = BackbeatPlaylist(
            id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
            name: "Delete",
            trackIDs: [firstID, secondID]
        )
        let remainingPlaylist = BackbeatPlaylist(
            id: UUID(uuidString: "44444444-5555-6666-7777-888888888888")!,
            name: "Keep",
            trackIDs: [secondID]
        )
        let queue = PlaybackQueue(
            playlistID: deletedPlaylist.id,
            trackIDs: [firstID, secondID],
            currentIndex: 0,
            preferredSource: .boostedDrums
        )
        let store = LibraryStore(
            tracks: [firstTrack, secondTrack],
            selectedTrackID: secondID,
            nowPlayingTrackID: firstID,
            playlists: [deletedPlaylist, remainingPlaylist],
            selectedPlaylistID: deletedPlaylist.id,
            activeQueue: queue,
            playbackElapsed: 12,
            playbackProgress: 0.2,
            isPlaybackPlaying: true
        )

        store.deletePlaylist(deletedPlaylist.id)

        XCTAssertEqual(store.playlists.map(\.id), [remainingPlaylist.id])
        XCTAssertEqual(store.tracks.map(\.id), [firstID, secondID])
        XCTAssertNil(store.selectedPlaylistID)
        XCTAssertNil(store.activeQueue)
        XCTAssertNil(store.nowPlayingTrackID)
        XCTAssertFalse(store.isPlaybackPlaying)
        XCTAssertEqual(store.playbackElapsed, 0)
        XCTAssertEqual(store.playbackProgress, 0)
    }

    func testDeletingTrackRemovesItFromPlaylistsAndActiveQueue() throws {
        let deletedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let remainingID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let deletedTrack = BackbeatTrack(id: deletedID, title: "Delete", duration: 100, status: .ready, sourceURL: URL(fileURLWithPath: "/tmp/delete.m4a"))
        let remainingTrack = BackbeatTrack(id: remainingID, title: "Keep", duration: 120, status: .ready, sourceURL: URL(fileURLWithPath: "/tmp/keep.m4a"))
        let playlist = BackbeatPlaylist(name: "Practice", trackIDs: [deletedID, remainingID])
        let queue = PlaybackQueue(trackIDs: [deletedID, remainingID], currentIndex: 0, preferredSource: .boostedDrums)
        let store = LibraryStore(
            tracks: [deletedTrack, remainingTrack],
            playlists: [playlist],
            activeQueue: queue
        )

        try store.deleteTrack(id: deletedID)

        XCTAssertEqual(store.playlists.first?.trackIDs, [remainingID])
        XCTAssertEqual(store.activeQueue?.trackIDs, [remainingID])
        XCTAssertEqual(store.activeQueue?.currentIndex, 0)
    }
}
