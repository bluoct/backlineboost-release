import XCTest

final class TrackRowActionsSourceTests: XCTestCase {
    func testOpenRoutesEveryTrackToThePlayer() throws {
        let source = try readSource("Sources/Backbeat/Views/TrackRowActions.swift")

        XCTAssertTrue(source.contains("store.selectRenderedTrackForInspection(track.id)"))
        XCTAssertTrue(source.contains("store.selectTrack(track.id)"))
        XCTAssertFalse(source.contains("route.wrappedValue = .preview"), "There is no preview screen; unrendered tracks open in the Player.")
        XCTAssertTrue(source.contains("route.wrappedValue = .player"))
    }

    func testPlayFromStartPlaysOriginalForUnrenderedTracks() throws {
        let source = try readSource("Sources/Backbeat/Views/TrackRowActions.swift")

        XCTAssertTrue(source.contains("store.selectTrackForPlayback(track.id, restart: true)"))
        XCTAssertTrue(source.contains("playback.playRenderFromStart(track: track, store: store)"))
        XCTAssertTrue(
            source.contains("playback.playTrack(track: track, store: store, source: .original, startElapsed: 0)"),
            "An unrendered track must start playing immediately from its original file."
        )
        XCTAssertFalse(
            source.contains("track.status == .ready, store.selectTrackForPlayback"),
            "Render playback gates on record presence, not status — a re-rendering or render-failed track still holds its old playable pair (D-105)."
        )
    }

    func testRowActionsHostTheSharedTapGestureDispatcher() throws {
        let source = try readSource("Sources/Backbeat/Views/TrackRowActions.swift")

        XCTAssertTrue(source.contains("TapGesture(count: 2)"))
        XCTAssertTrue(source.contains(".exclusively(before: TapGesture(count: 1))"))
        XCTAssertTrue(source.contains("playFromStart(track, queueing: visibleTrackIDs)"))
        XCTAssertTrue(source.contains("open(track)"))
    }

    func testPlayFromStartAnchorsTheLibraryQueueOnlyWhenNoPlaylistQueueIsActive() throws {
        let source = try readSource("Sources/Backbeat/Views/TrackRowActions.swift")

        // The D-102 hybrid gate: nil queue OR a non-playlist queue anchors
        // the visible-order library queue; an active playlist queue falls
        // through to the interleave path.
        XCTAssertTrue(source.contains("if store.activeQueue?.playlistID == nil {"))
        XCTAssertTrue(source.contains("store.startLibraryQueue(visibleTrackIDs, startingAt: track.id)"))
        XCTAssertTrue(
            source.contains("source: store.activeQueue?.preferredSource ?? store.nowPlayingPlaybackSource"),
            "The library-queue start must mirror PlaylistDetailView.playPlaylist's source resolution."
        )
        // The interleave path is owner-sacred: playFromStart must never
        // mutate the queue directly — the only queue write allowed here is
        // startLibraryQueue behind the playlist gate.
        XCTAssertFalse(
            source.contains("store.activeQueue ="),
            "TrackRowActions must never assign the queue directly; the playlist interleave depends on the queue surviving one-off plays."
        )
        XCTAssertFalse(
            source.contains("startSingleTrackQueue"),
            "Double-click must not collapse the queue to a single track."
        )
        // A failed hybrid start means the library mutated under the click:
        // a vanished track must not fall through to playing a dead file, and
        // a recoverable fallthrough must not strand the queue-start error.
        XCTAssertTrue(source.contains("guard store.track(id: track.id) != nil else { return }"))
        XCTAssertTrue(source.contains("store.playbackFailure = nil"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
