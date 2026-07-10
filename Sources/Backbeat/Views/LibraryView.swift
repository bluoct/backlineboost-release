import BackbeatCore
import SwiftUI

struct LibraryView: View {
    let store: LibraryStore
    let playback: AudioPlaybackController
    let renderQueue: RenderQueueCoordinator
    @Binding var route: BackbeatRoute
    let onImportTrack: () -> Void
    let onImportFolder: () -> Void
    let onDeleteTracks: ([BackbeatTrack]) throws -> Void
    @State private var searchText = ""
    @State private var selectedTrackIDs: Set<BackbeatTrack.ID> = []
    @State private var deletionCandidates: [BackbeatTrack]?
    @State private var deleteErrorMessage: String?

    // The pipeline is O(n log n) locale-aware work: body evaluates it ONCE
    // per pass and hands the result down — helpers take it as a parameter
    // and must never call this property themselves.
    private var visibleTracks: [BackbeatTrack] {
        LibraryTrackQuery.visibleTracks(in: store.tracks, sort: store.librarySortOrder, searchText: searchText)
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let visible = visibleTracks
        content(visible: visible)
            .alert(deleteAlertTitle, isPresented: deleteConfirmationBinding, presenting: deletionCandidates) { tracks in
                Button("No", role: .cancel) {
                    deletionCandidates = nil
                }
                Button("Yes", role: .destructive) {
                    confirmDelete(tracks)
                }
            } message: { tracks in
                Text(deleteAlertMessage(for: tracks))
            }
            .alert("Delete failed", isPresented: deleteFailedBinding) {
                Button("OK", role: .cancel) {
                    deleteErrorMessage = nil
                }
            } message: {
                Text(deleteErrorMessage ?? "")
            }
    }

    @ViewBuilder
    private func content(visible: [BackbeatTrack]) -> some View {
        if store.tracks.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header(visible: visible)
                    emptyState
                }
                .padding(.horizontal, 40)
                .padding(.top, 32)
                .padding(.bottom, 70)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        } else {
            // The header, search field, and sort menu stay fixed above the
            // list: a TextField inside a selection List loses first responder
            // to row recycling on every keystroke (each keystroke mutates the
            // list's own data), and the field would scroll away exactly while
            // the user is filtering.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 28) {
                    header(visible: visible)
                    VStack(alignment: .leading, spacing: 14) {
                        controlsRow(visible: visible)
                        columnHeader
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 32)
                .frame(maxWidth: 1100, alignment: .leading)

                if visible.isEmpty {
                    noMatchesState
                        .padding(.horizontal, 40)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 1100, alignment: .leading)
                    Spacer(minLength: 0)
                } else {
                    trackList(visible: visible)
                }
            }
        }
    }

    private func header(visible: [BackbeatTrack]) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Library")
                    .font(.system(size: 30, weight: .black))
                Text(countLine(visible: visible))
                    .font(.system(size: 13))
                    .foregroundStyle(BackbeatStyle.secondaryText)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    onImportTrack()
                } label: {
                    Label("Import Track", systemImage: "plus")
                }
                .buttonStyle(BackbeatButtonStyle(variant: .primary))

                Button {
                    onImportFolder()
                } label: {
                    Label("Import Folder", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(BackbeatButtonStyle(variant: .ghost))
            }
        }
    }

    private func countLine(visible: [BackbeatTrack]) -> String {
        if isFiltering {
            // Both numbers describe the filtered view — mixing the filtered
            // track count with a library-wide ready count reads as nonsense.
            let visibleReady = visible.filter { $0.status == .ready }.count
            return "\(visible.count) of \(store.tracks.count) tracks · \(visibleReady) ready to play"
        }
        return "\(store.tracks.count) tracks · \(readyCount) ready to play"
    }

    private func controlsRow(visible: [BackbeatTrack]) -> some View {
        let effectiveSelection = visible.filter { selectedTrackIDs.contains($0.id) }
        return HStack(spacing: 10) {
            searchField

            Spacer()

            if effectiveSelection.count > 1 {
                Button {
                    deletionCandidates = effectiveSelection
                } label: {
                    Label("Delete Selected (\(effectiveSelection.count))", systemImage: "trash")
                }
                .buttonStyle(BackbeatButtonStyle(variant: .ghost))
            }

            sortMenu
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(BackbeatStyle.mutedText)
            TextField("Search library", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BackbeatStyle.mutedText)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 260)
        .background(BackbeatStyle.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(BackbeatStyle.border, lineWidth: 1)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: sortFieldBinding) {
                ForEach(LibrarySortField.allCases, id: \.self) { field in
                    Text(field.displayLabel).tag(field)
                }
            }
            Divider()
            Picker("Direction", selection: sortAscendingBinding) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        } label: {
            Label(
                "Sort: \(store.librarySortOrder.field.displayLabel) \(store.librarySortOrder.ascending ? "↑" : "↓")",
                systemImage: "arrow.up.arrow.down"
            )
            .font(.system(size: 12, weight: .semibold))
        }
        .fixedSize()
        .accessibilityLabel("Sort library")
    }

    private var sortFieldBinding: Binding<LibrarySortField> {
        Binding(
            get: { store.librarySortOrder.field },
            set: { store.setLibrarySortOrder(LibrarySortOrder(field: $0, ascending: store.librarySortOrder.ascending)) }
        )
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(
            get: { store.librarySortOrder.ascending },
            set: { store.setLibrarySortOrder(LibrarySortOrder(field: store.librarySortOrder.field, ascending: $0)) }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            AppIconBadge(size: 58, cornerRadius: 12, fallbackSystemImage: "music.note")

            VStack(spacing: 5) {
                Text("No tracks yet")
                    .font(.system(size: 18, weight: .bold))
                Text("Add a local audio file to create a boosted-drums practice render.")
                    .font(.system(size: 13))
                    .foregroundStyle(BackbeatStyle.secondaryText)
            }

            HStack(spacing: 10) {
                Button {
                    onImportTrack()
                } label: {
                    Label("Import Track", systemImage: "plus")
                }
                .buttonStyle(BackbeatButtonStyle(variant: .primary))

                Button {
                    onImportFolder()
                } label: {
                    Label("Import Folder", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(BackbeatButtonStyle(variant: .ghost))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 86)
        .padding(.horizontal, 24)
        .background(BackbeatStyle.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BackbeatStyle.border, lineWidth: 1)
        }
    }

    private var noMatchesState: some View {
        VStack(spacing: 10) {
            Text("No tracks match \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                .font(.system(size: 14, weight: .semibold))
            Button("Clear Search") {
                searchText = ""
            }
            .buttonStyle(BackbeatButtonStyle(variant: .ghost))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .background(BackbeatStyle.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BackbeatStyle.border, lineWidth: 1)
        }
    }

    private var columnHeader: some View {
        HStack {
            Text("Track").frame(maxWidth: .infinity, alignment: .leading)
            Text("Length").frame(width: 80, alignment: .leading)
            Text("Status").frame(width: 190, alignment: .leading)
            Text("Version").frame(width: 150, alignment: .leading)
            Text("").frame(width: 130)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .textCase(.uppercase)
        .tracking(1)
        .foregroundStyle(BackbeatStyle.mutedText)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BackbeatStyle.border).frame(height: 1)
        }
    }

    private func trackList(visible: [BackbeatTrack]) -> some View {
        let visibleTrackIDs = visible.map(\.id)
        return List(selection: $selectedTrackIDs) {
            ForEach(visible) { track in
                trackRow(track, queueing: visibleTrackIDs)
                    .frame(maxWidth: 1020, alignment: .leading)
                    .tag(track.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 3, leading: 40, bottom: 3, trailing: 40))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            let selection = visible.filter { selectedTrackIDs.contains($0.id) }
            guard !selection.isEmpty else { return }
            deletionCandidates = selection
        }
        .onAppear {
            // @State resets when the route recreates this view; reseed the
            // highlight from the store so re-entry doesn't show nothing.
            if selectedTrackIDs.isEmpty, let selectedID = store.selectedTrackID {
                selectedTrackIDs = [selectedID]
            }
        }
        .onChange(of: selectedTrackIDs) { _, newSelection in
            // Keep the Player's detail track following a single selection;
            // multi-selections leave it where it was.
            if newSelection.count == 1, let onlyID = newSelection.first {
                store.selectTrack(onlyID)
            }
        }
        .onChange(of: store.selectedTrackID) { _, newID in
            // Mirror store-driven selection (queue auto-advance, sidebar
            // click) back into the list highlight — but never clobber an
            // in-progress multi-selection.
            if selectedTrackIDs.count <= 1, let newID {
                selectedTrackIDs = [newID]
            }
        }
    }

    private var readyCount: Int {
        store.tracks.filter { $0.status == .ready }.count
    }

    // Tile hue is seeded by the track's persisted position — stable across
    // sort/filter changes and consistent with the Player and mini-player,
    // which derive theirs from the same persisted order.
    private func tileIndex(for track: BackbeatTrack) -> Int {
        store.tracks.firstIndex(where: { $0.id == track.id }) ?? 0
    }

    private func trackRow(_ track: BackbeatTrack, queueing visibleTrackIDs: [BackbeatTrack.ID]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 13) {
                TrackTile(track: track, index: tileIndex(for: track), size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Text(track.artist ?? track.sourceURL.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(BackbeatStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Single-click selection belongs to the List; only the
            // double-click play gesture lives on the row content.
            .gesture(TapGesture(count: 2).onEnded {
                rowActions.playFromStart(track, queueing: visibleTrackIDs)
            })
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(track.title), \(track.artist ?? "Unknown Artist"), \(BackbeatFormat.duration(track.duration))")
            .accessibilityAddTraits(.isButton)

            Text(BackbeatFormat.duration(track.duration))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(BackbeatStyle.secondaryText)
                .frame(width: 80, alignment: .leading)

            HStack(spacing: 8) {
                StatusDot(status: track.status)
                Text(statusText(for: track))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(BackbeatStyle.statusColor(track.status))
            .frame(width: 190, alignment: .leading)

            Text(track.activeRender(for: .boostedDrums) == nil ? "—" : RenderVariant.boostedDrums.displayLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(track.activeRender(for: .boostedDrums) == nil ? BackbeatStyle.mutedText : BackbeatStyle.ready)
                .frame(width: 150, alignment: .leading)

            HStack(spacing: 6) {
                if track.status == .renderFailed {
                    Button {
                        renderQueue.enqueue(track.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(BackbeatButtonStyle(variant: .icon))
                    .accessibilityLabel("Retry render")
                    .help("Retry render")
                }

                Button {
                    rowActions.open(track)
                } label: {
                    Image(systemName: track.status == .ready ? "play.fill" : "chevron.right")
                }
                .buttonStyle(BackbeatButtonStyle(variant: track.status == .ready ? .primary : .icon))

                Button {
                    deletionCandidates = [track]
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(BackbeatButtonStyle(variant: .icon))
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(selectedTrackIDs.contains(track.id) ? BackbeatStyle.panelRaised : BackbeatStyle.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selectedTrackIDs.contains(track.id) ? BackbeatStyle.border.opacity(1) : BackbeatStyle.border.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var deleteAlertTitle: String {
        let count = deletionCandidates?.count ?? 0
        return count > 1 ? "Delete \(count) tracks?" : "Delete track?"
    }

    private func deleteAlertMessage(for tracks: [BackbeatTrack]) -> String {
        if tracks.count == 1, let track = tracks.first {
            return "Delete \(track.title), its stored source file, and any boosted-drums or drumless renders?"
        }
        return "Delete \(tracks.count) tracks, their stored source files, and any rendered files?"
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletionCandidates != nil },
            set: { if !$0 { deletionCandidates = nil } }
        )
    }

    private var deleteFailedBinding: Binding<Bool> {
        Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )
    }

    private func confirmDelete(_ tracks: [BackbeatTrack]) {
        let deletedIDs = Set(tracks.map(\.id))
        let selectionWasDeleted = store.selectedTrackID.map(deletedIDs.contains) ?? false
        do {
            try onDeleteTracks(tracks)
            deletionCandidates = nil
        } catch {
            deletionCandidates = nil
            deleteErrorMessage = error.localizedDescription
        }
        selectedTrackIDs.subtract(deletedIDs)
        // The store's own fallback re-selects the persisted-first track,
        // which under a sort is an arbitrary middle row; re-point at the top
        // of the visible list instead.
        if selectionWasDeleted, let topVisible = visibleTracks.first {
            store.selectTrack(topVisible.id)
        }
    }

    private func statusText(for track: BackbeatTrack) -> String {
        if renderQueue.activeTrackID == track.id {
            return renderQueue.activeProgress.display?.title ?? "Rendering"
        }
        if let position = renderQueue.queuePosition(of: track.id) {
            return "Waiting to render (#\(position))"
        }
        return track.status.displayLabel
    }

    private var rowActions: TrackRowActions {
        TrackRowActions(store: store, playback: playback, route: $route)
    }
}
