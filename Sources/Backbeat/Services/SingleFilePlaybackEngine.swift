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
    private var isConfigured = false

    var isPlaying: Bool {
        playerNode.isPlaying
    }

    func play(asset: PlaybackAsset, duration: TimeInterval, startElapsed: TimeInterval, volume: Double, speed: Double, normalizationGainDB: Double) throws {
        if activeAsset?.trackID != asset.trackID || activeAsset?.fileURL != asset.fileURL {
            try load(asset: asset, duration: duration)
        } else {
            activeDuration = max(0, duration)
        }

        setOutputGain(volume: volume, normalizationGainDB: normalizationGainDB)
        setSpeed(speed)
        schedule(from: startElapsed)

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        playerNode.play()
        clock.start(fromElapsed: startElapsed, duration: activeDuration)
    }

    func pause() {
        // Commit elapsed BEFORE pausing the node; playerTime(forNodeTime:) goes
        // invalid once the node stops playing.
        let committed = currentElapsed()
        playerNode.pause()
        engine.pause()
        clock.pause(committing: committed)
    }

    func stop() {
        stopNodes()
        engine.stop()
    }

    private func stopNodes() {
        playerNode.stop()
        clock.stop()
    }

    func seek(to elapsed: TimeInterval, autoplay: Bool, volume: Double, speed: Double, normalizationGainDB: Double) throws {
        guard let activeAsset else { return }
        // Stop only the node; the A/B-loop wrap path seeks every iteration and
        // must not tear down the running engine.
        stopNodes()

        if autoplay {
            try play(
                asset: activeAsset,
                duration: activeDuration,
                startElapsed: elapsed,
                volume: volume,
                speed: speed,
                normalizationGainDB: normalizationGainDB
            )
        } else {
            setOutputGain(volume: volume, normalizationGainDB: normalizationGainDB)
            setSpeed(speed)
            schedule(from: elapsed)
            clock.prepare(atElapsed: elapsed, duration: activeDuration)
        }
    }

    func currentElapsed() -> TimeInterval {
        clock.elapsed(renderedSeconds: renderedSeconds(on: playerNode))
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

    private func load(asset: PlaybackAsset, duration: TimeInterval) throws {
        configureGraphIfNeeded()
        audioFile = try AVAudioFile(forReading: asset.fileURL)
        activeAsset = asset
        activeDuration = max(0, duration)
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

    private func renderedSeconds(on node: AVAudioPlayerNode) -> TimeInterval? {
        guard node.isPlaying,
              let nodeTime = node.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid,
              playerTime.sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
