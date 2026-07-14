import XCTest
@testable import BackbeatCore

@MainActor
final class PlaybackFailureStoreTests: XCTestCase {
    func testStartPlaylistWithNoResolvableTracksSetsPlaylistEmpty() {
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Practice",
            trackIDs: [UUID(uuidString: "99999999-9999-9999-9999-999999999999")!],
            defaultPlaybackSource: .drumless
        )
        let store = LibraryStore(tracks: [], playlists: [playlist])

        let started = store.startPlaylist(playlist.id)

        XCTAssertNil(started)
        XCTAssertEqual(store.playbackFailure, .playlistEmpty)
    }

    func testStartPlaylistWithStartingTrackNotInPlaylistSetsTrackNotInPlaylist() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let unlisted = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Unlisted")
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Practice",
            trackIDs: [first.id],
            defaultPlaybackSource: .drumless
        )
        let store = LibraryStore(tracks: [first, unlisted], playlists: [playlist])

        let started = store.startPlaylist(playlist.id, at: unlisted.id)

        XCTAssertNil(started)
        XCTAssertEqual(store.playbackFailure, .trackNotInPlaylist)
    }

    func testStartLibraryQueueWithNoResolvableTracksSetsQueueEmpty() {
        let store = LibraryStore(tracks: [])
        let danglingID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        let started = store.startLibraryQueue([danglingID], startingAt: danglingID)

        XCTAssertNil(started)
        XCTAssertEqual(store.playbackFailure, .queueEmpty)
    }

    func testStartLibraryQueueWithStartingTrackNotInListSetsTrackNotInList() {
        let listed = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Listed")
        let unlisted = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Unlisted")
        let store = LibraryStore(tracks: [listed, unlisted])

        let started = store.startLibraryQueue([listed.id], startingAt: unlisted.id)

        XCTAssertNil(started)
        XCTAssertEqual(store.playbackFailure, .trackNotInList)
    }

    func testStartSingleTrackQueueForUnknownTrackSetsTrackNotPlayable() {
        let store = LibraryStore(tracks: [])
        let unknownID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        let started = store.startSingleTrackQueue(unknownID, preferredSource: .original)

        XCTAssertNil(started)
        XCTAssertEqual(store.playbackFailure, .trackNotPlayable)
    }

    func testSuccessfulStartPlaylistClearsAPreSetFailure() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Practice",
            trackIDs: [track.id],
            defaultPlaybackSource: .drumless
        )
        let store = LibraryStore(tracks: [track], playlists: [playlist])
        store.playbackFailure = .queueEmpty

        _ = store.startPlaylist(playlist.id)

        XCTAssertNil(store.playbackFailure)
    }

    func testSuccessfulStartLibraryQueueClearsAPreSetFailure() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let store = LibraryStore(tracks: [track])
        store.playbackFailure = .queueEmpty

        _ = store.startLibraryQueue([track.id], startingAt: track.id)

        XCTAssertNil(store.playbackFailure)
    }

    func testSuccessfulStartSingleTrackQueueClearsAPreSetFailure() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let store = LibraryStore(tracks: [track])
        store.playbackFailure = .queueEmpty

        _ = store.startSingleTrackQueue(track.id, preferredSource: .original)

        XCTAssertNil(store.playbackFailure)
    }

    func testSetPlaybackPlayingTrueClearsAPreSetFailure() {
        let store = LibraryStore()
        store.playbackFailure = .queueEmpty

        store.setPlaybackPlaying(true)

        XCTAssertNil(store.playbackFailure)
    }

    func testSetPlaybackPlayingFalseLeavesAPreSetFailureInPlace() {
        let store = LibraryStore()
        store.playbackFailure = .queueEmpty

        store.setPlaybackPlaying(false)

        XCTAssertEqual(store.playbackFailure, .queueEmpty)
    }

    // Safe-copy guard (COR-003): no case's message may leak a file path.
    // CaseIterable so a newly added case cannot silently escape the guard.
    func testEveryFailureMessageIsNonEmptyAndContainsNoPathSeparator() {
        for failure in PlaybackFailure.allCases {
            XCTAssertFalse(failure.userMessage.isEmpty)
            XCTAssertFalse(failure.userMessage.contains("/"))
        }
    }

    private func readyTrack(id: BackbeatTrack.ID, title: String) -> BackbeatTrack {
        BackbeatTrack(
            id: id,
            title: title,
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/\(title).m4a")
        )
    }
}
