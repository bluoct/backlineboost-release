import XCTest

/// The sidebar reorganization: Playlists sits above Tracks, both sections
/// collapse from their headers, and Playlists is capped with a "show more"
/// overflow so a long track list can never bury it.
final class SidebarSectionsSourceTests: XCTestCase {
    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPlaylistsSectionRendersAboveTracksSection() throws {
        let source = try readSource("Sources/Backbeat/Views/SidebarView.swift")
        // The scrolling body composes playlists, a divider, then tracks.
        let playlists = try XCTUnwrap(source.range(of: "playlistsSection"))
        let divider = try XCTUnwrap(source.range(of: "sectionDivider"))
        let tracks = try XCTUnwrap(source.range(of: "tracksSection"))
        XCTAssertLessThan(playlists.lowerBound, divider.lowerBound)
        XCTAssertLessThan(divider.lowerBound, tracks.lowerBound)
    }

    func testBothSectionsCollapseFromTheirHeaders() throws {
        let source = try readSource("Sources/Backbeat/Views/SidebarView.swift")
        XCTAssertTrue(source.contains("store.isPlaylistsSectionCollapsed.toggle()"))
        XCTAssertTrue(source.contains("store.isTracksSectionCollapsed.toggle()"))
        XCTAssertTrue(source.contains("if !store.isPlaylistsSectionCollapsed"))
        XCTAssertTrue(source.contains("if !store.isTracksSectionCollapsed"))
        // A rotating chevron signals the collapse affordance on each header.
        XCTAssertTrue(source.contains("systemName: \"chevron.down\""))
        XCTAssertTrue(source.contains("rotationEffect(.degrees(isCollapsed ? -90 : 0))"))
    }

    func testPlaylistsAreCappedWithShowMoreOverflow() throws {
        let source = try readSource("Sources/Backbeat/Views/SidebarView.swift")
        XCTAssertTrue(source.contains("playlistDisplayLimit"))
        XCTAssertTrue(source.contains("prefix(playlistDisplayLimit)"))
        XCTAssertTrue(source.contains("store.playlists.count > playlistDisplayLimit"))
        XCTAssertTrue(source.contains("store.isPlaylistOverflowExpanded.toggle()"))
        XCTAssertTrue(source.contains("Show less"))
    }

    func testHeadersKeepItemCountVisible() throws {
        let source = try readSource("Sources/Backbeat/Views/SidebarView.swift")
        // Collapsed sections still say what's inside, so the count binds to the header.
        XCTAssertTrue(source.contains("count: store.playlists.count"))
        XCTAssertTrue(source.contains("count: store.tracks.count"))
    }

    func testTracksAreCappedAndExpandIntoAScrollRegion() throws {
        let source = try readSource("Sources/Backbeat/Views/SidebarView.swift")
        // Tracks default to a short preview and expand into an overflow scroll,
        // mirroring the Playlists cap.
        XCTAssertTrue(source.contains("tracksDisplayLimit"))
        XCTAssertTrue(source.contains("prefix(tracksDisplayLimit)"))
        XCTAssertTrue(source.contains("store.tracks.count > tracksDisplayLimit"))
        XCTAssertTrue(source.contains("store.isTracksOverflowExpanded.toggle()"))
    }

    func testOnlyTheTrackListScrollsWhilePlaylistsStayPinned() throws {
        let source = try readSource("Sources/Backbeat/Views/SidebarView.swift")
        // The sidebar body no longer wraps playlists + tracks in one ScrollView.
        // The single ScrollView now lives inside the tracks section (defined
        // below `body`), so Playlists stays pinned above a scrolling track list…
        let scroll = try XCTUnwrap(source.range(of: "ScrollView"))
        let tracksDef = try XCTUnwrap(source.range(of: "private var tracksSection"))
        XCTAssertGreaterThan(scroll.lowerBound, tracksDef.lowerBound)
        // …and that scroll region takes the sidebar's remaining height.
        XCTAssertTrue(source.contains(".frame(maxHeight: .infinity, alignment: .top)"))
    }
}
