import BackbeatCore
import SwiftUI

struct SidebarView: View {
    let store: LibraryStore
    let playback: AudioPlaybackController
    @Binding var route: BackbeatRoute
    let onImportTrack: () -> Void
    let onImportFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 18)

            VStack(spacing: 8) {
                Button {
                    onImportTrack()
                } label: {
                    Label("Import Track", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BackbeatButtonStyle(variant: .primary))

                Button {
                    onImportFolder()
                } label: {
                    Label("Import Folder", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BackbeatButtonStyle(variant: .ghost))
            }
            .padding(.horizontal, 16)

            Button {
                route = .library
            } label: {
                HStack {
                    Label("Library", systemImage: "list.bullet")
                    Spacer()
                    Text("\(store.tracks.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(BackbeatStyle.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(BackbeatButtonStyle(variant: route == .library ? .primary : .ghost))
            .padding(.horizontal, 12)
            .padding(.top, 18)

            // Playlists (with its own overflow cap) and the divider stay pinned
            // so a long library can never scroll them out of view; only the
            // track list scrolls, and it claims the remaining height.
            playlistsSection
            sectionDivider
            tracksSection
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 268)
        .background(BackbeatStyle.sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(BackbeatStyle.border)
                .frame(width: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            brandMark
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Backline Boost")
                    .font(.system(size: 15, weight: .black))
                Text("PRACTICE PLAYER")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(BackbeatStyle.mutedText)
            }
        }
    }

    @ViewBuilder
    private var brandMark: some View {
        if BackbeatBrandIcon.image != nil {
            // The app icon is a self-contained dark squircle, so it stands as
            // the logo on its own (near-full, clear background).
            AppIconBadge(size: 34, cornerRadius: 9, insetRatio: 0.04, background: .clear)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [BackbeatStyle.primary, BackbeatStyle.primaryDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(BackbeatStyle.appBackground)
                }
        }
    }

    // Playlists are capped in the sidebar so a long track list can't bury them;
    // the rest stay one tap away behind "Show N more".
    private var playlistDisplayLimit: Int { 3 }

    private var visiblePlaylists: [BackbeatPlaylist] {
        guard !store.isPlaylistOverflowExpanded else { return store.playlists }
        return Array(store.playlists.prefix(playlistDisplayLimit))
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                sectionToggle(
                    title: "Playlists",
                    count: store.playlists.count,
                    isCollapsed: store.isPlaylistsSectionCollapsed
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.isPlaylistsSectionCollapsed.toggle()
                    }
                }
                Button {
                    let playlist = store.createPlaylist()
                    route = .playlist(playlist.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BackbeatStyle.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Playlist")
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if !store.isPlaylistsSectionCollapsed {
                if store.playlists.isEmpty {
                    Text("No playlists yet")
                        .font(.system(size: 12))
                        .foregroundStyle(BackbeatStyle.mutedText)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 6)
                } else {
                    VStack(spacing: 2) {
                        ForEach(visiblePlaylists) { playlist in
                            playlistRow(playlist)
                        }
                    }
                    .padding(.horizontal, 12)

                    if store.playlists.count > playlistDisplayLimit {
                        showMorePlaylistsButton
                    }
                }
            }
        }
    }

    private var showMorePlaylistsButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                store.isPlaylistOverflowExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(store.isPlaylistOverflowExpanded ? 180 : 0))
                Text(store.isPlaylistOverflowExpanded
                    ? "Show less"
                    : "Show \(store.playlists.count - playlistDisplayLimit) more")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(BackbeatStyle.mutedText)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ playlist: BackbeatPlaylist) -> some View {
        Button {
            store.selectedPlaylistID = playlist.id
            route = .playlist(playlist.id)
        } label: {
            HStack {
                Image(systemName: "music.note.list")
                Text(playlist.name)
                    .lineLimit(1)
                Spacer()
                Text("\(playlist.trackIDs.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(BackbeatStyle.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                store.selectedPlaylistID == playlist.id ? BackbeatStyle.panelRaised : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    // Tracks mirror the Playlists overflow: a short, non-scrolling preview by
    // default, expanding into a scrollable region that holds the rest.
    private var tracksDisplayLimit: Int { 3 }

    // The sidebar mirrors the library's persisted sort so the two surfaces
    // never show conflicting orders. O(n log n) — evaluate once per render
    // (trackRows) and pass down, never per row.
    private var sortedTracks: [BackbeatTrack] {
        LibraryTrackQuery.visibleTracks(in: store.tracks, sort: store.librarySortOrder, searchText: "")
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionToggle(
                title: "Tracks",
                count: store.tracks.count,
                isCollapsed: store.isTracksSectionCollapsed
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.isTracksSectionCollapsed.toggle()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if !store.isTracksSectionCollapsed {
                let hasOverflow = store.tracks.count > tracksDisplayLimit
                if hasOverflow && store.isTracksOverflowExpanded {
                    // Expanded: the ScrollView wraps only the rows and takes the
                    // sidebar's remaining height, so the pinned sections above
                    // never clip and "Show less" stays anchored at the bottom.
                    ScrollView {
                        trackRows
                            .padding(.bottom, 12)
                    }
                    showMoreTracksButton
                } else {
                    trackRows
                        .padding(.bottom, hasOverflow ? 4 : 12)
                    if hasOverflow {
                        showMoreTracksButton
                    }
                }
            }
        }
    }

    private var trackRows: some View {
        let sorted = sortedTracks
        let sortedIDs = sorted.map(\.id)
        let rows = store.isTracksOverflowExpanded ? sorted : Array(sorted.prefix(tracksDisplayLimit))
        return LazyVStack(spacing: 4) {
            ForEach(rows) { track in
                sidebarRow(track, queueing: sortedIDs)
            }
        }
        .padding(.horizontal, 10)
    }

    private var showMoreTracksButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                store.isTracksOverflowExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(store.isTracksOverflowExpanded ? 180 : 0))
                Text(store.isTracksOverflowExpanded
                    ? "Show less"
                    : "Show \(store.tracks.count - tracksDisplayLimit) more")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(BackbeatStyle.mutedText)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(BackbeatStyle.border)
            .frame(height: 1)
            .opacity(0.7)
            .padding(.horizontal, 16)
            .padding(.top, 10)
    }

    // A section header that collapses its body on tap. The item count stays
    // visible so a collapsed section still says what's inside; the chevron
    // rotates to point right when collapsed.
    private func sectionToggle(
        title: String,
        count: Int,
        isCollapsed: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(BackbeatStyle.secondaryText)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .foregroundStyle(BackbeatStyle.mutedText)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(BackbeatStyle.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items, \(isCollapsed ? "collapsed" : "expanded")")
        .accessibilityAddTraits(.isButton)
    }

    private func sidebarRow(_ track: BackbeatTrack, queueing sortedIDs: [BackbeatTrack.ID]) -> some View {
        HStack(spacing: 10) {
            // Tile hue seeds from the persisted position — stable across sort
            // changes and consistent with the library, Player, and mini-player.
            TrackTile(track: track, index: store.tracks.firstIndex(where: { $0.id == track.id }) ?? 0, size: 30, fontSize: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist ?? track.sourceURL.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(BackbeatStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            StatusDot(status: track.status)
            Text(BackbeatFormat.duration(track.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BackbeatStyle.mutedText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(track), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        // Double-click queues the FULL sorted library from this track (not
        // the prefix-limited sidebar slice) — same hybrid as the library view.
        .gesture(rowActions.tapGesture(for: track, queueing: sortedIDs))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.artist ?? "Unknown Artist"), \(BackbeatFormat.duration(track.duration))")
        .accessibilityAddTraits(.isButton)
    }

    private func rowBackground(_ track: BackbeatTrack) -> Color {
        store.selectedTrackID == track.id ? BackbeatStyle.panelRaised : .clear
    }

    private var rowActions: TrackRowActions {
        TrackRowActions(store: store, playback: playback, route: $route)
    }
}
