import BackbeatCore
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlaybackController {
    enum PlaybackMode: Equatable {
        case render(BackbeatTrack.ID)
    }

    enum RenderControlSource {
        case detail
        case nowPlaying
    }

    private enum RenderPlaybackBackend: Equatable {
        case singleFile(BackbeatTrack.ID)
        case twoTrackMix(BackbeatTrack.ID)
    }

    private let singleFileEngine = SingleFilePlaybackEngine()
    private let twoTrackMixEngine = TwoTrackMixPlaybackEngine()
    private var renderPlaybackBackend: RenderPlaybackBackend?
    private var timer: Timer?
    private var mode: PlaybackMode?

    func toggleRender(track: BackbeatTrack, store: LibraryStore, source: RenderControlSource = .detail) {
        let playbackSource: PlaybackSource = source == .detail ? store.selectedPlaybackSource : store.nowPlayingPlaybackSource
        guard store.playbackAsset(for: track, preferredSource: playbackSource) != nil else { return }
        if mode == .render(track.id), store.isPlaybackPlaying {
            pauseRender(store: store)
            return
        }
        playTrack(track: track, store: store, source: playbackSource, startElapsed: nil)
    }

    func updateVolume(toProgress progress: Double, store: LibraryStore) {
        store.setVolume(toProgress: progress)
        let normalizationGainDB = currentNormalizationGainDB(store: store)
        singleFileEngine.setOutputGain(volume: store.volume, normalizationGainDB: normalizationGainDB)
        twoTrackMixEngine.setOutputGain(volume: store.volume, normalizationGainDB: normalizationGainDB)
    }

    func playRender(track: BackbeatTrack, store: LibraryStore) {
        playTrack(track: track, store: store, source: store.selectedPlaybackSource, startElapsed: nil)
    }

    func playRenderFromStart(track: BackbeatTrack, store: LibraryStore) {
        playTrack(track: track, store: store, source: store.nowPlayingPlaybackSource, startElapsed: 0)
    }

    func playTrack(
        track: BackbeatTrack,
        store: LibraryStore,
        source: PlaybackSource,
        startElapsed: TimeInterval? = nil
    ) {
        guard let asset = store.playbackAsset(for: track, preferredSource: source) else { return }
        let resumeTime = startElapsed ?? (mode == .render(track.id) || store.nowPlayingTrackID == track.id ? store.playbackElapsed : 0)
        let boundedResumeTime = min(max(0, resumeTime), track.duration)

        if source == .drumBoost, let mixAsset = store.twoTrackMixAsset(for: track, preferredSource: .drumBoost) {
            playTwoTrackMix(track: track, asset: mixAsset, store: store, startElapsed: boundedResumeTime)
            return
        }

        stopCurrent()
        mode = .render(track.id)

        do {
            try singleFileEngine.play(
                asset: asset,
                duration: track.duration,
                startElapsed: boundedResumeTime,
                volume: store.volume,
                speed: store.practiceSpeed,
                normalizationGainDB: store.normalizationGainDB(for: track)
            )
            renderPlaybackBackend = .singleFile(track.id)
            store.nowPlayingTrackID = track.id
            store.setActiveQueueSource(source)
            store.setPlaybackElapsed(boundedResumeTime, duration: track.duration)
            store.setPlaybackPlaying(true)
            startTimer { [weak self, weak store, track] in
                guard let self, let store else { return }
                self.tickRenderEngine(self.singleFileEngine, track: track, store: store)
            }
        } catch {
            renderPlaybackBackend = nil
            mode = nil
            store.nowPlayingTrackID = track.id
            store.setActiveQueueSource(source)
            store.setPlaybackElapsed(boundedResumeTime, duration: track.duration)
            store.setPlaybackPlaying(false)
            store.playbackErrorMessage = error.localizedDescription
        }
    }

    private func playTwoTrackMix(track: BackbeatTrack, asset: TwoTrackMixAsset, store: LibraryStore, startElapsed: TimeInterval) {
        do {
            stopCurrent()
            mode = .render(track.id)
            try twoTrackMixEngine.play(asset: asset,
                                       startElapsed: startElapsed,
                                       volume: store.volume,
                                       speed: store.practiceSpeed,
                                       normalizationGainDB: store.normalizationGainDB(for: track))
            renderPlaybackBackend = .twoTrackMix(track.id)
            store.nowPlayingTrackID = track.id
            store.setActiveQueueSource(.drumBoost)
            store.setPlaybackElapsed(startElapsed, duration: track.duration)
            store.setPlaybackPlaying(true)
            startTimer { [weak self, weak store, track] in
                guard let self, let store else { return }
                self.tickRenderEngine(self.twoTrackMixEngine, track: track, store: store)
            }
        } catch {
            renderPlaybackBackend = nil
            mode = nil
            store.nowPlayingTrackID = track.id
            store.setActiveQueueSource(.drumBoost)
            store.setPlaybackElapsed(startElapsed, duration: track.duration)
            store.setPlaybackPlaying(false)
            store.playbackErrorMessage = error.localizedDescription
        }
    }

    func switchPlaybackSource(
        _ source: PlaybackSource,
        track: BackbeatTrack,
        store: LibraryStore,
        controlSource: RenderControlSource = .detail
    ) {
        switch controlSource {
        case .detail:
            store.selectDetailPlaybackSource(source, for: track)
        case .nowPlaying:
            switchNowPlayingPlaybackSource(source, track: track, store: store)
        }
    }

    private func switchNowPlayingPlaybackSource(_ source: PlaybackSource, track: BackbeatTrack, store: LibraryStore) {
        let isCurrentRender = mode == .render(track.id)
        let wasPlaying = isCurrentRender && store.isPlaybackPlaying
        if isCurrentRender {
            let currentElapsed = currentRenderElapsed(store: store)
            store.setPlaybackElapsed(currentElapsed, duration: track.duration)
        }
        store.selectNowPlayingPlaybackSource(source, for: track)

        guard store.nowPlayingPlaybackSource == source else { return }
        if wasPlaying {
            playTrack(track: track, store: store, source: source)
        }
    }

    func playNextInQueue(store: LibraryStore) {
        guard let nextTrack = store.advanceQueue(repeatingCurrentIfNeeded: false) else { return }
        playTrack(
            track: nextTrack,
            store: store,
            source: store.activeQueue?.preferredSource ?? store.nowPlayingPlaybackSource,
            startElapsed: 0
        )
    }

    func playPreviousInQueue(store: LibraryStore) {
        guard let previousTrack = store.retreatQueue() else { return }
        playTrack(
            track: previousTrack,
            store: store,
            source: store.activeQueue?.preferredSource ?? store.nowPlayingPlaybackSource,
            startElapsed: 0
        )
    }

    func seek(by seconds: TimeInterval, store: LibraryStore) {
        guard let track = store.nowPlayingTrack else { return }
        let current = currentRenderElapsed(store: store)
        let target = min(max(0, current + seconds), track.duration)
        let progress = track.duration > 0 ? target / track.duration : 0
        seekRender(toProgress: progress, track: track, store: store)
    }

    func seekRender(toProgress progress: Double, track: BackbeatTrack, store: LibraryStore) {
        let targetElapsed = PlaybackScrubPosition.elapsed(progress: progress, duration: track.duration)
        store.nowPlayingTrackID = track.id

        if let engine = activeRenderEngine(for: track) {
            try? engine.seek(to: targetElapsed,
                             autoplay: store.isPlaybackPlaying,
                             volume: store.volume,
                             speed: store.practiceSpeed,
                             normalizationGainDB: store.normalizationGainDB(for: track))
        }

        store.setPlaybackElapsed(targetElapsed, duration: track.duration)
    }

    func setPracticeSpeed(_ speed: Double, track: BackbeatTrack, store: LibraryStore) {
        store.setPracticeSpeed(speed)
        singleFileEngine.setSpeed(store.practiceSpeed)
        twoTrackMixEngine.setSpeed(store.practiceSpeed)
    }

    func stepPracticeSpeed(by delta: Double, track: BackbeatTrack, store: LibraryStore) {
        store.stepPracticeSpeed(by: delta)
        singleFileEngine.setSpeed(store.practiceSpeed)
        twoTrackMixEngine.setSpeed(store.practiceSpeed)
    }

    func setPracticeLoopMode(_ mode: PracticeLoopMode, track: BackbeatTrack, store: LibraryStore) {
        store.setPracticeLoopMode(mode, duration: track.duration)
        enforcePracticeLoopBounds(track: track, store: store)
    }

    func setPracticeLoopStart(_ elapsed: TimeInterval, track: BackbeatTrack, store: LibraryStore) {
        store.setPracticeLoopStart(elapsed, duration: track.duration)
        enforcePracticeLoopBounds(track: track, store: store)
    }

    func setPracticeLoopEnd(_ elapsed: TimeInterval, track: BackbeatTrack, store: LibraryStore) {
        store.setPracticeLoopEnd(elapsed, duration: track.duration)
        enforcePracticeLoopBounds(track: track, store: store)
    }

    func clearPracticeLoop(track: BackbeatTrack, store: LibraryStore) {
        store.clearPracticeLoop()
    }

    func resetPracticePlayback(store: LibraryStore) {
        store.resetPracticeState()
        singleFileEngine.setSpeed(store.practiceSpeed)
        twoTrackMixEngine.setSpeed(store.practiceSpeed)
    }

    func setDrumMixBoostDB(_ boostDB: Double, track: BackbeatTrack, store: LibraryStore) {
        store.setDrumMixBoostDB(boostDB, for: track.id)
        if let updatedTrack = store.track(id: track.id) {
            twoTrackMixEngine.setMixSettings(updatedTrack.drumMixSettings)
        }
    }

    func stopRender(track: BackbeatTrack, store: LibraryStore) {
        if mode == .render(track.id) {
            stopCurrent()
        }
        store.stopPlayback(duration: track.duration)
    }

    private func pauseRender(store: LibraryStore) {
        // Commit the engine's exact position before the timer stops; resume reads store.playbackElapsed.
        if let track = store.nowPlayingTrack {
            store.setPlaybackElapsed(currentRenderElapsed(store: store), duration: track.duration)
        }
        singleFileEngine.pause()
        twoTrackMixEngine.pause()
        store.setPlaybackPlaying(false)
        stopTimer()
    }

    private func tickRenderEngine(_ engine: RenderPlaybackEngine, track: BackbeatTrack, store: LibraryStore) {
        let schedule = PracticePlaybackSchedule(
            duration: track.duration,
            loopMode: store.practiceLoopMode,
            loopRange: store.practiceLoopRange,
            speed: store.practiceSpeed
        )
        switch schedule.tickAction(forElapsed: engine.currentElapsed()) {
        case .wrap(let target):
            try? engine.seek(to: target,
                             autoplay: store.isPlaybackPlaying,
                             volume: store.volume,
                             speed: store.practiceSpeed,
                             normalizationGainDB: store.normalizationGainDB(for: track))
            store.setPlaybackElapsed(target, duration: track.duration)
        case .finished:
            if let nextTrack = store.advanceQueue() {
                playTrack(
                    track: nextTrack,
                    store: store,
                    source: store.activeQueue?.preferredSource ?? store.nowPlayingPlaybackSource,
                    startElapsed: 0
                )
            } else {
                stopRender(track: track, store: store)
            }
        case .progress(let elapsed):
            store.setPlaybackElapsed(elapsed, duration: track.duration)
        }
    }

    private func startTimer(_ action: @MainActor @Sendable @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func stopCurrent() {
        stopTimer()
        singleFileEngine.stop()
        twoTrackMixEngine.stop()
        renderPlaybackBackend = nil
        mode = nil
    }

    private func currentRenderElapsed(store: LibraryStore) -> TimeInterval {
        if case .twoTrackMix = renderPlaybackBackend {
            return twoTrackMixEngine.currentElapsed()
        }
        if case .singleFile = renderPlaybackBackend {
            return singleFileEngine.currentElapsed()
        }
        return store.playbackElapsed
    }

    private func currentNormalizationGainDB(store: LibraryStore) -> Double {
        guard let track = store.nowPlayingTrack else { return 0 }
        return store.normalizationGainDB(for: track)
    }

    private func activeRenderEngine(for track: BackbeatTrack) -> RenderPlaybackEngine? {
        guard mode == .render(track.id) else { return nil }
        switch renderPlaybackBackend {
        case .twoTrackMix(track.id):
            return twoTrackMixEngine
        case .singleFile(track.id):
            return singleFileEngine
        default:
            return nil
        }
    }

    private func enforcePracticeLoopBounds(track: BackbeatTrack, store: LibraryStore) {
        guard
            mode == .render(track.id),
            store.practiceLoopMode == .section,
            let range = store.practiceLoopRange,
            let engine = activeRenderEngine(for: track)
        else { return }

        let current = engine.currentElapsed()
        guard current < range.start || current >= range.end else { return }
        try? engine.seek(to: range.start,
                         autoplay: store.isPlaybackPlaying,
                         volume: store.volume,
                         speed: store.practiceSpeed,
                         normalizationGainDB: store.normalizationGainDB(for: track))
        store.setPlaybackElapsed(range.start, duration: track.duration)
    }
}
