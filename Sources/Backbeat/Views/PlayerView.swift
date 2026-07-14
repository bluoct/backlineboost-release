import BackbeatCore
import SwiftUI

struct PlayerView: View {
    let store: LibraryStore
    let playback: AudioPlaybackController
    let renderQueue: RenderQueueCoordinator
    @Binding var route: BackbeatRoute

    var body: some View {
        if let track = store.selectedTrack ?? store.nowPlayingTrack ?? store.tracks.first {
            PlayerDetailView(store: store, playback: playback, renderQueue: renderQueue, route: $route, track: track)
        } else {
            // Empty library: nothing to play — return to Library.
            Color.clear
                .onAppear { route = .library }
        }
    }
}

private struct PlayerDetailView: View {
    let store: LibraryStore
    let playback: AudioPlaybackController
    let renderQueue: RenderQueueCoordinator
    @Binding var route: BackbeatRoute
    let track: BackbeatTrack
    @State private var waveformEnvelope: WaveformEnvelope?
    // Process-stable so decode dedup survives SwiftUI re-initializing the view.
    private static let waveformCache = WaveformEnvelopeCache()

    private var trackIndex: Int {
        store.tracks.firstIndex(where: { $0.id == track.id }) ?? 0
    }

    private var selectedSource: PlaybackSource {
        isDetailTrackNowPlaying ? store.nowPlayingPlaybackSource : store.selectedPlaybackSource
    }

    private var renderControlSource: AudioPlaybackController.RenderControlSource {
        isDetailTrackNowPlaying ? .nowPlaying : .detail
    }

    private var isDetailTrackNowPlaying: Bool {
        store.nowPlayingTrackID == track.id
    }

    private var detailPlaybackAsset: PlaybackAsset? {
        store.detailPlaybackAsset(for: track)
    }

    private var waveformAsset: PlaybackAsset? {
        isDetailTrackNowPlaying ? store.nowPlayingPlaybackAsset(for: track) : detailPlaybackAsset
    }

    private var waveformIdentity: String {
        "\(track.id.uuidString)-\(selectedSource.rawValue)-\(waveformAsset?.fileURL.path ?? "missing")"
    }

    private var detailIsPlaying: Bool {
        isDetailTrackNowPlaying && store.isPlaybackPlaying
    }

    private var detailPlaybackProgress: Double {
        isDetailTrackNowPlaying ? store.playbackProgress : 0
    }

    private var detailElapsedLabel: String {
        isDetailTrackNowPlaying ? store.playbackElapsedLabel : BackbeatFormat.duration(0)
    }

    private var detailRemainingLabel: String {
        guard isDetailTrackNowPlaying else {
            return "-\(BackbeatFormat.duration(track.duration))"
        }
        return store.playbackRemainingLabel(for: track)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        route = .library
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(BackbeatButtonStyle(variant: .icon))

                    Text("Library")
                        .foregroundStyle(BackbeatStyle.secondaryText)
                    Text("/")
                        .foregroundStyle(BackbeatStyle.mutedText)
                    Text(isDetailTrackNowPlaying ? "Now playing" : "Track")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 40)
                .padding(.top, 20)

                VStack(spacing: 16) {
                    TrackTile(track: track, index: trackIndex, size: 168, fontSize: 62)
                        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 14)

                    VStack(spacing: 5) {
                        Text(track.title)
                            .font(.system(size: 30, weight: .black))
                        Text(track.artist ?? "Unknown Artist")
                            .font(.system(size: 14))
                            .foregroundStyle(BackbeatStyle.secondaryText)
                    }

                    sourceControl

                    // Background render lifecycle for this track: queued,
                    // rendering stages, or failed with a retry action.
                    if let renderStatus = renderQueue.statusDisplay(for: track) {
                        ProgressStatusRow(display: renderStatus) {
                            renderQueue.enqueue(track.id)
                        }
                        .frame(width: 640)
                    }

                    VStack(spacing: 7) {
                        LoopTimelineView(
                            progress: detailPlaybackProgress,
                            duration: track.duration,
                            loopRange: store.practiceLoopRange,
                            envelope: nil,
                            height: 9,
                            onScrub: { progress in
                                playback.seekRender(toProgress: progress, track: track, store: store)
                            },
                            onMoveLoopStart: { elapsed in
                                playback.setPracticeLoopStart(elapsed, track: track, store: store)
                            },
                            onMoveLoopEnd: { elapsed in
                                playback.setPracticeLoopEnd(elapsed, track: track, store: store)
                            }
                        )
                        .disabled(!isDetailTrackNowPlaying)
                        HStack {
                            Text(detailElapsedLabel)
                            Spacer()
                            Text(detailRemainingLabel)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(BackbeatStyle.secondaryText)
                    }
                    .frame(width: 640)

                    HStack(spacing: 24) {
                        Button {
                            playback.playPreviousInQueue(store: store)
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 22))
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canPlayPreviousInQueue)
                        .help("Previous track")

                        Button {
                            playback.seek(by: -15, store: store)
                        } label: {
                            Label("15", systemImage: "gobackward.15")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 22))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isDetailTrackNowPlaying)

                        PlaybackCircleButton(
                            systemName: detailIsPlaying ? "pause.fill" : "play.fill",
                            size: 64,
                            iconSize: 24,
                            accessibilityLabel: detailIsPlaying ? "Pause track" : "Play track"
                        ) {
                            playback.toggleRender(track: track, store: store, source: renderControlSource)
                        }
                        .shadow(color: BackbeatStyle.primary.opacity(0.45), radius: 18, x: 0, y: 8)

                        Button {
                            playback.seek(by: 15, store: store)
                        } label: {
                            Label("15", systemImage: "goforward.15")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 22))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isDetailTrackNowPlaying)

                        Button {
                            playback.playNextInQueue(store: store)
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 22))
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canPlayNextInQueue)
                        .help("Next track")
                    }

                    PracticeControlsView(
                        store: store,
                        playback: playback,
                        track: track,
                        progress: detailPlaybackProgress,
                        envelope: waveformEnvelope,
                        // Mirrors the controller's practice-edit ownership
                        // guard (D-108, extended at owner QA 2026-07-13): a
                        // free transport edits anything; a live session only
                        // its own track — scrub, loop bounds, and speed alike.
                        isPracticeEditingEnabled: !store.isPlaybackSessionActive || store.nowPlayingTrackID == track.id,
                        onScrub: { progress in
                            playback.seekRender(toProgress: progress, track: track, store: store)
                        },
                        onMoveLoopStart: { elapsed in
                            playback.setPracticeLoopStart(elapsed, track: track, store: store)
                        },
                        onMoveLoopEnd: { elapsed in
                            playback.setPracticeLoopEnd(elapsed, track: track, store: store)
                        }
                    ) {
                        drumsSection
                    }
                    .frame(width: 760)
                }
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: waveformIdentity) {
            await loadWaveformEnvelope()
        }
    }

    private var sourceControl: some View {
        PlaybackSourcePicker(selection: Binding(
            get: { selectedSource },
            set: { source in
                playback.switchPlaybackSource(source, track: track, store: store, controlSource: renderControlSource)
            }
        ))
        .frame(width: 400)
    }

    // Live drum mix only exists for a rendered Drum Boost pair; otherwise the
    // card keeps its shape with an inert, dimmed slider.
    @ViewBuilder
    private var drumsSection: some View {
        if selectedSource == .drumBoost, store.twoTrackMixAsset(for: track, preferredSource: .drumBoost) != nil {
            DrumMixControlsView(settings: track.drumMixSettings) { boostDB in
                playback.setDrumMixBoostDB(boostDB, track: track, store: store)
            }
        } else {
            DrumMixControlsView(settings: track.drumMixSettings) { _ in }
                .disabled(true)
                .opacity(0.4)
                .help("Switch to Drum Boost to adjust the drum level")
        }
    }

    private func loadWaveformEnvelope() async {
        guard let url = waveformAsset?.fileURL else {
            await MainActor.run {
                waveformEnvelope = nil
            }
            return
        }

        do {
            let envelope = try await Self.waveformCache.envelope(for: url, binCount: 180)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                waveformEnvelope = envelope
            }
        } catch {
            // A cancelled task must not blank the envelope a newer task set.
            guard !Task.isCancelled else { return }
            await MainActor.run {
                waveformEnvelope = nil
            }
        }
    }
}
