import XCTest

final class PlaylistDetailSourceTests: XCTestCase {
    func testPlaylistDetailExposesRenameAddRemovePlayAndSourceControls() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        XCTAssertTrue(source.contains("struct PlaylistDetailView"))
        XCTAssertTrue(source.contains("TextField("))
        XCTAssertTrue(source.contains("PlaybackSourcePicker("))
        XCTAssertTrue(source.contains("store.renamePlaylist("))
        XCTAssertTrue(source.contains("store.addTracks("))
        XCTAssertTrue(source.contains("store.removeTrack("))
        XCTAssertTrue(source.contains("store.startPlaylist("))
    }

    func testPlaylistRowsOpenTracksInThePlayerWithTheWaveformButton() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        // The open affordance navigates without playing (waveform, never a
        // play triangle — owner QA 2026-07-13), and the minus button only
        // removes the playlist entry, never the library track.
        XCTAssertTrue(source.contains("TrackRowActions(store: store, playback: playback, route: $route).open(track)"))
        XCTAssertTrue(source.contains("Image(systemName: \"waveform\")"))
        XCTAssertTrue(source.contains("store.removeTrack(track.id, from: playlistID)"))
        XCTAssertFalse(source.contains("deleteTrack"), "playlist rows must never delete from the library")

        let library = try readSource("Sources/Backbeat/Views/LibraryView.swift")
        XCTAssertTrue(library.contains("Image(systemName: \"waveform\")"))
        XCTAssertFalse(
            library.contains("track.status == .ready ? \"play.fill\" : \"chevron.right\""),
            "the open button must not masquerade as a play button"
        )
    }

    func testPlaylistPlayStaysOnPlaylistAndHighlightsNowPlayingTrack() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        XCTAssertTrue(source.contains("isNowPlaying(track)"))
        XCTAssertTrue(source.contains("BackbeatStyle.primary.opacity(0.16)"))
        XCTAssertFalse(source.contains("route = .player"))
    }

    func testPlaylistRowsDoubleClickStartPlaylistAtThatTrack() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        XCTAssertTrue(source.contains(".onTapGesture(count: 2)"))
        XCTAssertTrue(source.contains("playPlaylist(startingAt: track.id)"))
        XCTAssertTrue(source.contains("store.startPlaylist(playlistID, at: startingTrackID)"))
    }

    func testPlaylistTrackListScrollsInsideDetailPane() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains(".frame(maxHeight: .infinity"))
        XCTAssertTrue(source.contains("trackList"))
    }

    func testPlaylistSourceControlSwitchesLiveQueuePlayback() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        XCTAssertTrue(source.contains("private var currentPlaylistSource: PlaybackSource"))
        XCTAssertTrue(source.contains("activeQueue.preferredSource"))
        XCTAssertTrue(source.contains("playback.switchPlaybackSource(source, track: track, store: store, controlSource: .nowPlaying)"))
    }

    func testPlaylistSourcePickerUsesDrumBoostAsDefaultPracticeSource() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        XCTAssertTrue(source.contains("return playlist?.defaultPlaybackSource ?? .drumBoost"))
    }

    func testPlaylistDetailExposesConfirmedPlaylistDeletion() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        XCTAssertTrue(source.contains("showingDeleteConfirmation"))
        XCTAssertTrue(source.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(source.contains(".alert(\"Delete playlist?\""))
        XCTAssertTrue(source.contains("store.deletePlaylist(playlistID)"))
        XCTAssertTrue(source.contains("route = .library"))
    }

    func testRootAndSidebarRouteToPlaylistDetail() throws {
        let root = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")
        let sidebar = try readSource("Sources/Backbeat/Views/SidebarView.swift")

        XCTAssertTrue(root.contains("case playlist(BackbeatPlaylist.ID)"))
        XCTAssertTrue(root.contains("PlaylistDetailView("))
        XCTAssertTrue(sidebar.contains("Playlists"))
        XCTAssertTrue(sidebar.contains("store.createPlaylist("))
        XCTAssertTrue(sidebar.contains("route = .playlist(playlist.id)"))
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
