import XCTest
@testable import BackbeatCore

final class LibraryTrackQueryTests: XCTestCase {
    // MARK: - Upgrade identity (the invariant the default sort must hold)

    func testDefaultSortOverAllLegacyTracksReturnsInputOrderUnchanged() {
        // Every pre-upgrade track decodes dateAdded == nil; the default sort
        // (dateAdded ascending) must reproduce the persisted array order
        // exactly, so an upgrading user sees zero reordering.
        let tracks = [
            track(title: "Zebra"),
            track(title: "Apple", artist: "Cream"),
            track(title: "Mango", artist: "Adele"),
            track(title: "apple"),
        ]

        let visible = LibraryTrackQuery.visibleTracks(in: tracks, sort: .default, searchText: "")

        XCTAssertEqual(visible.map(\.title), ["Zebra", "Apple", "Mango", "apple"])
    }

    func testDefaultSortPlacesDatedImportsAfterLegacyTracksInDateOrder() {
        let legacyA = track(title: "Legacy A")
        let legacyB = track(title: "Legacy B")
        let newer = track(title: "Newer", dateAdded: Date(timeIntervalSince1970: 2_000))
        let older = track(title: "Older", dateAdded: Date(timeIntervalSince1970: 1_000))
        let tracks = [legacyA, newer, legacyB, older]

        let visible = LibraryTrackQuery.visibleTracks(in: tracks, sort: .default, searchText: "")

        XCTAssertEqual(visible.map(\.title), ["Legacy A", "Legacy B", "Older", "Newer"])
    }

    func testDateAddedDescendingPutsNewestFirstAndLegacyLast() {
        let legacy = track(title: "Legacy")
        let newer = track(title: "Newer", dateAdded: Date(timeIntervalSince1970: 2_000))
        let older = track(title: "Older", dateAdded: Date(timeIntervalSince1970: 1_000))
        let tracks = [legacy, older, newer]

        let visible = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .dateAdded, ascending: false),
            searchText: ""
        )

        XCTAssertEqual(visible.map(\.title), ["Newer", "Older", "Legacy"])
    }

    // MARK: - Sort fields

    func testTitleSortIsLocaleAwareAndCaseInsensitive() {
        let tracks = [
            track(title: "cream"),
            track(title: "Adele"),
            track(title: "Beck"),
        ]

        let ascending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .title, ascending: true),
            searchText: ""
        )
        let descending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .title, ascending: false),
            searchText: ""
        )

        XCTAssertEqual(ascending.map(\.title), ["Adele", "Beck", "cream"])
        XCTAssertEqual(descending.map(\.title), ["cream", "Beck", "Adele"])
    }

    func testArtistSortSinksMissingArtistInBothDirections() {
        let tagged = track(title: "Tagged", artist: "Beck")
        let untagged = track(title: "Untagged")
        let alsoTagged = track(title: "Also", artist: "Adele")
        let tracks = [untagged, tagged, alsoTagged]

        let ascending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .artist, ascending: true),
            searchText: ""
        )
        let descending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .artist, ascending: false),
            searchText: ""
        )

        XCTAssertEqual(ascending.map(\.title), ["Also", "Tagged", "Untagged"])
        XCTAssertEqual(descending.map(\.title), ["Tagged", "Also", "Untagged"])
    }

    func testArtistSortBreaksTiesByTitleInBothDirections() {
        let second = track(title: "Bravo", artist: "Same Band")
        let first = track(title: "Alpha", artist: "Same Band")
        let tracks = [second, first]

        let ascending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .artist, ascending: true),
            searchText: ""
        )
        let descending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .artist, ascending: false),
            searchText: ""
        )

        // Direction flips the artist key only; the title tie-break stays
        // ascending, like the original-position tie-break.
        XCTAssertEqual(ascending.map(\.title), ["Alpha", "Bravo"])
        XCTAssertEqual(descending.map(\.title), ["Alpha", "Bravo"])
    }

    func testAlbumSortSinksMissingAlbumAndBreaksTiesByTitle() {
        let noAlbum = track(title: "Single")
        let bSide = track(title: "Zulu", album: "Anthology")
        let aSide = track(title: "Alpha", album: "Anthology")
        let other = track(title: "Other", album: "Bootlegs")
        let tracks = [noAlbum, bSide, other, aSide]

        let visible = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .album, ascending: true),
            searchText: ""
        )

        XCTAssertEqual(visible.map(\.title), ["Alpha", "Zulu", "Other", "Single"])
    }

    func testDurationSortOrdersNumericallyAndKeepsEqualDurationsStable() {
        let long = track(title: "Long", duration: 300)
        let shortA = track(title: "Short A", duration: 90)
        let shortB = track(title: "Short B", duration: 90)
        let tracks = [long, shortA, shortB]

        let ascending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .duration, ascending: true),
            searchText: ""
        )
        let descending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .duration, ascending: false),
            searchText: ""
        )

        XCTAssertEqual(ascending.map(\.title), ["Short A", "Short B", "Long"])
        XCTAssertEqual(descending.map(\.title), ["Long", "Short A", "Short B"])
    }

    func testDurationSortToleratesNaNWithoutViolatingStrictWeakOrdering() {
        // NaN must coalesce into the total order (as -infinity), not fall to
        // the index tie-break while numeric pairs still compare — that shape
        // permits comparator cycles, which is documented UB in sorted(by:).
        let nan = track(title: "NaN", duration: .nan)
        let short = track(title: "Short", duration: 90)
        let long = track(title: "Long", duration: 300)
        let tracks = [long, nan, short]

        let ascending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .duration, ascending: true),
            searchText: ""
        )
        let descending = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .duration, ascending: false),
            searchText: ""
        )

        XCTAssertEqual(ascending.map(\.title), ["NaN", "Short", "Long"])
        XCTAssertEqual(descending.map(\.title), ["Long", "Short", "NaN"])
    }

    // MARK: - Search filter

    func testSearchMatchesTitleCaseInsensitively() {
        let tracks = [track(title: "Moby Dick"), track(title: "Kashmir")]

        let visible = LibraryTrackQuery.visibleTracks(in: tracks, sort: .default, searchText: "moby")

        XCTAssertEqual(visible.map(\.title), ["Moby Dick"])
    }

    func testSearchMatchesDiacriticInsensitively() {
        let tracks = [track(title: "Jóga", artist: "Björk"), track(title: "Angel")]

        XCTAssertEqual(
            LibraryTrackQuery.visibleTracks(in: tracks, sort: .default, searchText: "bjork").map(\.title),
            ["Jóga"]
        )
        XCTAssertEqual(
            LibraryTrackQuery.visibleTracks(in: tracks, sort: .default, searchText: "joga").map(\.title),
            ["Jóga"]
        )
    }

    func testSearchMatchesAlbum() {
        let tracks = [
            track(title: "One", album: "Abbey Road"),
            track(title: "Two", album: "Let It Be"),
        ]

        let visible = LibraryTrackQuery.visibleTracks(in: tracks, sort: .default, searchText: "abbey")

        XCTAssertEqual(visible.map(\.title), ["One"])
    }

    func testSearchMatchesDisplayedFilenameFallbackWhenArtistMissing() {
        // The artist cell displays the source filename when the tag is
        // missing; search must find what the row shows.
        let untagged = track(title: "Take 3", sourcePath: "/tmp/river-session.m4a")
        let tagged = track(title: "Take 4", artist: "Studio Band")

        let visible = LibraryTrackQuery.visibleTracks(
            in: [untagged, tagged],
            sort: .default,
            searchText: "river"
        )

        XCTAssertEqual(visible.map(\.title), ["Take 3"])
    }

    func testWhitespaceOnlyQueryDoesNotFilter() {
        let tracks = [track(title: "One"), track(title: "Two")]

        let visible = LibraryTrackQuery.visibleTracks(in: tracks, sort: .default, searchText: "   ")

        XCTAssertEqual(visible.count, 2)
    }

    func testQueryIsTrimmedBeforeMatching() {
        let tracks = [track(title: "Kashmir"), track(title: "Angel")]

        let visible = LibraryTrackQuery.visibleTracks(in: tracks, sort: .default, searchText: "  kashmir  ")

        XCTAssertEqual(visible.map(\.title), ["Kashmir"])
    }

    func testFilterAndSortCompose() {
        let tracks = [
            track(title: "Blue Train", artist: "Coltrane", duration: 300),
            track(title: "Blue in Green", artist: "Davis", duration: 200),
            track(title: "So What", artist: "Davis", duration: 100),
        ]

        let visible = LibraryTrackQuery.visibleTracks(
            in: tracks,
            sort: LibrarySortOrder(field: .duration, ascending: true),
            searchText: "blue"
        )

        XCTAssertEqual(visible.map(\.title), ["Blue in Green", "Blue Train"])
    }

    // MARK: - Fixtures

    private func track(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval = 180,
        dateAdded: Date? = nil,
        sourcePath: String? = nil
    ) -> BackbeatTrack {
        BackbeatTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            status: .ready,
            sourceURL: URL(fileURLWithPath: sourcePath ?? "/tmp/\(title).m4a"),
            dateAdded: dateAdded
        )
    }
}
