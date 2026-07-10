import BackbeatCore
import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: BackbeatPlaylist.ID
    let store: LibraryStore
    let playback: AudioPlaybackController
    @Binding var route: BackbeatRoute
    @State private var showingAddTracks = false
    @State private var showingDeleteConfirmation = false
    @State private var selectedTrackIDs = Set<BackbeatTrack.ID>()

    private var playlist: BackbeatPlaylist? {
        store.playlist(id: playlistID)
    }

    private var playlistTracks: [BackbeatTrack] {
        guard let playlist else { return [] }
        return playlist.trackIDs.compactMap { store.track(id: $0) }
    }

    private var currentPlaylistSource: PlaybackSource {
        if let activeQueue = store.activeQueue, activeQueue.playlistID == playlistID {
            return activeQueue.preferredSource
        }
        return playlist?.defaultPlaybackSource ?? .drumBoost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            sourceAndPlayControls
            ScrollView {
                trackList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingAddTracks) {
            addTracksSheet
        }
        .alert("Delete playlist?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deletePlaylist()
            }
        } message: {
            Text("Delete \(playlist?.name ?? "this playlist")? Tracks and renders stay in your library.")
        }
    }

    private var header: some View {
        let tracks = playlistTracks
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Playlist name", text: Binding(
                get: { playlist?.name ?? "" },
                set: { store.renamePlaylist(playlistID, to: $0) }
            ))
            .font(.system(size: 34, weight: .black))
            .textFieldStyle(.plain)

            Text("\(tracks.count) tracks · \(BackbeatFormat.duration(tracks.reduce(0) { $0 + $1.duration }))")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(BackbeatStyle.secondaryText)
        }
    }

    private var sourceAndPlayControls: some View {
        HStack(spacing: 14) {
            PlaybackSourcePicker(selection: Binding(
                get: { currentPlaylistSource },
                set: { setPlaylistSource($0) }
            ))
            .frame(width: 360)

            PlaybackCircleButton(
                systemName: "play.fill",
                size: 50,
                iconSize: 18,
                accessibilityLabel: "Play playlist"
            ) {
                playPlaylist()
            }

            Button {
                selectedTrackIDs = []
                showingAddTracks = true
            } label: {
                Label("Add Tracks", systemImage: "plus")
            }
            .buttonStyle(BackbeatButtonStyle(variant: .ghost))

            Button {
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(BackbeatButtonStyle(variant: .icon))
            .accessibilityLabel("Delete playlist")
            .help("Delete playlist")
            .disabled(playlist == nil)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        let tracks = playlistTracks
        if tracks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("No tracks")
                    .font(.system(size: 18, weight: .bold))
                Text("Add tracks from your library to build this playlist.")
                    .foregroundStyle(BackbeatStyle.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 30)
        } else {
            // One index map per body instead of an O(n) scan per row.
            let trackIndexByID = Dictionary(
                store.tracks.enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            VStack(spacing: 0) {
                ForEach(tracks) { track in
                    playlistTrackRow(track, index: trackIndexByID[track.id] ?? 0)
                    Divider().overlay(BackbeatStyle.border)
                }
            }
        }
    }

    private func playlistTrackRow(_ track: BackbeatTrack, index: Int) -> some View {
        HStack(spacing: 12) {
            TrackTile(
                track: track,
                index: index,
                size: 44,
                fontSize: 16
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(track.artist ?? "Unknown Artist")
                    .font(.system(size: 11))
                    .foregroundStyle(BackbeatStyle.secondaryText)
            }
            Spacer()
            Text(BackbeatFormat.duration(track.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BackbeatStyle.secondaryText)
            Button {
                store.removeTrack(track.id, from: playlistID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            isNowPlaying(track) ? BackbeatStyle.primary.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isNowPlaying(track) ? BackbeatStyle.primary.opacity(0.46) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            playPlaylist(startingAt: track.id)
        }
    }

    private var addTracksSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Tracks")
                .font(.system(size: 24, weight: .black))
            // The picker mirrors the library's persisted sort so it never
            // contradicts the order the user just saw in the library view.
            List(LibraryTrackQuery.visibleTracks(in: store.tracks, sort: store.librarySortOrder, searchText: "")) { track in
                Button {
                    toggleSelection(track.id)
                } label: {
                    HStack {
                        Image(systemName: selectedTrackIDs.contains(track.id) ? "checkmark.circle.fill" : "circle")
                        Text(track.title)
                        Spacer()
                        Text(track.artist ?? "Unknown Artist")
                            .foregroundStyle(BackbeatStyle.secondaryText)
                    }
                }
                .disabled(playlist?.trackIDs.contains(track.id) == true)
            }
            HStack {
                Button("Cancel") {
                    showingAddTracks = false
                }
                Spacer()
                Button("Add") {
                    let orderedIDs = store.tracks.map(\.id).filter { selectedTrackIDs.contains($0) }
                    store.addTracks(orderedIDs, to: playlistID)
                    showingAddTracks = false
                }
                .disabled(selectedTrackIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
    }

    private func setPlaylistSource(_ source: PlaybackSource) {
        store.setPlaylistDefaultPlaybackSource(source, for: playlistID)
        if store.activeQueue?.playlistID == playlistID {
            if let track = store.nowPlayingTrack {
                playback.switchPlaybackSource(source, track: track, store: store, controlSource: .nowPlaying)
            } else {
                store.setActiveQueueSource(source)
            }
        }
    }

    private func playPlaylist(startingAt startingTrackID: BackbeatTrack.ID? = nil) {
        guard let track = store.startPlaylist(playlistID, at: startingTrackID) else { return }
        playback.playTrack(
            track: track,
            store: store,
            source: store.activeQueue?.preferredSource ?? store.nowPlayingPlaybackSource,
            startElapsed: 0
        )
    }

    private func deletePlaylist() {
        if store.activeQueue?.playlistID == playlistID, let track = store.nowPlayingTrack {
            playback.stopRender(track: track, store: store)
        }
        store.deletePlaylist(playlistID)
        route = .library
    }

    private func isNowPlaying(_ track: BackbeatTrack) -> Bool {
        store.activeQueue?.playlistID == playlistID && store.nowPlayingTrackID == track.id
    }

    private func toggleSelection(_ id: BackbeatTrack.ID) {
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
        } else {
            selectedTrackIDs.insert(id)
        }
    }
}
