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
    private var clock = PlaybackTransportClock()
    private var isConfigured = false

    var isPlaying: Bool {
        drumlessNode.isPlaying || drumsNode.isPlaying
    }

    func play(asset: TwoTrackMixAsset, startElapsed: TimeInterval, volume: Double, speed: Double, normalizationGainDB: Double) throws {
        if activeAsset?.trackID != asset.trackID ||
            activeAsset?.drumlessURL != asset.drumlessURL ||
            activeAsset?.drumsURL != asset.drumsURL {
            try load(asset: asset)
        }

        setOutputGain(volume: volume, normalizationGainDB: normalizationGainDB)
        setSpeed(speed)
        setMixSettings(asset.settings)
        schedulePair(from: startElapsed)

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        // AVAudioTime hostTime is in mach ticks, not nanoseconds; convert the
        // synchronized-start delay and shift the position clock by the same amount.
        let startDelay: TimeInterval = 0.02
        let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: startDelay))
        drumlessNode.play(at: startTime)
        drumsNode.play(at: startTime)
        clock.start(fromElapsed: startElapsed, duration: activeAsset?.duration ?? 0, at: Date().addingTimeInterval(startDelay))
    }

    func pause() {
        // Commit elapsed BEFORE pausing the nodes; playerTime(forNodeTime:) goes
        // invalid once the nodes stop playing.
        let committed = currentElapsed()
        drumlessNode.pause()
        drumsNode.pause()
        engine.pause()
        clock.pause(committing: committed)
    }

    func stop() {
        stopNodes()
        engine.stop()
    }

    private func stopNodes() {
        drumlessNode.stop()
        drumsNode.stop()
        clock.stop()
    }

    func seek(to elapsed: TimeInterval, autoplay: Bool, volume: Double, speed: Double, normalizationGainDB: Double) throws {
        guard let activeAsset else { return }
        // Stop only the nodes; the A/B-loop wrap path seeks every iteration and
        // must not tear down the running engine.
        stopNodes()

        if autoplay {
            try play(
                asset: activeAsset,
                startElapsed: elapsed,
                volume: volume,
                speed: speed,
                normalizationGainDB: normalizationGainDB
            )
        } else {
            setOutputGain(volume: volume, normalizationGainDB: normalizationGainDB)
            setSpeed(speed)
            setMixSettings(activeAsset.settings)
            schedulePair(from: elapsed)
            clock.prepare(atElapsed: elapsed, duration: activeAsset.duration)
        }
    }

    func currentElapsed() -> TimeInterval {
        clock.elapsed(renderedSeconds: renderedSeconds(on: drumlessNode))
    }

    func setMixSettings(_ settings: DrumMixSettings) {
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

    private func load(asset: TwoTrackMixAsset) throws {
        configureGraphIfNeeded()
        let candidateDrumlessFile = try AVAudioFile(forReading: asset.drumlessURL)
        let candidateDrumsFile = try AVAudioFile(forReading: asset.drumsURL)

        try validatePair(asset: asset, drumlessFile: candidateDrumlessFile, drumsFile: candidateDrumsFile)

        drumlessFile = candidateDrumlessFile
        drumsFile = candidateDrumsFile
        activeAsset = asset
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
    }

    private func validatePair(asset: TwoTrackMixAsset, drumlessFile: AVAudioFile, drumsFile: AVAudioFile) throws {
        let sampleRateDelta = abs(drumlessFile.processingFormat.sampleRate - drumsFile.processingFormat.sampleRate)
        let channelMatch = drumlessFile.processingFormat.channelCount == drumsFile.processingFormat.channelCount
        let drumlessDuration = Double(drumlessFile.length) / drumlessFile.processingFormat.sampleRate
        let drumsDuration = Double(drumsFile.length) / drumsFile.processingFormat.sampleRate

        guard sampleRateDelta < 0.001, channelMatch, abs(drumlessDuration - drumsDuration) <= 0.12 else {
            throw TwoTrackMixPlaybackError.incompatiblePair
        }
        guard abs(asset.duration - min(drumlessDuration, drumsDuration)) <= 0.25 else {
            throw TwoTrackMixPlaybackError.incompatiblePair
        }
    }

    private func schedulePair(from elapsed: TimeInterval) {
        guard let drumlessFile, let drumsFile else { return }

        let boundedElapsed = min(max(0, elapsed), activeAsset?.duration ?? elapsed)
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
