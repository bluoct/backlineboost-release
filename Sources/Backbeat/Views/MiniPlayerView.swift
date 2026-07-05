import BackbeatCore
import SwiftUI

struct MiniPlayerView: View {
    let store: LibraryStore
    let playback: AudioPlaybackController
    @Binding var route: BackbeatRoute

    private var track: BackbeatTrack? {
        store.nowPlayingTrack
    }

    private var trackIndex: Int {
        guard let track else { return 0 }
        return store.tracks.firstIndex(where: { $0.id == track.id }) ?? 0
    }

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 12) {
                if let track {
                    TrackTile(track: track, index: trackIndex, size: 48, fontSize: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                        Text(track.artist ?? "Unknown Artist")
                            .font(.system(size: 11))
                            .foregroundStyle(BackbeatStyle.secondaryText)
                            .lineLimit(1)
                    }
                } else {
                    AppIconBadge(size: 48, cornerRadius: 8, fallbackSystemImage: "waveform", fallbackTint: BackbeatStyle.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No rendered track")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Render a track to play")
                            .font(.system(size: 11))
                            .foregroundStyle(BackbeatStyle.secondaryText)
                    }
                }
            }
            .frame(width: 250, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if let track {
                    store.selectRenderedTrackForInspection(track.id)
                    route = .player
                }
            }

            VStack(spacing: 7) {
                HStack(spacing: 15) {
                    Button {
                        store.cycleRepeatMode()
                    } label: {
                        Image(systemName: store.repeatModeSystemImage)
                    }
                    .disabled(store.activeQueue == nil)
                    .foregroundStyle(repeatModeForeground)
                    .accessibilityLabel("Repeat mode")
                    .accessibilityValue(store.repeatModeAccessibilityValue)
                    .help("Repeat: \(store.repeatModeAccessibilityValue)")

                    Button {
                        playback.playPreviousInQueue(store: store)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!store.canPlayPreviousInQueue)
                    .help("Previous track")

                    Button {
                        playback.seek(by: -15, store: store)
                    } label: { Image(systemName: "gobackward.15") }
                    .disabled(track == nil)

                    PlaybackCircleButton(
                        systemName: store.isPlaybackPlaying ? "pause.fill" : "play.fill",
                        size: 40,
                        iconSize: 16,
                        fill: track == nil ? BackbeatStyle.panelRaised : BackbeatStyle.primary,
                        foreground: track == nil ? BackbeatStyle.secondaryText : BackbeatStyle.appBackground,
                        isDisabled: track == nil,
                        accessibilityLabel: store.isPlaybackPlaying ? "Pause track" : "Play track"
                    ) {
                        if let track {
                            playback.toggleRender(track: track, store: store, source: .nowPlaying)
                        }
                    }

                    Button {
                        playback.seek(by: 15, store: store)
                    } label: { Image(systemName: "goforward.15") }
                    .disabled(track == nil)

                    Button {
                        playback.playNextInQueue(store: store)
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!store.canPlayNextInQueue)
                    .help("Next track")

                    Button {
                        store.toggleShuffleMode()
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .disabled(store.activeQueue == nil)
                    .foregroundStyle(shuffleModeForeground)
                    .accessibilityLabel("Shuffle")
                    .accessibilityValue(store.activeQueue?.isShuffleEnabled == true ? "On" : "Off")
                    .help(store.activeQueue?.isShuffleEnabled == true ? "Shuffle on" : "Shuffle off")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BackbeatStyle.secondaryText)

                HStack(spacing: 11) {
                    Text(track == nil ? "0:00" : store.playbackElapsedLabel)
                        .frame(width: 42, alignment: .trailing)
                    ScrubbableProgressBar(progress: track == nil ? 0 : store.playbackProgress) { progress in
                        guard let track else { return }
                        playback.seekRender(toProgress: progress, track: track, store: store)
                    }
                    .disabled(track == nil)
                    Text(track.map { store.playbackRemainingLabel(for: $0) } ?? "-0:00")
                        .frame(width: 42, alignment: .leading)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BackbeatStyle.secondaryText)
            }
            .frame(maxWidth: 620)

            HStack(spacing: 12) {
                if track == nil {
                    Text("No version")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(BackbeatStyle.mutedText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(BackbeatStyle.panelRaised, in: RoundedRectangle(cornerRadius: 6))
                } else if let track {
                    sourceControl(for: track)
                }
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(BackbeatStyle.secondaryText)
                ScrubbableProgressBar(
                    progress: store.volume,
                    fill: BackbeatStyle.secondaryText,
                    track: BackbeatStyle.panelRaised,
                    accessibilityLabel: "Volume"
                ) { progress in
                    playback.updateVolume(toProgress: progress, store: store)
                }
                    .frame(width: 88)
            }
            .frame(width: 250, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .frame(height: 84)
        .background(BackbeatStyle.sidebarBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BackbeatStyle.border)
                .frame(height: 1)
        }
    }

    private func sourceControl(for track: BackbeatTrack) -> some View {
        let asset = activePlaybackAsset(for: track)
        let preferredSource = asset?.preferredSource ?? store.nowPlayingPlaybackSource
        let effectiveSource = asset?.effectiveSource ?? preferredSource
        let nextSource = nextPlaybackSource(after: preferredSource)

        return Button {
            playback.switchPlaybackSource(nextSource, track: track, store: store, controlSource: .nowPlaying)
        } label: {
            PlaybackSourceTag(preferredSource: preferredSource, effectiveSource: effectiveSource)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Switch to \(nextSource.displayLabel)")
        .accessibilityLabel("Switch playback source")
        .accessibilityValue(preferredSource.displayLabel)
    }

    private func activePlaybackAsset(for track: BackbeatTrack) -> PlaybackAsset? {
        store.nowPlayingPlaybackAsset(for: track)
    }

    private func nextPlaybackSource(after source: PlaybackSource) -> PlaybackSource {
        let sources = PlaybackSource.controlCases
        guard sources.contains(.drumBoost), sources.contains(.drumless) else { return .original }
        guard let index = sources.firstIndex(of: source) else { return .original }
        let nextIndex = sources.index(after: index)
        return nextIndex == sources.endIndex ? (sources.first ?? .original) : sources[nextIndex]
    }

    private var repeatModeForeground: Color {
        guard store.activeQueue != nil else { return BackbeatStyle.mutedText }
        return store.activeQueue?.repeatMode == .off ? BackbeatStyle.secondaryText : BackbeatStyle.primary
    }

    private var shuffleModeForeground: Color {
        guard store.activeQueue != nil else { return BackbeatStyle.mutedText }
        return store.activeQueue?.isShuffleEnabled == true ? BackbeatStyle.primary : BackbeatStyle.secondaryText
    }
}
