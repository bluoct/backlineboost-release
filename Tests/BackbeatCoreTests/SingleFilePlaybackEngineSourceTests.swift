import XCTest

final class SingleFilePlaybackEngineSourceTests: XCTestCase {
    func testSingleFilePlaybackEngineUsesAVAudioEngineGainStage() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        XCTAssertTrue(source.contains("final class SingleFilePlaybackEngine"))
        XCTAssertTrue(source.contains("AVAudioEngine"))
        XCTAssertTrue(source.contains("AVAudioPlayerNode"))
        XCTAssertTrue(source.contains("AVAudioUnitTimePitch"))
        XCTAssertTrue(source.contains("func play(asset: PlaybackAsset"))
        XCTAssertTrue(source.contains("normalizationGainDB"))
        XCTAssertTrue(source.contains("PlaybackNormalization.linearGain"))
    }

    func testCurrentElapsedReadsNodeRenderPositionThroughTransportClock() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        XCTAssertTrue(source.contains("private var clock = PlaybackTransportClock()"))
        XCTAssertTrue(source.contains("playerTime(forNodeTime:"))
        XCTAssertTrue(source.contains("clock.elapsed(renderedSeconds:"))
    }

    func testPauseCommitsElapsedBeforePausingNodeThenPausesEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let pauseMethod = try XCTUnwrap(source.range(of: "func pause()"))
        let commit = try XCTUnwrap(source.range(of: "let committed = currentElapsed()", range: pauseMethod.lowerBound..<source.endIndex))
        let nodePause = try XCTUnwrap(source.range(of: "playerNode.pause()", range: pauseMethod.lowerBound..<source.endIndex))
        let enginePause = try XCTUnwrap(source.range(of: "engine.pause()", range: pauseMethod.lowerBound..<source.endIndex))
        let clockPause = try XCTUnwrap(source.range(of: "clock.pause(committing: committed)", range: pauseMethod.lowerBound..<source.endIndex))

        XCTAssertLessThan(commit.lowerBound, nodePause.lowerBound)
        XCTAssertLessThan(nodePause.lowerBound, enginePause.lowerBound)
        XCTAssertLessThan(enginePause.lowerBound, clockPause.lowerBound)
    }

    func testStopStopsNodesThenEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        XCTAssertTrue(source.contains("private func stopNodes()"))

        let stopMethod = try XCTUnwrap(source.range(of: "func stop()"))
        let nodesStop = try XCTUnwrap(source.range(of: "stopNodes()", range: stopMethod.upperBound..<source.endIndex))
        let engineStop = try XCTUnwrap(source.range(of: "engine.stop()", range: stopMethod.upperBound..<source.endIndex))

        XCTAssertLessThan(nodesStop.lowerBound, engineStop.lowerBound)
    }

    func testSeekStopsNodesWithoutStoppingEngine() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

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
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let prepare = try XCTUnwrap(source.range(of: "engine.prepare()"))
        let start = try XCTUnwrap(source.range(of: "try engine.start()"))

        XCTAssertLessThan(prepare.lowerBound, start.lowerBound)
    }

    func testSpeedChangesCommitThroughTransportClock() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let speedMethod = try XCTUnwrap(source.range(of: "func setSpeed(_ speed: Double)"))
        let clockCall = try XCTUnwrap(source.range(of: "clock.setSpeed(", range: speedMethod.lowerBound..<source.endIndex))
        let rateAssignment = try XCTUnwrap(source.range(of: "timePitch.rate = Float(clock.speed)", range: speedMethod.lowerBound..<source.endIndex))

        XCTAssertLessThan(clockCall.lowerBound, rateAssignment.lowerBound)
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
