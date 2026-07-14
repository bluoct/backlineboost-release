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

    func playFromStart(_ track: BackbeatTrack, queueing visibleTrackIDs: [BackbeatTrack.ID]) {
        // D-102 hybrid: with no queue — or a non-playlist queue — double-click
        // (re)anchors a queue over the caller's visible order, so the library
        // plays on in its sorted/filtered order. An active PLAYLIST queue
        // falls through to the interleave below instead: the one-off track
        // plays without the queue being touched, and end-of-track advance
        // resumes the playlist where it left off (owner-sacred, D-102).
        if store.activeQueue?.playlistID == nil {
            if let first = store.startLibraryQueue(visibleTrackIDs, startingAt: track.id) {
                playback.playTrack(
                    track: first,
                    store: store,
                    source: store.activeQueue?.preferredSource ?? store.nowPlayingPlaybackSource,
                    startElapsed: 0
                )
                route.wrappedValue = .player
                return
            }
            // The hybrid start only fails when the library mutated under the
            // double-click. If the row's track is gone, keep the store's
            // error message and never play a dead file; otherwise clear the
            // queue error and let the legacy single-play path take over.
            guard store.track(id: track.id) != nil else { return }
            store.playbackFailure = nil
        }
        // Gate on render presence, not status: a re-rendering or
        // render-failed track still holds its old playable pair (D-105's
        // "keeps playing" promise), and selectTrackForPlayback already
        // refuses tracks with no render records.
        if store.selectTrackForPlayback(track.id, restart: true) {
            playback.playRenderFromStart(track: track, store: store)
        } else {
            store.selectTrack(track.id)
            playback.playTrack(track: track, store: store, source: .original, startElapsed: 0)
        }
        route.wrappedValue = .player
    }

    func tapGesture(for track: BackbeatTrack, queueing visibleTrackIDs: [BackbeatTrack.ID]) -> some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    playFromStart(track, queueing: visibleTrackIDs)
                case .second:
                    open(track)
                }
            }
    }
}
