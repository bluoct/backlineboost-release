import AVFoundation
import BackbeatCore
import Foundation

@MainActor
final class SingleFilePlaybackEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let mixNode = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var audioFile: AVAudioFile?
    private var activeAsset: PlaybackAsset?
    private var activeDuration: TimeInterval = 0
    private var clock = PlaybackTransportClock()
    private var chainModel: LoopPositionModel?
    private var chainGeneration: UInt64 = 0
    private var chainAppliedLoop: PracticeLoopRange?
    private var chainTargetDepth = 0
    private var queuedSegmentCount = 0
    private var lastChainElapsed: TimeInterval = 0
    private var activeSectionLoop: PracticeLoopRange?
    private var pendingLoopEditTask: Task<Void, Never>?
    private var activeSampleRate: Double = 0
    private var isConfigured = false
    private var isPlaybackActive = false
    // Only mutated on the MainActor; read once in the nonisolated deinit under
    // exclusive access, so opting out of isolation checking is safe here.
    nonisolated(unsafe) private var configChangeObserver: (any NSObjectProtocol)?

    /// Invoked on the main actor when an AVAudioEngineConfigurationChange (an
    /// output-device or hardware-format change) forces the engine to stop, so
    /// the controller can commit the position and reflect the real (paused)
    /// state instead of leaving the UI "playing" silence (F3).
    var onPlaybackInterrupted: (@MainActor (TimeInterval) -> Void)?

    var isPlaying: Bool {
        playerNode.isPlaying
    }

    var transportDuration: TimeInterval { activeDuration }

    var isSectionLoopChainActive: Bool { chainModel != nil }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    func play(asset: PlaybackAsset, startElapsed: TimeInterval, volume: Double, speed: Double, normalizationGainDB: Double, sectionLoop: PracticeLoopRange?) throws {
        if activeAsset?.trackID != asset.trackID || activeAsset?.fileURL != asset.fileURL {
            try load(asset: asset)
        }

        setOutputGain(volume: volume, normalizationGainDB: normalizationGainDB)
        setSpeed(speed)

        activeSectionLoop = sectionLoop
        let isChainResume = chainModel != nil && sectionLoop == chainAppliedLoop && abs(startElapsed - currentElapsed()) <= 0.05
        if isChainResume {
            // The pre-scheduled loop chain survives pause; re-scheduling would
            // destroy the gapless queue (D-094).
        } else if let sectionLoop, buildChain(anchoredAt: startElapsed, range: sectionLoop, snapOutsideToStart: false) {
            // Chain built.
        } else {
            // Flush any stale chain BEFORE the linear schedule: schedule's own
            // node.stop() fires the queued completions, and without the
            // generation bump they would top the dead loop back up behind the
            // linear tail.
            stopNodes()
            schedule(from: startElapsed)
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        // Engine-pause resume leaves the node in playing state.
        if !playerNode.isPlaying {
            playerNode.play()
        }

        clock.start(fromElapsed: startElapsed, duration: activeDuration)
        isPlaybackActive = true
    }

    func pause() {
        // Commit elapsed BEFORE pausing. Engine-level pause freezes the render
        // atomically and preserves the node's scheduled queue (the chain
        // survives to resume); commit stays first per D-012.
        let committed = currentElapsed()
        engine.pause()
        clock.pause(committing: committed)
        if chainModel != nil {
            lastChainElapsed = committed
        }
        isPlaybackActive = false
    }

    func stop() {
        stopNodes()
        engine.stop()
        activeSectionLoop = nil
    }

    private func stopNodes() {
        playerNode.stop()
        clock.stop()
        isPlaybackActive = false
        chainGeneration &+= 1
        chainModel = nil
        chainAppliedLoop = nil
        queuedSegmentCount = 0
        pendingLoopEditTask?.cancel()
        pendingLoopEditTask = nil
    }

    func seek(to elapsed: TimeInterval, autoplay: Bool, volume: Double, speed: Double, normalizationGainDB: Double) throws {
        guard let activeAsset else { return }
        // Stop only the node; the A/B-loop wrap path seeks every iteration and
        // must not tear down the running engine.
        stopNodes()

        if autoplay {
            try play(
                asset: activeAsset,
                startElapsed: elapsed,
                volume: volume,
                speed: speed,
                normalizationGainDB: normalizationGainDB,
                sectionLoop: activeSectionLoop
            )
        } else {
            setOutputGain(volume: volume, normalizationGainDB: normalizationGainDB)
            setSpeed(speed)
            if let range = activeSectionLoop, buildChain(anchoredAt: elapsed, range: range, snapOutsideToStart: false) {
                // Chain rebuilt.
            } else {
                schedule(from: elapsed)
            }
            clock.prepare(atElapsed: elapsed, duration: activeDuration)
        }
    }

    func setSectionLoop(_ range: PracticeLoopRange?) {
        // Without hadPending, a same-range call landing inside the debounce
        // window would cancel the armed task and permanently drop the
        // settling edit.
        let hadPending = pendingLoopEditTask != nil
        pendingLoopEditTask?.cancel()
        pendingLoopEditTask = nil
        activeSectionLoop = range

        guard audioFile != nil else { return }

        guard let range else {
            guard chainModel != nil else { return }
            dismantleChainToLinear()
            return
        }

        if !hadPending && chainModel != nil && range == chainAppliedLoop {
            return
        }

        // Per-pixel handle drags coalesce behind a ~120 ms trailing debounce;
        // audio loops the prior bounds until the edit settles.
        pendingLoopEditTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            // Clear the handle BEFORE applying: hadPending means "an edit is
            // actually in flight" — a stale non-nil handle would permanently
            // defeat the same-range no-op guard above.
            self?.pendingLoopEditTask = nil
            self?.applySectionLoopEdit()
        }
    }

    func currentElapsed() -> TimeInterval {
        if let chainModel {
            // Reads can return nil while the engine is paused — the cache is
            // load-bearing, not an optimization.
            guard let frames = renderedFrames(on: playerNode) else { return lastChainElapsed }
            let position = chainModel.positionSeconds(forRenderedFrames: frames, sampleRate: activeSampleRate)
            lastChainElapsed = position
            return position
        }
        return clock.elapsed(renderedSeconds: renderedSeconds(on: playerNode))
    }

    func setOutputGain(volume: Double, normalizationGainDB: Double) {
        let userVolume = Float(min(1, max(0, volume)))
        let normalization = PlaybackNormalization.linearGain(fromDB: normalizationGainDB)
        mixNode.outputVolume = userVolume * normalization
    }

    func setSpeed(_ speed: Double) {
        clock.setSpeed(speed, committing: currentElapsed())
        timePitch.rate = Float(clock.speed)
    }

    private func load(asset: PlaybackAsset) throws {
        configureGraphIfNeeded()
        let file = try AVAudioFile(forReading: asset.fileURL)
        audioFile = file
        activeAsset = asset
        // The rendered/imported file is the source of truth for the timeline;
        // the persisted track.duration is AVFoundation's fast estimate and
        // drifts on VBR sources (F1).
        let sampleRate = file.processingFormat.sampleRate
        activeDuration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        activeSampleRate = sampleRate
        stopNodes()
        activeSectionLoop = nil
    }

    private func configureGraphIfNeeded() {
        guard !isConfigured else { return }

        engine.attach(playerNode)
        engine.attach(mixNode)
        engine.attach(timePitch)

        engine.connect(playerNode, to: mixNode, format: nil)
        engine.connect(mixNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        isConfigured = true
        observeConfigurationChanges()
    }

    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    private func handleConfigurationChange() {
        // A hardware/format change stops the engine's render and silently kills
        // audio while the wall clock keeps advancing. Commit the real position
        // and stop cleanly so the UI reflects paused; the next play rebuilds the
        // graph on the new hardware (F3).
        if !isPlaybackActive, chainModel != nil {
            // A paused preserved queue must not survive a hardware swap; flush
            // it (no onPlaybackInterrupted — already paused, position already
            // committed).
            let committed = lastChainElapsed
            stopNodes()
            engine.stop()
            clock.prepare(atElapsed: committed, duration: activeDuration)
            return
        }
        guard isPlaybackActive else { return }
        let resumeElapsed = currentElapsed()
        stopNodes()
        engine.stop()
        // Re-anchor the zeroed clock at the committed position so engine
        // reads (marker capture, relative seeks) stay truthful while paused.
        clock.prepare(atElapsed: resumeElapsed, duration: activeDuration)
        onPlaybackInterrupted?(resumeElapsed)
    }

    private func schedule(from elapsed: TimeInterval) {
        guard let audioFile else { return }

        let boundedElapsed = min(max(0, elapsed), activeDuration)
        let sampleRate = audioFile.processingFormat.sampleRate
        let startFrame = min(max(0, AVAudioFramePosition(boundedElapsed * sampleRate)), audioFile.length)
        let frameCount = AVAudioFrameCount(max(0, audioFile.length - startFrame))

        playerNode.stop()
        if frameCount > 0 {
            playerNode.scheduleSegment(
                audioFile,
                startingFrame: startFrame,
                frameCount: frameCount,
                at: nil
            )
        }
    }

    private func buildChain(anchoredAt elapsed: TimeInterval, range: PracticeLoopRange, snapOutsideToStart: Bool) -> Bool {
        guard let audioFile, activeSampleRate > 0 else { return false }

        let startFrame = LoopPositionModel.frame(forSeconds: range.start, sampleRate: activeSampleRate)
        let endFrame = min(LoopPositionModel.frame(forSeconds: range.end, sampleRate: activeSampleRate), audioFile.length)
        var anchorFrame = LoopPositionModel.frame(forSeconds: elapsed, sampleRate: activeSampleRate)
        if snapOutsideToStart && (anchorFrame < startFrame || anchorFrame >= endFrame) {
            anchorFrame = startFrame
        }
        let minimumFrames = Int64((0.05 * activeSampleRate).rounded(.up))

        // A degenerate edit must never kill a running schedule.
        guard LoopPositionModel.validated(
            loopStartFrame: startFrame,
            loopEndFrame: endFrame,
            anchorFrame: anchorFrame,
            generation: chainGeneration &+ 1,
            minimumFrameCount: minimumFrames
        ) != nil else { return false }

        stopNodes()

        guard let model = LoopPositionModel.validated(
            loopStartFrame: startFrame,
            loopEndFrame: endFrame,
            anchorFrame: anchorFrame,
            generation: chainGeneration,
            minimumFrameCount: minimumFrames
        ) else { return false }

        chainModel = model
        chainAppliedLoop = range
        chainTargetDepth = model.iterationsToKeepQueued(sampleRate: activeSampleRate)
        scheduleChainSegment(start: model.headFrames.start, count: model.headFrames.count, generation: model.generation)
        for _ in 0..<min(2, chainTargetDepth) {
            scheduleChainSegment(start: model.iterationFrames.start, count: model.iterationFrames.count, generation: model.generation)
        }
        lastChainElapsed = Double(model.anchorFrame) / activeSampleRate
        return true
    }

    private func scheduleChainSegment(start: Int64, count: Int64, generation: UInt64) {
        guard let audioFile, count > 0 else { return }
        queuedSegmentCount += 1
        playerNode.scheduleSegment(
            audioFile,
            startingFrame: AVAudioFramePosition(start),
            frameCount: AVAudioFrameCount(count),
            at: nil,
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.topUpChain(inGeneration: generation)
            }
        }
    }

    private func topUpChain(inGeneration generation: UInt64) {
        // Completions fire for flushed segments on node.stop() — stale
        // generations are dropped, ending the recursion.
        guard let chainModel, chainModel.isCurrent(inGeneration: generation), generation == chainGeneration else { return }
        queuedSegmentCount -= 1
        while queuedSegmentCount < chainTargetDepth {
            scheduleChainSegment(start: chainModel.iterationFrames.start, count: chainModel.iterationFrames.count, generation: generation)
        }
    }

    private func applySectionLoopEdit() {
        guard let range = activeSectionLoop else { return }
        // A drag that settles back on the applied bounds needs no rebuild —
        // the live chain already renders exactly this loop (D-094: a no-op
        // edit must not glitch the seam).
        if chainModel != nil, range == chainAppliedLoop { return }
        let wasActive = isPlaybackActive
        if buildChain(anchoredAt: currentElapsed(), range: range, snapOutsideToStart: true) {
            if wasActive {
                resumeChainPlayback()
            }
        } else if chainModel != nil {
            // A degenerate edit with no prior chain leaves linear playback
            // untouched.
            dismantleChainToLinear()
        }
    }

    private func dismantleChainToLinear() {
        let wasActive = isPlaybackActive
        let current = currentElapsed()
        stopNodes()
        schedule(from: current)
        if wasActive, ensureEngineRunning() {
            playerNode.play()
            clock.start(fromElapsed: current, duration: activeDuration)
            isPlaybackActive = true
        } else {
            // Also the failed-start path: node.play() on a dead engine raises
            // an uncatchable NSException — stay paused at the committed
            // position instead.
            clock.prepare(atElapsed: current, duration: activeDuration)
        }
    }

    private func resumeChainPlayback() {
        // node.play() on a dead engine raises an uncatchable NSException;
        // stay paused-staged and let the next play() surface the failure.
        guard ensureEngineRunning() else { return }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        isPlaybackActive = true
    }

    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        return (try? engine.start()) != nil
    }

    private func renderedSeconds(on node: AVAudioPlayerNode) -> TimeInterval? {
        guard node.isPlaying,
              let nodeTime = node.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid,
              playerTime.sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func renderedFrames(on node: AVAudioPlayerNode) -> Int64? {
        guard node.isPlaying,
              let nodeTime = node.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid,
              playerTime.sampleRate > 0 else { return nil }
        // The graph is connected format-nil so the node's output rate can
        // differ from the file rate; raw sampleTime is not file-domain.
        return Int64((Double(playerTime.sampleTime) * activeSampleRate / playerTime.sampleRate).rounded())
    }
}
