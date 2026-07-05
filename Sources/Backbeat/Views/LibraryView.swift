import BackbeatCore
import SwiftUI

struct LibraryView: View {
    let store: LibraryStore
    let playback: AudioPlaybackController
    let renderQueue: RenderQueueCoordinator
    @Binding var route: BackbeatRoute
    let onImportTrack: () -> Void
    let onImportFolder: () -> Void
    let onDeleteTrack: (BackbeatTrack) throws -> Void
    @State private var deletionCandidate: BackbeatTrack?
    @State private var deleteErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                table
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 70)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .alert("Delete track?", isPresented: deleteConfirmationBinding, presenting: deletionCandidate) { track in
            Button("No", role: .cancel) {
                deletionCandidate = nil
            }
            Button("Yes", role: .destructive) {
                confirmDelete(track)
            }
        } message: { track in
            Text("Delete \(track.title), its stored source file, and any boosted-drums or drumless renders?")
        }
        .alert("Delete failed", isPresented: deleteFailedBinding) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Library")
                    .font(.system(size: 30, weight: .black))
                Text("\(store.tracks.count) tracks · \(readyCount) ready to play")
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

    @ViewBuilder
    private var table: some View {
        if store.tracks.isEmpty {
            emptyState
        } else {
            trackTable
        }
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

    private var trackTable: some View {
        VStack(spacing: 6) {
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

            ForEach(Array(store.tracks.enumerated()), id: \.element.id) { index, track in
                trackRow(track, index: index)
            }
        }
    }

    private var readyCount: Int {
        store.tracks.filter { $0.status == .ready }.count
    }

    private func trackRow(_ track: BackbeatTrack, index: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 13) {
                TrackTile(track: track, index: index, size: 42)
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
            .gesture(rowActions.tapGesture(for: track))
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
                    deletionCandidate = track
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(BackbeatButtonStyle(variant: .icon))
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(store.selectedTrackID == track.id ? BackbeatStyle.panelRaised : BackbeatStyle.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(store.selectedTrackID == track.id ? BackbeatStyle.border.opacity(1) : BackbeatStyle.border.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        )
    }

    private var deleteFailedBinding: Binding<Bool> {
        Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )
    }

    private func confirmDelete(_ track: BackbeatTrack) {
        do {
            try onDeleteTrack(track)
            deletionCandidate = nil
        } catch {
            deletionCandidate = nil
            deleteErrorMessage = error.localizedDescription
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
