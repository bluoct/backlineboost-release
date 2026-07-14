import XCTest
@testable import BackbeatCore

@MainActor
final class PlaybackQueueStoreTests: XCTestCase {
    func testStartingPlaylistCreatesActiveQueueAndSelectsFirstTrack() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Practice",
            trackIDs: [first.id, second.id],
            defaultPlaybackSource: .drumless
        )
        let store = LibraryStore(tracks: [first, second], playlists: [playlist])

        let started = store.startPlaylist(playlist.id)

        XCTAssertEqual(started?.id, first.id)
        XCTAssertEqual(store.activeQueue?.playlistID, playlist.id)
        XCTAssertEqual(store.activeQueue?.trackIDs, [first.id, second.id])
        XCTAssertEqual(store.activeQueue?.currentIndex, 0)
        XCTAssertEqual(store.activeQueue?.preferredSource, .drumless)
        XCTAssertEqual(store.nowPlayingTrackID, first.id)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .drumless)
        XCTAssertEqual(store.playbackElapsed, 0)
    }

    func testStartingPlaylistClearsPracticeState() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Practice",
            trackIDs: [track.id],
            defaultPlaybackSource: .drumBoost
        )
        let store = LibraryStore(tracks: [track], playlists: [playlist])
        store.setPracticeSpeed(0.75)
        store.setPracticeSectionLoop(start: 8, end: 12, duration: track.duration)

        _ = store.startPlaylist(playlist.id)

        XCTAssertEqual(store.practiceSpeed, 1)
        XCTAssertEqual(store.practiceLoopMode, .off)
        XCTAssertNil(store.practiceLoopRange)
        XCTAssertFalse(store.isPracticeZoomVisible)
    }

    func testStartingPlaylistAtTrackKeepsPlaylistQueueAndStartsFromThatTrack() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let third = readyTrack(id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!, title: "Third")
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Practice",
            trackIDs: [first.id, second.id, third.id],
            defaultPlaybackSource: .drumless
        )
        let store = LibraryStore(tracks: [first, second, third], playlists: [playlist])

        let started = store.startPlaylist(playlist.id, at: second.id)

        XCTAssertEqual(started?.id, second.id)
        XCTAssertEqual(store.activeQueue?.playlistID, playlist.id)
        XCTAssertEqual(store.activeQueue?.trackIDs, [first.id, second.id, third.id])
        XCTAssertEqual(store.activeQueue?.currentIndex, 1)
        XCTAssertEqual(store.nowPlayingTrackID, second.id)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .drumless)
    }

    func testStartingSingleTrackCreatesOneTrackQueue() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Single")
        let store = LibraryStore(tracks: [track])

        let started = store.startSingleTrackQueue(track.id, preferredSource: .original)

        XCTAssertEqual(started?.id, track.id)
        XCTAssertNil(store.activeQueue?.playlistID)
        XCTAssertEqual(store.activeQueue?.trackIDs, [track.id])
        XCTAssertEqual(store.activeQueue?.preferredSource, .original)
        XCTAssertEqual(store.nowPlayingTrackID, track.id)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .original)
    }

    func testStartingSingleTrackQueueClearsPracticeState() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Single")
        let store = LibraryStore(tracks: [track])
        store.setPracticeSpeed(1.25)
        store.setPracticeSectionLoop(start: 8, end: 12, duration: track.duration)

        _ = store.startSingleTrackQueue(track.id, preferredSource: .original)

        XCTAssertEqual(store.practiceSpeed, 1)
        XCTAssertEqual(store.practiceLoopMode, .off)
        XCTAssertNil(store.practiceLoopRange)
        XCTAssertFalse(store.isPracticeZoomVisible)
    }

    func testQueueNavigationAvailabilityTracksCurrentQueuePosition() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let store = LibraryStore(
            tracks: [first, second],
            activeQueue: PlaybackQueue(trackIDs: [first.id, second.id], currentIndex: 0, preferredSource: .boostedDrums),
            playbackElapsed: 0
        )

        XCTAssertFalse(store.canPlayPreviousInQueue)
        XCTAssertTrue(store.canPlayNextInQueue)

        store.playbackElapsed = 4
        XCTAssertTrue(store.canPlayPreviousInQueue)

        store.activeQueue = PlaybackQueue(trackIDs: [first.id, second.id], currentIndex: 1, preferredSource: .boostedDrums)
        store.playbackElapsed = 0
        XCTAssertTrue(store.canPlayPreviousInQueue)
        XCTAssertFalse(store.canPlayNextInQueue)

        store.activeQueue = PlaybackQueue(trackIDs: [first.id], currentIndex: 0, preferredSource: .boostedDrums)
        XCTAssertFalse(store.canPlayPreviousInQueue)
        XCTAssertFalse(store.canPlayNextInQueue)

        store.activeQueue = nil
        XCTAssertFalse(store.canPlayPreviousInQueue)
        XCTAssertFalse(store.canPlayNextInQueue)
    }

    func testAdvanceQueueMovesToNextTrackAndStopsAtEnd() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let queue = PlaybackQueue(trackIDs: [first.id, second.id], currentIndex: 0, preferredSource: .boostedDrums)
        let store = LibraryStore(tracks: [first, second], nowPlayingTrackID: first.id, activeQueue: queue)

        let next = store.advanceQueue()
        let ended = store.advanceQueue()

        XCTAssertEqual(next?.id, second.id)
        XCTAssertEqual(store.activeQueue?.currentIndex, 1)
        XCTAssertEqual(store.nowPlayingTrackID, second.id)
        XCTAssertNil(ended)
        XCTAssertFalse(store.isPlaybackPlaying)
        XCTAssertEqual(store.playbackElapsed, 0)
    }

    func testAdvanceQueueHonorsRepeatModes() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let store = LibraryStore(
            tracks: [first, second],
            nowPlayingTrackID: first.id,
            activeQueue: PlaybackQueue(
                trackIDs: [first.id, second.id],
                currentIndex: 0,
                preferredSource: .boostedDrums,
                repeatMode: .one
            )
        )

        let repeated = store.advanceQueue()

        XCTAssertEqual(repeated?.id, first.id)
        XCTAssertEqual(store.activeQueue?.currentIndex, 0)
        XCTAssertEqual(store.nowPlayingTrackID, first.id)

        store.activeQueue = PlaybackQueue(
            trackIDs: [first.id, second.id],
            currentIndex: 1,
            preferredSource: .boostedDrums,
            repeatMode: .all
        )
        store.nowPlayingTrackID = second.id

        let wrapped = store.advanceQueue()

        XCTAssertEqual(wrapped?.id, first.id)
        XCTAssertEqual(store.activeQueue?.currentIndex, 0)
        XCTAssertEqual(store.nowPlayingTrackID, first.id)
    }

    func testAdvanceQueueTerminatesWhenNoQueuedTrackResolves() {
        let store = LibraryStore(
            tracks: [],
            activeQueue: PlaybackQueue(
                trackIDs: [
                    UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
                ],
                currentIndex: 0,
                preferredSource: .boostedDrums,
                repeatMode: .all
            ),
            isPlaybackPlaying: true
        )

        let next = store.advanceQueue()

        XCTAssertNil(next)
        XCTAssertFalse(store.isPlaybackPlaying)
    }

    func testAdvanceQueueSkipsDanglingIDToNextResolvableTrack() {
        let real = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Real")
        let danglingID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let store = LibraryStore(
            tracks: [real],
            nowPlayingTrackID: real.id,
            activeQueue: PlaybackQueue(
                trackIDs: [danglingID, real.id],
                currentIndex: 1,
                preferredSource: .boostedDrums,
                repeatMode: .all
            )
        )

        let next = store.advanceQueue()

        XCTAssertEqual(next?.id, real.id)
        XCTAssertEqual(store.activeQueue?.currentIndex, 1)
        XCTAssertEqual(store.nowPlayingTrackID, real.id)
    }

    func testShuffleTogglePreservesCurrentTrackAndCanRestorePlaylistOrder() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let third = readyTrack(id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!, title: "Third")
        let playlist = BackbeatPlaylist(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            name: "Practice",
            trackIDs: [first.id, second.id, third.id],
            defaultPlaybackSource: .drumBoost
        )
        let store = LibraryStore(
            tracks: [first, second, third],
            nowPlayingTrackID: second.id,
            playlists: [playlist],
            activeQueue: PlaybackQueue(
                playlistID: playlist.id,
                trackIDs: [first.id, second.id, third.id],
                currentIndex: 1,
                preferredSource: .boostedDrums
            )
        )

        store.setShuffleEnabled(true)

        XCTAssertTrue(store.activeQueue?.isShuffleEnabled == true)
        XCTAssertEqual(store.activeQueue?.currentTrackID, second.id)
        XCTAssertEqual(Set(store.activeQueue?.trackIDs ?? []), Set([first.id, second.id, third.id]))

        store.setShuffleEnabled(false)

        XCTAssertFalse(store.activeQueue?.isShuffleEnabled == true)
        XCTAssertEqual(store.activeQueue?.trackIDs, [first.id, second.id, third.id])
        XCTAssertEqual(store.activeQueue?.currentIndex, 1)
    }

    func testPracticeSpeedCanStepIncrementallyAndClamp() {
        let store = LibraryStore()

        store.stepPracticeSpeed(by: 0.05)
        XCTAssertEqual(store.practiceSpeed, 1.05, accuracy: 0.0001)

        store.stepPracticeSpeed(by: -0.10)
        XCTAssertEqual(store.practiceSpeed, 0.95, accuracy: 0.0001)

        store.setPracticeSpeed(1.49)
        store.stepPracticeSpeed(by: 0.05)
        XCTAssertEqual(store.practiceSpeed, 1.5, accuracy: 0.0001)

        store.setPracticeSpeed(0.51)
        store.stepPracticeSpeed(by: -0.05)
        XCTAssertEqual(store.practiceSpeed, 0.5, accuracy: 0.0001)
    }

    func testRetreatQueueRestartsCurrentTrackAfterThreeSeconds() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let queue = PlaybackQueue(trackIDs: [first.id, second.id], currentIndex: 1, preferredSource: .boostedDrums)
        let store = LibraryStore(tracks: [first, second], nowPlayingTrackID: second.id, activeQueue: queue, playbackElapsed: 4)

        let current = store.retreatQueue()

        XCTAssertEqual(current?.id, second.id)
        XCTAssertEqual(store.activeQueue?.currentIndex, 1)
        XCTAssertEqual(store.playbackElapsed, 0)
    }

    func testSetActiveQueueSourceUpdatesQueueAndNowPlayingSource() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Track")
        let queue = PlaybackQueue(trackIDs: [track.id], preferredSource: .boostedDrums)
        let store = LibraryStore(tracks: [track], nowPlayingTrackID: track.id, activeQueue: queue)

        store.setActiveQueueSource(.drumless)

        XCTAssertEqual(store.activeQueue?.preferredSource, .drumless)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .drumless)
    }

    func testNowPlayingSourceWritePathsKeepQueueInSync() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Track")
        let store = LibraryStore(
            tracks: [track],
            nowPlayingTrackID: track.id,
            activeQueue: PlaybackQueue(trackIDs: [track.id], preferredSource: .boostedDrums)
        )

        store.setActiveQueueSource(.drums)

        XCTAssertEqual(store.activeQueue?.preferredSource, .drums)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .drums)

        XCTAssertTrue(store.selectNowPlayingPlaybackSource(.drumless, for: track))

        XCTAssertEqual(store.activeQueue?.preferredSource, .drumless)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .drumless)
    }

    // MARK: - Library queue (D-102 hybrid double-click)

    func testStartLibraryQueueSnapshotsVisibleOrderWithNilPlaylistID() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let third = readyTrack(id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!, title: "Third")
        let store = LibraryStore(tracks: [first, second, third])
        // The caller's visible order, deliberately different from array order.
        let visibleIDs = [third.id, first.id, second.id]

        let started = store.startLibraryQueue(visibleIDs, startingAt: first.id)

        XCTAssertEqual(started?.id, first.id)
        XCTAssertNil(store.activeQueue?.playlistID)
        XCTAssertEqual(store.activeQueue?.trackIDs, visibleIDs)
        XCTAssertEqual(store.activeQueue?.currentIndex, 1)
        XCTAssertEqual(store.activeQueue?.preferredSource, .drumBoost)
        XCTAssertEqual(store.nowPlayingTrackID, first.id)
        XCTAssertEqual(store.nowPlayingPlaybackSource, .drumBoost)
        XCTAssertEqual(store.playbackElapsed, 0)
        XCTAssertNil(store.playbackFailure)
    }

    func testStartLibraryQueueClearsPracticeState() {
        let track = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let store = LibraryStore(tracks: [track])
        store.setPracticeSpeed(0.75)
        store.setPracticeSectionLoop(start: 8, end: 12, duration: track.duration)

        _ = store.startLibraryQueue([track.id], startingAt: track.id)

        XCTAssertEqual(store.practiceSpeed, 1)
        XCTAssertEqual(store.practiceLoopMode, .off)
        XCTAssertNil(store.practiceLoopRange)
        XCTAssertFalse(store.isPracticeZoomVisible)
    }

    func testStartLibraryQueueSkipsDanglingIDs() {
        let known = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Known")
        let alsoKnown = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Also")
        let store = LibraryStore(tracks: [known, alsoKnown])
        let danglingID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        let started = store.startLibraryQueue([known.id, danglingID, alsoKnown.id], startingAt: alsoKnown.id)

        XCTAssertEqual(started?.id, alsoKnown.id)
        XCTAssertEqual(store.activeQueue?.trackIDs, [known.id, alsoKnown.id])
        XCTAssertEqual(store.activeQueue?.currentIndex, 1)
    }

    func testStartLibraryQueueRequiresStartingTrackInTheList() {
        let listed = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Listed")
        let unlisted = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Unlisted")
        let store = LibraryStore(tracks: [listed, unlisted])

        let started = store.startLibraryQueue([listed.id], startingAt: unlisted.id)

        XCTAssertNil(started)
        XCTAssertNil(store.activeQueue)
        XCTAssertEqual(store.playbackFailure, .trackNotInList)
    }

    func testStartLibraryQueueWithNoResolvableTracksSetsErrorMessage() {
        let store = LibraryStore(tracks: [])
        let danglingID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        let started = store.startLibraryQueue([danglingID], startingAt: danglingID)

        XCTAssertNil(started)
        XCTAssertNil(store.activeQueue)
        XCTAssertEqual(store.playbackFailure, .queueEmpty)
    }

    func testAdvanceQueueWalksLibraryQueueInVisibleOrder() {
        let first = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "First")
        let second = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Second")
        let third = readyTrack(id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!, title: "Third")
        let store = LibraryStore(tracks: [first, second, third])
        _ = store.startLibraryQueue([third.id, first.id, second.id], startingAt: third.id)

        XCTAssertEqual(store.advanceQueue()?.id, first.id)
        XCTAssertEqual(store.advanceQueue()?.id, second.id)
        XCTAssertNil(store.advanceQueue())
    }

    func testUnshuffleRestoresLibraryQueueToPersistedSortOrder() {
        let alpha = readyTrack(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Alpha")
        let bravo = readyTrack(id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, title: "Bravo")
        let charlie = readyTrack(id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!, title: "Charlie")
        // Store order deliberately differs from the title sort so the test
        // can tell "restored to sort order" apart from "restored to array
        // order".
        let store = LibraryStore(
            tracks: [charlie, alpha, bravo],
            librarySortOrder: LibrarySortOrder(field: .title, ascending: true)
        )
        _ = store.startLibraryQueue([alpha.id, bravo.id, charlie.id], startingAt: bravo.id)

        store.setShuffleEnabled(true)
        XCTAssertEqual(store.activeQueue?.trackIDs.first, bravo.id)
        store.setShuffleEnabled(false)

        // Without the library-queue branch, un-shuffle is a silent no-op for
        // nil-playlistID queues and the shuffled order is stranded.
        XCTAssertEqual(store.activeQueue?.trackIDs, [alpha.id, bravo.id, charlie.id])
        XCTAssertEqual(store.activeQueue?.currentIndex, 1)
        XCTAssertEqual(store.activeQueue?.currentTrackID, bravo.id)
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
