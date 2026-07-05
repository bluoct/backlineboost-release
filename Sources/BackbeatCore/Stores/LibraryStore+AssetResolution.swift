import Foundation

// Pure presentation vocabulary and render/asset resolution over store state —
// split from LibraryStore.swift so the store itself stays focused on mutations.
extension LibraryStore {
    public var repeatModeSystemImage: String {
        switch activeQueue?.repeatMode ?? .off {
        case .off, .all:
            "repeat"
        case .one:
            "repeat.1"
        }
    }

    public var repeatModeAccessibilityValue: String {
        switch activeQueue?.repeatMode ?? .off {
        case .off:
            "Off"
        case .all:
            "All"
        case .one:
            "One"
        }
    }

    public func detailRender(for track: BackbeatTrack) -> RenderRecord? {
        render(for: track, preferredVariant: selectedPlaybackVariant)
    }

    public func playbackRender(for track: BackbeatTrack) -> RenderRecord? {
        render(for: track, preferredVariant: nowPlayingPlaybackVariant)
    }

    public func render(for track: BackbeatTrack, preferredVariant: RenderVariant) -> RenderRecord? {
        track.activeRender(for: preferredVariant)
            ?? track.activeRender(for: .boostedDrums)
            ?? track.activeRender(for: .drumless)
    }

    public func playbackAsset(
        for track: BackbeatTrack,
        preferredSource: PlaybackSource
    ) -> PlaybackAsset? {
        switch preferredSource {
        case .original:
            return PlaybackAsset(
                trackID: track.id,
                preferredSource: preferredSource,
                effectiveSource: .original,
                fileURL: track.sourceURL
            )
        case .drumBoost:
            if twoTrackMixAsset(for: track, preferredSource: preferredSource) != nil {
                return PlaybackAsset(
                    trackID: track.id,
                    preferredSource: preferredSource,
                    effectiveSource: .drumBoost,
                    fileURL: track.sourceURL
                )
            }
            if let render = track.activeRender(for: .boostedDrums) {
                return PlaybackAsset(
                    trackID: track.id,
                    preferredSource: preferredSource,
                    effectiveSource: .drumBoost,
                    fileURL: render.fileURL
                )
            }
            return PlaybackAsset(
                trackID: track.id,
                preferredSource: preferredSource,
                effectiveSource: .original,
                fileURL: track.sourceURL
            )
        case .drums:
            if let render = track.activeRender(for: .drums) {
                return PlaybackAsset(
                    trackID: track.id,
                    preferredSource: preferredSource,
                    effectiveSource: .drums,
                    fileURL: render.fileURL
                )
            }
            return PlaybackAsset(
                trackID: track.id,
                preferredSource: preferredSource,
                effectiveSource: .original,
                fileURL: track.sourceURL
            )
        case .drumless:
            if let render = track.activeRender(for: .drumless) {
                return PlaybackAsset(
                    trackID: track.id,
                    preferredSource: preferredSource,
                    effectiveSource: .drumless,
                    fileURL: render.fileURL
                )
            }
            return PlaybackAsset(
                trackID: track.id,
                preferredSource: preferredSource,
                effectiveSource: .original,
                fileURL: track.sourceURL
            )
        }
    }

    public func twoTrackMixAsset(for track: BackbeatTrack, preferredSource: PlaybackSource) -> TwoTrackMixAsset? {
        guard preferredSource == .drumBoost else { return nil }
        guard
            let drumless = track.activeRender(for: .drumless),
            let drums = track.activeRender(for: .drums)
        else { return nil }
        return TwoTrackMixAsset(
            trackID: track.id,
            drumlessURL: drumless.fileURL,
            drumsURL: drums.fileURL,
            duration: track.duration,
            settings: track.drumMixSettings
        )
    }

    public func normalizationGainDB(for track: BackbeatTrack) -> Double {
        PlaybackNormalization.gainDB(for: track, settings: playbackNormalizationSettings)
    }

    public func detailPlaybackAsset(for track: BackbeatTrack) -> PlaybackAsset? {
        playbackAsset(for: track, preferredSource: selectedPlaybackSource)
    }

    public func nowPlayingPlaybackAsset(for track: BackbeatTrack) -> PlaybackAsset? {
        playbackAsset(for: track, preferredSource: nowPlayingPlaybackSource)
    }

    public var playbackElapsedLabel: String {
        BackbeatFormat.duration(playbackElapsed)
    }

    public func playbackRemainingLabel(for track: BackbeatTrack) -> String {
        let remaining = max(0, track.duration - playbackElapsed)
        return "-\(BackbeatFormat.duration(remaining))"
    }
}
