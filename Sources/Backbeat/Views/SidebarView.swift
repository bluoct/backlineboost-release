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

            Text("Tracks")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundStyle(BackbeatStyle.mutedText)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(store.tracks.enumerated()), id: \.element.id) { index, track in
                        sidebarRow(track, index: index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)

                playlistsSection
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
            }
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

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Playlists")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(BackbeatStyle.mutedText)
                Spacer()
                Button {
                    let playlist = store.createPlaylist()
                    route = .playlist(playlist.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            ForEach(store.playlists) { playlist in
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
        }
    }

    private func sidebarRow(_ track: BackbeatTrack, index: Int) -> some View {
        HStack(spacing: 10) {
            TrackTile(track: track, index: index, size: 30, fontSize: 11)
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
        .gesture(rowActions.tapGesture(for: track))
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
