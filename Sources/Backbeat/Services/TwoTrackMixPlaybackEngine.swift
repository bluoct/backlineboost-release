import AVFoundation
import BackbeatCore
import Darwin
import Foundation

@MainActor
final class TwoTrackMixPlaybackEngine {
    private let engine = AVAudioEngine()
    private let drumlessNode = AVAudioPlayerNode()
    private let drumsNode = AVAudioPlayerNode()
    private let mixNode = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var drumlessFile: AVAudioFile?
    private var drumsFile: AVAudioFile?
    private var activeAsset: TwoTrackMixAsset?
    // The LIVE mix settings for the loaded pair. activeAsset.settings is a
    // load-time snapshot: drum-boost edits arrive mid-session through
    // setMixSettings, so every seek/restart must reapply the live value —
    // reapplying the snapshot audibly reverts a slider edit on scrub.
    private var activeMixSettings: DrumMixSettings?
    // Transport duration derived from the rendered files themselves, not the
    // persisted track.duration — that value is AVFoundation's fast estimate and
    // drifts on VBR sources, which used to block Drum Boost outright (F1).
    private var pairDuration: TimeInterval = 0
    private var clock = PlaybackTransportClock()
    private var isConfigured = false
    private var isPlaybackActive = false

    // Gapless A/B section-loop chain state (D-094): a pre-scheduled
    // scheduleSegment queue plays head→[A→B][A→B]… sample-contiguously across
    // both nodes in lockstep; see LoopPositionModel for the position mapping.
    private var chainModel: LoopPositionModel?
    private var chainGeneration: UInt64 = 0
    private var chainAppliedLoop: PracticeLoopRange?
    private var chainTargetDepth = 0
    private var queuedSegmentCount = 0
    private var lastChainElapsed: TimeInterval = 0
    private var activeSectionLoop: PracticeLoopRange?
    private var pendingLoopEditTask: Task<Void, Never>?
    private var activeSampleRate: Double = 0

    // Only mutated on the MainActor; read once in the nonisolated deinit under
    // exclusive access, so opting out of isolation checking is safe here.
    nonisolated(unsafe) private var configChangeObserver: (any NSObjectProtocol)?

    /// Invoked on the main actor when an AVAudioEngineConfigurationChange (an
    /// output-device or hardware-format change) forces the engine to stop, so
    /// the controller can commit the position and reflect the real (paused)
    /// state instead of leaving the UI "playing" silence (F3).
    var onPlaybackInterrupted: (@MainActor (TimeInterval) -> Void)?

    var isPlaying: Bool {
        drumlessNode.isPlaying || drumsNode.isPlaying
    }

    var transportDuration: TimeInterval { pairDuration }

    var isSectionLoopChainActive: Bool { chainModel != nil }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    func play(asset: TwoTrackMixAsset, startElapsed: TimeInterval, volume: Double, speed: Double, normalizationGainDB: Double, sectionLoop: PracticeLoopRange?) throws {
        if activeAsset?.trackID != asset.trackID ||
            activeAsset?.drumlessURL != asset.drumlessURL ||
            activeAsset?.drumsURL != asset.drumsURL {
            try load(asset: asset)
        }

        setOutputGain(volume: volume, normalizationGainDB: normalizationGainDB)
        setSpeed(speed)
        setMixSettings(asset.settings)

        activeSectionLoop = sectionLoop
        // A chain-valid resume preserves the pre-scheduled queue: same asset,
        // same loop, and the transport hasn't moved — no reschedule, no new
        // sync-start delay (D-094).
        let isChainResume = chainModel != nil
            && sectionLoop == chainAppliedLoop
            && abs(startElapsed - currentElapsed()) <= 0.05

        if isChainResume {
            // Resume: the pre-scheduled queue survives untouched.
        } else if let sectionLoop, buildChain(anchoredAt: startElapsed, range: sectionLoop, snapOutsideToStart: false) {
            // Fresh chain built; nothing more to schedule.
        } else {
            // Flush any stale chain BEFORE the linear schedule: the nodes'
            // stop() fires the queued completions, and without the generation
            // bump they would top the dead loop back up behind the linear tail.
            stopNodes()
            schedulePair(from: startElapsed)
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        // An engine-pause resume leaves both nodes frozen in playing state and
        // engine.start() resumes them in lockstep with no new sync delay.
        if !drumlessNode.isPlaying || !drumsNode.isPlaying {
            // AVAudioTime hostTime is in mach ticks, not nanoseconds; convert the
            // synchronized-start delay and shift the position clock by the same amount.
            let startDelay: TimeInterval = 0.02
            let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: startDelay))
            drumlessNode.play(at: startTime)
            drumsNode.play(at: startTime)
            clock.start(fromElapsed: startElapsed, duration: pairDuration, at: Date().addingTimeInterval(startDelay))
        } else {
            clock.start(fromElapsed: startElapsed, duration: pairDuration, at: Date())
        }
        isPlaybackActive = true
    }

    func pause() {
        // Commit elapsed BEFORE pausing; playerTime(forNodeTime:) goes invalid
        // once the engine stops rendering.
        let committed = currentElapsed()
        // Engine-level pause freezes the render for BOTH nodes atomically —
        // per-node pauses can straddle a render cycle and freeze the stems
        // ~11 ms apart, a desync a preserved queue would make permanent;
        // commit stays first per D-012.
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
        drumlessNode.stop()
        drumsNode.stop()
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
        // The live settings, not the asset's load-time snapshot: a scrub must
        // not audibly revert a mid-session drum-boost edit.
        let liveMixSettings = activeMixSettings ?? activeAsset.settings
        // Stop only the nodes; the A/B-loop wrap path seeks every iteration and
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
            // play(asset:) reapplies the snapshot settings of the asset it was
            // handed — for this internal restart that asset is the stale
            // activeAsset, so restore the live value on top.
            setMixSettings(liveMixSettings)
        } else {
            setOutputGain(volume: volume, normalizationGainDB: normalizationGainDB)
            setSpeed(speed)
            setMixSettings(liveMixSettings)
            if let range = activeSectionLoop, buildChain(anchoredAt: elapsed, range: range, snapOutsideToStart: false) {
            } else {
                schedulePair(from: elapsed)
            }
            clock.prepare(atElapsed: elapsed, duration: pairDuration)
        }
    }

    func currentElapsed() -> TimeInterval {
        if let chainModel {
            guard let frames = renderedFrames(on: drumlessNode) else { return lastChainElapsed }
            let position = chainModel.positionSeconds(forRenderedFrames: frames, sampleRate: activeSampleRate)
            lastChainElapsed = position
            return position
        }
        return clock.elapsed(renderedSeconds: renderedSeconds(on: drumlessNode))
    }

    func setMixSettings(_ settings: DrumMixSettings) {
        activeMixSettings = settings
        let gains = DrumBoostMixGains(boostDB: settings.boostDB)
        drumlessNode.volume = gains.backingLinearGain
        drumsNode.volume = gains.drumLinearGain
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

    func setSectionLoop(_ range: PracticeLoopRange?) {
        let hadPending = pendingLoopEditTask != nil
        pendingLoopEditTask?.cancel()
        pendingLoopEditTask = nil
        activeSectionLoop = range
        guard drumlessFile != nil, drumsFile != nil else { return }

        guard let range else {
            guard chainModel != nil else { return }
            dismantleChainToLinear()
            return
        }

        // A same-range call landing inside the debounce window must not cancel
        // the armed task and permanently drop the settling edit — the
        // hadPending conjunct keeps it alive.
        if !hadPending, chainModel != nil, range == chainAppliedLoop {
            return
        }

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

    private func load(asset: TwoTrackMixAsset) throws {
        configureGraphIfNeeded()
        let candidateDrumlessFile = try AVAudioFile(forReading: asset.drumlessURL)
        let candidateDrumsFile = try AVAudioFile(forReading: asset.drumsURL)

        try validatePair(drumlessFile: candidateDrumlessFile, drumsFile: candidateDrumsFile)

        drumlessFile = candidateDrumlessFile
        drumsFile = candidateDrumsFile
        activeAsset = asset
        // A fresh pair must not inherit the previous track's live settings;
        // play(asset:) re-seeds from the new asset right after load.
        activeMixSettings = nil
        // The rendered files are the source of truth for the timeline; the
        // shorter of the coherent pair bounds the transport (F1).
        let drumlessDuration = Double(candidateDrumlessFile.length) / candidateDrumlessFile.processingFormat.sampleRate
        let drumsDuration = Double(candidateDrumsFile.length) / candidateDrumsFile.processingFormat.sampleRate
        pairDuration = min(drumlessDuration, drumsDuration)
        // validatePair guarantees the pair's sample rates match.
        activeSampleRate = candidateDrumlessFile.processingFormat.sampleRate
        stopNodes()
        activeSectionLoop = nil
    }

    private func configureGraphIfNeeded() {
        guard !isConfigured else { return }

        engine.attach(drumlessNode)
        engine.attach(drumsNode)
        engine.attach(mixNode)
        engine.attach(timePitch)

        engine.connect(drumlessNode, to: mixNode, format: nil)
        engine.connect(drumsNode, to: mixNode, format: nil)
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
            // A paused preserved queue must not survive a hardware swap onto a
            // stale graph. Already paused, so no onPlaybackInterrupted — the
            // store position was already committed at pause.
            let committed = lastChainElapsed
            stopNodes()
            engine.stop()
            clock.prepare(atElapsed: committed, duration: pairDuration)
            return
        }
        guard isPlaybackActive else { return }
        let resumeElapsed = currentElapsed()
        stopNodes()
        engine.stop()
        // Re-anchor the zeroed clock at the committed position so engine
        // reads (marker capture, relative seeks) stay truthful while paused.
        clock.prepare(atElapsed: resumeElapsed, duration: pairDuration)
        onPlaybackInterrupted?(resumeElapsed)
    }

    // Validate the pair from the rendered files themselves — sample rate,
    // channel count, and Drums-vs-Drumless length coherence. The old
    // asset.duration ± 0.25 s gate consulted the persisted estimate and
    // permanently blocked Drum Boost when it drifted on VBR sources (F1); the
    // files are the source of truth, so that gate is gone.
    private func validatePair(drumlessFile: AVAudioFile, drumsFile: AVAudioFile) throws {
        let sampleRateDelta = abs(drumlessFile.processingFormat.sampleRate - drumsFile.processingFormat.sampleRate)
        let channelMatch = drumlessFile.processingFormat.channelCount == drumsFile.processingFormat.channelCount
        let drumlessDuration = Double(drumlessFile.length) / drumlessFile.processingFormat.sampleRate
        let drumsDuration = Double(drumsFile.length) / drumsFile.processingFormat.sampleRate

        guard sampleRateDelta < 0.001, channelMatch, abs(drumlessDuration - drumsDuration) <= 0.12 else {
            throw TwoTrackMixPlaybackError.incompatiblePair
        }
    }

    private func schedulePair(from elapsed: TimeInterval) {
        guard let drumlessFile, let drumsFile else { return }

        let boundedElapsed = min(max(0, elapsed), pairDuration)
        schedule(file: drumlessFile, on: drumlessNode, from: boundedElapsed)
        schedule(file: drumsFile, on: drumsNode, from: boundedElapsed)
    }

    private func schedule(file: AVAudioFile, on node: AVAudioPlayerNode, from elapsed: TimeInterval) {
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = min(max(0, AVAudioFramePosition(elapsed * sampleRate)), file.length)
        let frameCount = AVAudioFrameCount(max(0, file.length - startFrame))

        node.stop()
        if frameCount > 0 {
            node.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: frameCount,
                at: nil
            )
        }
    }

    private func renderedSeconds(on node: AVAudioPlayerNode) -> TimeInterval? {
        // A negative sampleTime occurs during the 20ms synchronized-start window;
        // clock.elapsed clamps it to 0.
        guard node.isPlaying,
              let nodeTime = node.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid,
              playerTime.sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func renderedFrames(on node: AVAudioPlayerNode) -> Int64? {
        // A negative sampleTime occurs during the 20ms synchronized-start window;
        // the model clamps negatives to the anchor.
        guard node.isPlaying,
              let nodeTime = node.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid,
              playerTime.sampleRate > 0 else { return nil }
        // The graph is connected format-nil, so the node's output rate can
        // differ from the file rate — convert into file-domain frames.
        return Int64((Double(playerTime.sampleTime) * activeSampleRate / playerTime.sampleRate).rounded())
    }

    private func buildChain(anchoredAt elapsed: TimeInterval, range: PracticeLoopRange, snapOutsideToStart: Bool) -> Bool {
        guard let drumlessFile, let drumsFile, activeSampleRate > 0 else { return false }

        // The loop chain is bounded by the coherent pair, never by
        // track.duration — the 0.12 s validatePair tolerance would otherwise
        // desync the stems.
        let pairFrameLimit = min(drumlessFile.length, drumsFile.length)
        let startFrame = LoopPositionModel.frame(forSeconds: range.start, sampleRate: activeSampleRate)
        let endFrame = min(LoopPositionModel.frame(forSeconds: range.end, sampleRate: activeSampleRate), pairFrameLimit)
        var anchorFrame = LoopPositionModel.frame(forSeconds: elapsed, sampleRate: activeSampleRate)
        if snapOutsideToStart && (anchorFrame < startFrame || anchorFrame >= endFrame) {
            anchorFrame = startFrame
        }
        let minimumFrames = Int64((0.05 * activeSampleRate).rounded(.up))

        // Pure precheck before any flush — a degenerate edit must never kill a
        // running schedule.
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

        let head = model.headFrames
        scheduleChainSegment(start: head.start, count: head.count, generation: chainGeneration)
        let iteration = model.iterationFrames
        for _ in 0..<min(2, chainTargetDepth) {
            scheduleChainSegment(start: iteration.start, count: iteration.count, generation: chainGeneration)
        }

        lastChainElapsed = Double(model.anchorFrame) / activeSampleRate
        return true
    }

    private func scheduleChainSegment(start: Int64, count: Int64, generation: UInt64) {
        guard let drumlessFile, let drumsFile, count > 0 else { return }
        queuedSegmentCount += 1
        // The .dataConsumed completion rides ONLY the drumless segment (the
        // position-reporting node) and tops up BOTH nodes; frame counts are
        // identical by construction so the stems stay lockstep.
        drumlessNode.scheduleSegment(
            drumlessFile,
            startingFrame: AVAudioFramePosition(start),
            frameCount: AVAudioFrameCount(count),
            at: nil,
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.topUpChain(inGeneration: generation)
            }
        }
        drumsNode.scheduleSegment(
            drumsFile,
            startingFrame: AVAudioFramePosition(start),
            frameCount: AVAudioFrameCount(count),
            at: nil
        )
    }

    private func topUpChain(inGeneration generation: UInt64) {
        guard let chainModel, chainModel.isCurrent(inGeneration: generation), generation == chainGeneration else { return }
        queuedSegmentCount -= 1
        while queuedSegmentCount < chainTargetDepth {
            let iteration = chainModel.iterationFrames
            scheduleChainSegment(start: iteration.start, count: iteration.count, generation: generation)
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
            dismantleChainToLinear()
        }
    }

    private func dismantleChainToLinear() {
        let wasActive = isPlaybackActive
        let current = currentElapsed()
        stopNodes()
        schedulePair(from: current)

        if wasActive, ensureEngineRunning() {
            let startDelay: TimeInterval = 0.02
            let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: startDelay))
            drumlessNode.play(at: startTime)
            drumsNode.play(at: startTime)
            clock.start(fromElapsed: current, duration: pairDuration, at: Date().addingTimeInterval(startDelay))
            isPlaybackActive = true
        } else {
            // Also the failed-start path: node.play() on a dead engine raises
            // an uncatchable NSException — stay paused at the committed
            // position instead.
            clock.prepare(atElapsed: current, duration: pairDuration)
        }
    }

    private func resumeChainPlayback() {
        // node.play() on a dead engine raises an uncatchable NSException;
        // stay paused-staged and let the next play() surface the failure.
        guard ensureEngineRunning() else { return }

        // A mixed node state should not occur; rebuild rather than start one
        // stem late.
        if drumlessNode.isPlaying != drumsNode.isPlaying {
            if let range = chainAppliedLoop {
                _ = buildChain(anchoredAt: lastChainElapsed, range: range, snapOutsideToStart: false)
            }
        }

        if !drumlessNode.isPlaying || !drumsNode.isPlaying {
            let startDelay: TimeInterval = 0.02
            let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: startDelay))
            drumlessNode.play(at: startTime)
            drumsNode.play(at: startTime)
        }
        isPlaybackActive = true
    }

    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        return (try? engine.start()) != nil
    }
}

enum TwoTrackMixPlaybackError: LocalizedError {
    case incompatiblePair

    var errorDescription: String? {
        switch self {
        case .incompatiblePair:
            "Drums and drumless files do not share a compatible timeline."
        }
    }
}
