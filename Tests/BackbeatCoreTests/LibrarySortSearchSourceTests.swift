import XCTest

final class LibrarySortSearchSourceTests: XCTestCase {
    func testLibraryRendersTheCoreQueryPipelineAndNeverReSortsLocally() throws {
        let source = try readSource("Sources/Backbeat/Views/LibraryView.swift")

        XCTAssertTrue(
            source.contains("LibraryTrackQuery.visibleTracks(in: store.tracks, sort: store.librarySortOrder, searchText: searchText)"),
            "The view must render the single Core filter→sort pipeline, never re-derive the order."
        )
        XCTAssertFalse(source.contains(".sorted {"), "Sorting lives in LibraryTrackQuery, not the view.")
        XCTAssertFalse(source.contains(".sorted(by:"), "Sorting lives in LibraryTrackQuery, not the view.")
        // The pipeline is O(n log n) locale-aware work: body evaluates it
        // once per pass and hands the result down as a parameter.
        XCTAssertTrue(source.contains("let visible = visibleTracks"))
        XCTAssertTrue(source.contains("content(visible: visible)"))
    }

    func testSidebarMirrorsThePersistedSortOrder() throws {
        let source = try readSource("Sources/Backbeat/Views/SidebarView.swift")

        XCTAssertTrue(
            source.contains("LibraryTrackQuery.visibleTracks(in: store.tracks, sort: store.librarySortOrder, searchText: \"\")"),
            "The sidebar must show the same persisted sort as the library (unfiltered)."
        )
        // One sort per render, shared by every row — never a per-row
        // sortedTracks evaluation inside the gesture arguments.
        XCTAssertTrue(source.contains("let sorted = sortedTracks"))
        XCTAssertTrue(source.contains("let sortedIDs = sorted.map(\\.id)"))
        XCTAssertTrue(source.contains("sorted.prefix(tracksDisplayLimit)"))
        XCTAssertFalse(source.contains("queueing: sortedTracks"), "Rows must receive the precomputed ID array, not re-sort per row.")
    }

    func testAddTracksPickerMirrorsThePersistedSort() throws {
        let source = try readSource("Sources/Backbeat/Views/PlaylistDetailView.swift")

        XCTAssertTrue(
            source.contains("List(LibraryTrackQuery.visibleTracks(in: store.tracks, sort: store.librarySortOrder, searchText: \"\"))"),
            "The add-tracks picker must not contradict the sort order the user just saw in the library."
        )
    }

    func testSortMenuWritesThroughTheGuardedStoreSetter() throws {
        let source = try readSource("Sources/Backbeat/Views/LibraryView.swift")

        XCTAssertTrue(source.contains("store.setLibrarySortOrder(LibrarySortOrder(field: $0, ascending: store.librarySortOrder.ascending))"))
        XCTAssertTrue(source.contains("store.setLibrarySortOrder(LibrarySortOrder(field: store.librarySortOrder.field, ascending: $0))"))
        XCTAssertTrue(source.contains("ForEach(LibrarySortField.allCases, id: \\.self)"))
    }

    func testSearchFieldAndControlsLiveAboveTheSelectionList() throws {
        let source = try readSource("Sources/Backbeat/Views/LibraryView.swift")

        XCTAssertTrue(source.contains("TextField(\"Search library\", text: $searchText)"))
        XCTAssertTrue(source.contains("List(selection: $selectedTrackIDs)"))
        let controlsIndex = try XCTUnwrap(source.range(of: "TextField(\"Search library\""))
        let listIndex = try XCTUnwrap(source.range(of: "List(selection: $selectedTrackIDs)"))
        XCTAssertTrue(
            controlsIndex.lowerBound < listIndex.lowerBound,
            "The search field must stay OUTSIDE (above) the selection List: a TextField inside a selection List loses first responder to row recycling on every keystroke."
        )
    }

    func testFilteredStateShowsCountAndNoMatchesRecovery() throws {
        let source = try readSource("Sources/Backbeat/Views/LibraryView.swift")

        XCTAssertTrue(source.contains("\\(visible.count) of \\(store.tracks.count) tracks"))
        XCTAssertTrue(
            source.contains("visible.filter { $0.status == .ready }.count"),
            "While filtering, the ready count must describe the filtered view, not the whole library."
        )
        XCTAssertTrue(source.contains("No tracks match"))
        XCTAssertTrue(source.contains("Clear Search"))
    }

    func testBulkDeleteOperatesOnTheEffectiveSelectionOnly() throws {
        let source = try readSource("Sources/Backbeat/Views/LibraryView.swift")

        // Effective selection = selected ∩ visible: a search typed after
        // selecting must not leave hidden tracks deletable.
        XCTAssertTrue(source.contains("visible.filter { selectedTrackIDs.contains($0.id) }"))
        XCTAssertTrue(source.contains(".onDeleteCommand"))
        XCTAssertTrue(
            source.contains("guard !selection.isEmpty else { return }"),
            "The Delete key must not arm an empty confirmation."
        )
        XCTAssertTrue(source.contains("Delete Selected (\\(effectiveSelection.count))"))
        XCTAssertTrue(source.contains("Delete \\(tracks.count) tracks, their stored source files, and any rendered files?"))
        XCTAssertTrue(source.contains("selectedTrackIDs.subtract(deletedIDs)"))
        // Post-delete selection lands on the top VISIBLE row, not the
        // persisted-first track the store's own fallback picks.
        XCTAssertTrue(source.contains("if selectionWasDeleted, let topVisible = visibleTracks.first {"))
    }

    func testListSelectionMirrorsStoreDrivenSelectionChanges() throws {
        let source = try readSource("Sources/Backbeat/Views/LibraryView.swift")

        // Store-driven selection (queue auto-advance, sidebar click) must
        // reflect back into the list highlight; a lone one-way List→store
        // sync leaves the two surfaces contradicting each other.
        XCTAssertTrue(source.contains(".onChange(of: store.selectedTrackID)"))
        XCTAssertTrue(
            source.contains("if selectedTrackIDs.count <= 1, let newID {"),
            "The mirror must never clobber an in-progress multi-selection."
        )
        XCTAssertTrue(
            source.contains("if selectedTrackIDs.isEmpty, let selectedID = store.selectedTrackID {"),
            "Re-entering the library must reseed the highlight from the store."
        )
        // Tile hue seeds from the persisted position so it is stable across
        // sorts and consistent with the Player/mini-player.
        XCTAssertTrue(source.contains("store.tracks.firstIndex(where: { $0.id == track.id })"))
    }

    func testLibraryDoubleClickQueuesTheVisibleOrder() throws {
        let source = try readSource("Sources/Backbeat/Views/LibraryView.swift")

        XCTAssertTrue(source.contains("rowActions.playFromStart(track, queueing: visibleTrackIDs)"))
        XCTAssertTrue(
            source.contains("selectedTrackIDs.contains(track.id) ? BackbeatStyle.panelRaised : BackbeatStyle.panel"),
            "Row highlight follows the List selection now, not store.selectedTrackID."
        )
    }

    func testRootBulkDeleteKeepsCancelBeforeDeleteAndRethrowsFirstError() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("func deleteTracks(_ tracksToDelete: [BackbeatTrack]) throws"))
        // The existing ordering pin (cancel before delete) is asserted by
        // BackbeatRootSourceTests; here pin the batch contract.
        XCTAssertTrue(source.contains("firstError = firstError ?? error"))
        XCTAssertTrue(source.contains("if let firstError {"))
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
