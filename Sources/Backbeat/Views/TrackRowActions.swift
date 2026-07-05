import BackbeatCore
import SwiftUI

@MainActor
struct TrackRowActions {
    let store: LibraryStore
    let playback: AudioPlaybackController
    let route: Binding<BackbeatRoute>

    func open(_ track: BackbeatTrack) {
        if track.status == .ready {
            store.selectRenderedTrackForInspection(track.id)
        } else {
            // Unrendered tracks open in the Player too — they play as
            // Original while the background queue renders them.
            store.selectTrack(track.id)
        }
        route.wrappedValue = .player
    }

    func playFromStart(_ track: BackbeatTrack) {
        if track.status == .ready, store.selectTrackForPlayback(track.id, restart: true) {
            playback.playRenderFromStart(track: track, store: store)
        } else {
            store.selectTrack(track.id)
            playback.playTrack(track: track, store: store, source: .original, startElapsed: 0)
        }
        route.wrappedValue = .player
    }

    func tapGesture(for track: BackbeatTrack) -> some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    playFromStart(track)
                case .second:
                    open(track)
                }
            }
    }
}
