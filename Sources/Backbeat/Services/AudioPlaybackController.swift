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
    private weak var activeStore: LibraryStore?
    private var activeTickAction: (@MainActor @Sendable () -> Void)?

    init() {
        // Route each engine's hardware-interruption signal (an AVAudioEngine
        // configuration change — output-device or format change) back to the
        // store so a device change reflects as paused instead of leaving the UI
        // "playing" silence (F3). The engines own the AVFoundation observer; the
        // controller stays AVFoundation-free.
        let interrupt: @MainActor (TimeInterval) -> Void = { [weak self] elapsed in
            self?.handlePlaybackInterrupted(elapsed: elapsed)
        }
        singleFileEngine.onPlaybackInterrupted = interrupt
        twoTrackMixEngine.onPlaybackInterrupted = interrupt
    }

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
        applyOutputGain(store: store)
    }

    /// Recomputes the normalization gain for the now-playing track and pushes it
    /// into both engines. Called on a volume change and when the "Normalize
    /// playback volume" setting toggles, so the change reaches live playback
    /// immediately instead of deferring to the next play/seek/volume touch (F4).
    func applyOutputGain(store: LibraryStore) {
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

    private func effectiveSectionLoop(store: LibraryStore) -> PracticeLoopRange? {
        store.practiceLoopMode == .section ? store.practiceLoopRange : nil
    }

    // Stop only the engine we are NOT about to play — stopping the target
    // would destroy the pre-scheduled loop chain the pause/resume contract
    // preserves (D-094); the target engine's play() resumes or rebuilds
    // internally.
    private func prepareForPlayback(target: RenderPlaybackBackend) {
        stopTimer()
        switch target {
        case .singleFile:
            twoTrackMixEngine.stop()
        case .twoTrackMix:
            singleFileEngine.stop()
        }
    }

    func playTrack(
        track: BackbeatTrack,
        store: LibraryStore,
        source: PlaybackSource,
        startElapsed: TimeInterval? = nil
    ) {
        guard let asset = store.playbackAsset(for: track, preferredSource: source) else { return }
        let resumeTime = startElapsed ?? (mode == .render(track.id) || store.nowPlayingTrackID == track.id ? store.playbackElapsed : 0)
        let boundedResumeTime = min(max(0, resumeTime), transportDuration(for: track))

        if source == .drumBoost, let mixAsset = store.twoTrackMixAsset(for: track, preferredSource: .drumBoost) {
            playTwoTrackMix(track: track, asset: mixAsset, store: store, startElapsed: boundedResumeTime)
            return
        }

        prepareForPlayback(target: .singleFile(track.id))
        mode = .render(track.id)

        do {
            try singleFileEngine.play(
                asset: asset,
                startElapsed: boundedResumeTime,
                volume: store.volume,
                speed: store.practiceSpeed,
                normalizationGainDB: store.normalizationGainDB(for: track),
                sectionLoop: effectiveSectionLoop(store: store)
            )
            renderPlaybackBackend = .singleFile(track.id)
            activeStore = store
            store.nowPlayingTrackID = track.id
            store.setActiveQueueSource(source)
            store.setPlaybackElapsed(boundedResumeTime, duration: transportDuration(for: track))
            store.setPlaybackPlaying(true)
            // One UI-progress cadence — A/B wrap enforcement lives in the
            // engines' pre-scheduled chain now, D-094.
            startTimer(interval: 0.2) { [weak self, weak store, track] in
                guard let self, let store else { return }
                self.tickRenderEngine(self.singleFileEngine, track: track, store: store)
            }
        } catch {
            stopCurrent()
            // A rendered file may have been deleted on disk; recover the dangling
            // record and fall back to Original instead of dead-ending on a raw
            // Foundation error (F7).
            if source != .original, store.recoverMissingRenderFiles(for: track.id) {
                playTrack(track: track, store: store, source: .original, startElapsed: boundedResumeTime)
                return
            }
            renderPlaybackBackend = nil
            mode = nil
            store.nowPlayingTrackID = track.id
            store.setActiveQueueSource(source)
            store.setPlaybackElapsed(boundedResumeTime, duration: transportDuration(for: track))
            store.setPlaybackPlaying(false)
            store.playbackErrorMessage = error.localizedDescription
        }
    }

    private func playTwoTrackMix(track: BackbeatTrack, asset: TwoTrackMixAsset, store: LibraryStore, startElapsed: TimeInterval) {
        do {
            prepareForPlayback(target: .twoTrackMix(track.id))
            mode = .render(track.id)
            try twoTrackMixEngine.play(asset: asset,
                                       startElapsed: startElapsed,
                                       volume: store.volume,
                                       speed: store.practiceSpeed,
                                       normalizationGainDB: store.normalizationGainDB(for: track),
                                       sectionLoop: effectiveSectionLoop(store: store))
            renderPlaybackBackend = .twoTrackMix(track.id)
            activeStore = store
            store.nowPlayingTrackID = track.id
            store.setActiveQueueSource(.drumBoost)
            store.setPlaybackElapsed(startElapsed, duration: transportDuration(for: track))
            store.setPlaybackPlaying(true)
            startTimer(interval: 0.2) { [weak self, weak store, track] in
                guard let self, let store else { return }
                self.tickRenderEngine(self.twoTrackMixEngine, track: track, store: store)
            }
        } catch {
            stopCurrent()
            // A missing drums/drumless file is recoverable: drop the dangling
            // records (the track re-renders) and fall back to Original (F7). An
            // incompatible existing pair is a real defect, not a deleted file —
            // surface it like the single-file catch above rather than silently
            // swapping to Original with no indication.
            if store.recoverMissingRenderFiles(for: track.id) {
                renderPlaybackBackend = nil
                mode = nil
                playTrack(track: track, store: store, source: .original, startElapsed: startElapsed)
                return
            }
            renderPlaybackBackend = nil
            mode = nil
            store.nowPlayingTrackID = track.id
            store.setActiveQueueSource(.drumBoost)
            store.setPlaybackElapsed(startElapsed, duration: transportDuration(for: track))
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
            store.setPlaybackElapsed(currentElapsed, duration: transportDuration(for: track))
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
        let duration = transportDuration(for: track)
        let target = min(max(0, current + seconds), duration)
        let progress = duration > 0 ? target / duration : 0
        seekRender(toProgress: progress, track: track, store: store)
    }

    func seekRender(toProgress progress: Double, track: BackbeatTrack, store: LibraryStore) {
        let targetElapsed = PlaybackScrubPosition.elapsed(progress: progress, duration: transportDuration(for: track))
        store.nowPlayingTrackID = track.id

        if let engine = activeRenderEngine(for: track) {
            try? engine.seek(to: targetElapsed,
                             autoplay: store.isPlaybackPlaying,
                             volume: store.volume,
                             speed: store.practiceSpeed,
                             normalizationGainDB: store.normalizationGainDB(for: track))
        }

        store.setPlaybackElapsed(targetElapsed, duration: transportDuration(for: track))
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
        store.setPracticeLoopMode(mode, duration: transportDuration(for: track))
        syncEngineSectionLoop(track: track, store: store)
    }

    func setPracticeLoopStart(_ elapsed: TimeInterval, track: BackbeatTrack, store: LibraryStore) {
        store.setPracticeLoopStart(elapsed, duration: transportDuration(for: track))
        syncEngineSectionLoop(track: track, store: store)
    }

    func setPracticeLoopEnd(_ elapsed: TimeInterval, track: BackbeatTrack, store: LibraryStore) {
        store.setPracticeLoopEnd(elapsed, duration: transportDuration(for: track))
        syncEngineSectionLoop(track: track, store: store)
    }

    // Marker capture reads the engine's live position — the 0.2s UI poll is
    // too stale for a precision feature (the old faster section-loop poll
    // was itself 30ms stale).
    func capturePracticeLoopStart(track: BackbeatTrack, store: LibraryStore) {
        setPracticeLoopStart(currentRenderElapsed(store: store), track: track, store: store)
    }

    func capturePracticeLoopEnd(track: BackbeatTrack, store: LibraryStore) {
        setPracticeLoopEnd(currentRenderElapsed(store: store), track: track, store: store)
    }

    func clearPracticeLoop(track: BackbeatTrack, store: LibraryStore) {
        store.clearPracticeLoop()
        syncEngineSectionLoop(track: track, store: store)
    }

    func resetPracticePlayback(store: LibraryStore) {
        store.resetPracticeState()
        // Store-side clears must reach the engines — with wrap ownership in
        // the chain, a cleared store alone leaves audio looping A→B forever
        // (the route-change zombie loop); a nil on a chain-less engine is a
        // guarded no-op.
        singleFileEngine.setSectionLoop(nil)
        twoTrackMixEngine.setSectionLoop(nil)
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
            store.setPlaybackElapsed(currentRenderElapsed(store: store), duration: transportDuration(for: track))
        }
        singleFileEngine.pause()
        twoTrackMixEngine.pause()
        store.setPlaybackPlaying(false)
        stopTimer()
    }

    private func tickRenderEngine(_ engine: RenderPlaybackEngine, track: BackbeatTrack, store: LibraryStore) {
        let schedule = PracticePlaybackSchedule(
            duration: transportDuration(for: track),
            loopMode: store.practiceLoopMode,
            loopRange: store.practiceLoopRange,
            speed: store.practiceSpeed
        )
        switch schedule.tickAction(forElapsed: engine.currentElapsed()) {
        case .wrap(let target):
            // The chain owns the wrap (D-094); a transient float/debounce
            // .wrap must not flush it.
            if engine.isSectionLoopChainActive {
                store.setPlaybackElapsed(engine.currentElapsed(), duration: transportDuration(for: track))
            } else {
                try? engine.seek(to: target,
                                 autoplay: store.isPlaybackPlaying,
                                 volume: store.volume,
                                 speed: store.practiceSpeed,
                                 normalizationGainDB: store.normalizationGainDB(for: track))
                store.setPlaybackElapsed(target, duration: transportDuration(for: track))
            }
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
            store.setPlaybackElapsed(elapsed, duration: transportDuration(for: track))
        }
    }

    private func startTimer(interval: TimeInterval, _ action: @MainActor @Sendable @escaping () -> Void) {
        activeTickAction = action
        armTimer(interval: interval)
    }

    private func armTimer(interval: TimeInterval) {
        guard let action = activeTickAction else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        activeTickAction = nil
    }

    private func handlePlaybackInterrupted(elapsed: TimeInterval) {
        // An engine's audio graph was torn down by a hardware/format change.
        // Commit the real position and reflect paused so the transport isn't
        // left advancing over silence (F3); the next play rebuilds the graph.
        guard let store = activeStore, let track = store.nowPlayingTrack else { return }
        store.setPlaybackElapsed(elapsed, duration: transportDuration(for: track))
        store.setPlaybackPlaying(false)
        stopTimer()
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

    // The file-derived duration is authoritative whenever an engine is loaded
    // for this track; track.duration (AVFoundation's fast estimate, which
    // drifts on VBR sources) is only the fallback for pre-load, post-stop, and
    // engine-failure catch paths where the backend is nil (F1 companion fix).
    private func transportDuration(for track: BackbeatTrack) -> TimeInterval {
        activeRenderEngine(for: track)?.transportDuration ?? track.duration
    }

    private func syncEngineSectionLoop(track: BackbeatTrack, store: LibraryStore) {
        // The practice loop is global store state and the edit can arrive from
        // a detail view showing a DIFFERENT track (PracticeControlsView has no
        // now-playing gate): resolve through the controller's own mode — the
        // only truth about which engine is live. nowPlayingTrackID is NOT
        // usable here: a detail-view scrub sets it without starting playback,
        // which would strand the real engine's chain (zombie loop).
        guard case .render(let activeTrackID) = mode, let track = store.track(id: activeTrackID) else { return }
        guard let engine = activeRenderEngine(for: track) else { return }
        engine.setSectionLoop(effectiveSectionLoop(store: store))

        // Immediate UI snap, mirroring the old bounds-enforcement store write: the
        // engine's debounced rebuild lands ~120 ms later, but a playhead outside
        // the new range should reflect A right away. A range starting at/past the
        // file-derived duration degrades to run-to-end instead (Phase A).
        guard
            store.practiceLoopMode == .section,
            let range = store.practiceLoopRange
        else { return }
        let duration = transportDuration(for: track)
        guard range.start < duration else { return }
        let current = engine.currentElapsed()
        guard current < range.start || current >= range.end else { return }
        store.setPlaybackElapsed(range.start, duration: duration)
    }
}
