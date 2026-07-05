import XCTest

final class TwoTrackMixPlaybackEngineSourceTests: XCTestCase {
    func testTwoTrackMixPlaybackEngineUsesOneEngineClockAndTwoPlayerNodes() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        XCTAssertTrue(source.contains("final class TwoTrackMixPlaybackEngine"))
        XCTAssertTrue(source.contains("private let engine = AVAudioEngine()"))
        XCTAssertTrue(source.contains("private let drumlessNode = AVAudioPlayerNode()"))
        XCTAssertTrue(source.contains("private let drumsNode = AVAudioPlayerNode()"))
        XCTAssertTrue(source.contains("private let timePitch = AVAudioUnitTimePitch()"))
        XCTAssertTrue(source.contains("func play(asset: TwoTrackMixAsset"))
        XCTAssertTrue(source.contains("func seek(to elapsed: TimeInterval"))
        XCTAssertTrue(source.contains("func setMixSettings(_ settings: DrumMixSettings"))
        XCTAssertTrue(source.contains("func setSpeed(_ speed: Double"))
    }

    func testSpeedChangesCommitElapsedBeforeChangingRate() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let speedMethod = try XCTUnwrap(source.range(of: "func setSpeed(_ speed: Double)"))
        let clockCall = try XCTUnwrap(source.range(of: "clock.setSpeed(", range: speedMethod.lowerBound..<source.endIndex))
        let rateAssignment = try XCTUnwrap(source.range(of: "timePitch.rate = Float(clock.speed)", range: speedMethod.lowerBound..<source.endIndex))
        XCTAssertLessThan(clockCall.lowerBound, rateAssignment.lowerBound)
    }

    func testLoadValidatesCandidateFilesBeforeMutatingActiveState() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        XCTAssertTrue(source.contains("let candidateDrumlessFile = try AVAudioFile(forReading: asset.drumlessURL)"))
        XCTAssertTrue(source.contains("let candidateDrumsFile = try AVAudioFile(forReading: asset.drumsURL)"))
        XCTAssertTrue(source.contains("try validatePair(asset: asset, drumlessFile: candidateDrumlessFile, drumsFile: candidateDrumsFile)"))

        let loadMethod = try XCTUnwrap(source.range(of: "private func load(asset: TwoTrackMixAsset) throws"))
        let validateCall = try XCTUnwrap(source.range(of: "try validatePair(asset: asset, drumlessFile: candidateDrumlessFile, drumsFile: candidateDrumsFile)", range: loadMethod.lowerBound..<source.endIndex))
        let drumlessAssignment = try XCTUnwrap(source.range(of: "drumlessFile = candidateDrumlessFile", range: loadMethod.lowerBound..<source.endIndex))
        let drumsAssignment = try XCTUnwrap(source.range(of: "drumsFile = candidateDrumsFile", range: loadMethod.lowerBound..<source.endIndex))
        let activeAssignment = try XCTUnwrap(source.range(of: "activeAsset = asset", range: loadMethod.lowerBound..<source.endIndex))

        XCTAssertLessThan(validateCall.lowerBound, drumlessAssignment.lowerBound)
        XCTAssertLessThan(validateCall.lowerBound, drumsAssignment.lowerBound)
        XCTAssertLessThan(validateCall.lowerBound, activeAssignment.lowerBound)
    }

    func testTwoTrackMixEngineAppliesNormalizationAtOutputStage() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        XCTAssertTrue(source.contains("normalizationGainDB"))
        XCTAssertTrue(source.contains("PlaybackNormalization.linearGain"))
        XCTAssertTrue(source.contains("setOutputGain(volume:"))
    }

    func testSynchronizedStartConvertsDelaySecondsToHostTicksAndOffsetsClock() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        XCTAssertTrue(source.contains("AVAudioTime.hostTime(forSeconds: startDelay)"))
        XCTAssertTrue(source.contains("clock.start(fromElapsed:"))
        XCTAssertTrue(source.contains("at: Date().addingTimeInterval(startDelay)"))
        XCTAssertFalse(
            source.contains("mach_absolute_time() + 20_000_000"),
            "hostTime is measured in mach ticks; adding a raw nanosecond count delays playback by ~0.83s on Apple Silicon"
        )
    }

    func testCurrentElapsedReadsNodeRenderPositionThroughTransportClock() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        XCTAssertTrue(source.contains("private var clock = PlaybackTransportClock()"))
        XCTAssertTrue(source.contains("playerTime(forNodeTime:"))
        XCTAssertTrue(source.contains("clock.elapsed(renderedSeconds:"))
    }

    func testPauseCommitsElapsedBeforePausingNodesThenPausesEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let pauseMethod = try XCTUnwrap(source.range(of: "func pause()"))
        let commit = try XCTUnwrap(source.range(of: "let committed = currentElapsed()", range: pauseMethod.lowerBound..<source.endIndex))
        let drumlessPause = try XCTUnwrap(source.range(of: "drumlessNode.pause()", range: pauseMethod.lowerBound..<source.endIndex))
        let drumsPause = try XCTUnwrap(source.range(of: "drumsNode.pause()", range: pauseMethod.lowerBound..<source.endIndex))
        let enginePause = try XCTUnwrap(source.range(of: "engine.pause()", range: pauseMethod.lowerBound..<source.endIndex))
        let clockPause = try XCTUnwrap(source.range(of: "clock.pause(committing: committed)", range: pauseMethod.lowerBound..<source.endIndex))

        XCTAssertLessThan(commit.lowerBound, drumlessPause.lowerBound)
        XCTAssertLessThan(drumlessPause.lowerBound, drumsPause.lowerBound)
        XCTAssertLessThan(drumsPause.lowerBound, enginePause.lowerBound)
        XCTAssertLessThan(enginePause.lowerBound, clockPause.lowerBound)
    }

    func testStopStopsNodesThenEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        XCTAssertTrue(source.contains("private func stopNodes()"))

        let stopMethod = try XCTUnwrap(source.range(of: "func stop()"))
        let nodesStop = try XCTUnwrap(source.range(of: "stopNodes()", range: stopMethod.upperBound..<source.endIndex))
        let engineStop = try XCTUnwrap(source.range(of: "engine.stop()", range: stopMethod.upperBound..<source.endIndex))

        XCTAssertLessThan(nodesStop.lowerBound, engineStop.lowerBound)
    }

    func testSeekStopsNodesWithoutStoppingEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let seekMethod = try XCTUnwrap(source.range(of: "func seek(to elapsed: TimeInterval"))
        let nextMethod = try XCTUnwrap(source.range(of: "\n    func ", range: seekMethod.upperBound..<source.endIndex))
        let seekBody = String(source[seekMethod.lowerBound..<nextMethod.lowerBound])

        XCTAssertTrue(seekBody.contains("stopNodes()"))
        XCTAssertFalse(
            seekBody.contains("engine.stop()"),
            "seek must not tear down the engine; the A/B-loop wrap path seeks every iteration"
        )
    }

    func testPlayPreparesEngineBeforeStarting() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let prepare = try XCTUnwrap(source.range(of: "engine.prepare()"))
        let start = try XCTUnwrap(source.range(of: "try engine.start()"))

        XCTAssertLessThan(prepare.lowerBound, start.lowerBound)
    }

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
