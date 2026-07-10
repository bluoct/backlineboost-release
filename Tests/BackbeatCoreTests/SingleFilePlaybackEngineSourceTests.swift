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

    func testTransportDurationIsDerivedFromTheAudioFileNotACallerSuppliedValue() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        XCTAssertTrue(
            source.contains("var transportDuration: TimeInterval { activeDuration }"),
            "The controller must be able to read the file-derived duration off the engine (F1 companion fix)."
        )
        XCTAssertFalse(
            source.contains("func play(asset: PlaybackAsset, duration:"),
            "play(...) must no longer accept a caller-supplied duration; the file is the source of truth."
        )
        XCTAssertTrue(
            source.contains("private func load(asset: PlaybackAsset) throws"),
            "load(asset:) must no longer take a duration parameter either."
        )
        XCTAssertTrue(
            source.contains("activeDuration = sampleRate > 0 ? Double(file.length) / sampleRate : 0"),
            "activeDuration must be derived from the loaded file's length and sample rate, guarding a zero sample rate."
        )
    }

    func testCurrentElapsedReadsNodeRenderPositionThroughTransportClock() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        XCTAssertTrue(source.contains("private var clock = PlaybackTransportClock()"))
        XCTAssertTrue(source.contains("playerTime(forNodeTime:"))
        XCTAssertTrue(source.contains("clock.elapsed(renderedSeconds:"))
    }

    func testPauseCommitsElapsedThenPausesEngineOnlyPreservingTheNodeQueue() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let pauseBody = try methodBody(source, signature: "func pause()")
        let commit = try XCTUnwrap(pauseBody.range(of: "let committed = currentElapsed()"))
        let enginePause = try XCTUnwrap(pauseBody.range(of: "engine.pause()"))
        let clockPause = try XCTUnwrap(pauseBody.range(of: "clock.pause(committing: committed)"))

        XCTAssertLessThan(commit.lowerBound, enginePause.lowerBound)
        XCTAssertLessThan(enginePause.lowerBound, clockPause.lowerBound)
        XCTAssertFalse(
            pauseBody.contains("playerNode.pause()"),
            "Engine-level pause freezes the render atomically and preserves the scheduled chain queue; commit-first per D-012."
        )
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

    func testEngineObservesHardwareConfigurationChanges() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        XCTAssertTrue(
            source.contains("AVAudioEngineConfigurationChange"),
            "An output-device or hardware-format change stops the engine and silently kills audio; it must be observed (F3)."
        )
        XCTAssertTrue(
            source.contains("onPlaybackInterrupted"),
            "The engine must report an interruption so the controller can reflect paused instead of 'playing' silence (F3)."
        )
    }

    func testBuildChainSchedulesTheHeadSegmentWithDataConsumedCompletion() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let buildChainBody = try methodBody(source, signature: "private func buildChain(anchoredAt elapsed: TimeInterval, range: PracticeLoopRange, snapOutsideToStart: Bool) -> Bool")
        XCTAssertTrue(
            buildChainBody.contains("model.headFrames"),
            "The head segment (anchor→B truncated) is the segment plan the gapless chain schedules from."
        )
        XCTAssertTrue(
            buildChainBody.contains("iterationsToKeepQueued(sampleRate:"),
            "The queue depth is adaptive, derived from the model, not a fixed constant."
        )

        let scheduleChainSegmentBody = try methodBody(source, signature: "private func scheduleChainSegment(start: Int64, count: Int64, generation: UInt64)")
        XCTAssertTrue(
            scheduleChainSegmentBody.contains("completionCallbackType: .dataConsumed"),
            "The gapless chain relies on .dataConsumed completions to top itself up; .dataRendered would fire too early."
        )
    }

    func testChainCompletionHopsToMainActorAndTopUpGuardsGeneration() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let scheduleChainSegmentBody = try methodBody(source, signature: "private func scheduleChainSegment(start: Int64, count: Int64, generation: UInt64)")
        XCTAssertTrue(
            scheduleChainSegmentBody.contains("Task { @MainActor [weak self] in"),
            "The completion handler crosses off the AVAudioEngine render thread onto the main actor with [weak self] on both hops (D-096)."
        )

        let topUpChainBody = try methodBody(source, signature: "private func topUpChain(inGeneration generation: UInt64)")
        XCTAssertTrue(
            topUpChainBody.contains("isCurrent(inGeneration:"),
            "Completions fire for flushed segments on node.stop() too — stale generations must be dropped, ending the recursion."
        )
        XCTAssertTrue(
            topUpChainBody.contains("generation == chainGeneration"),
            "The completion's captured generation must also match the engine's current generation, not just the model's."
        )
    }

    func testTopUpChainRefillsToTheDepthTarget() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let topUpChainBody = try methodBody(source, signature: "private func topUpChain(inGeneration generation: UInt64)")
        XCTAssertTrue(
            topUpChainBody.contains("while queuedSegmentCount < chainTargetDepth"),
            "Each completion tops up to the target depth rather than scheduling exactly one — self-healing if a completion is ever lost."
        )
    }

    func testStopNodesInvalidatesTheChainGeneration() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let stopNodesBody = try methodBody(source, signature: "private func stopNodes()")
        XCTAssertTrue(
            stopNodesBody.contains("chainGeneration &+= 1"),
            "Every flush path (seek, stop, config change, rebuild, loop-off) must invalidate the chain generation in one place."
        )
        XCTAssertTrue(
            stopNodesBody.contains("chainModel = nil"),
            "A flushed chain must not be mistaken for a live one by currentElapsed() or a subsequent play()."
        )
    }

    func testPlayGuardsAChainValidResumeBeforeAnyScheduling() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let playBody = try methodBody(source, signature: "func play(asset: PlaybackAsset, startElapsed: TimeInterval, volume: Double, speed: Double, normalizationGainDB: Double, sectionLoop: PracticeLoopRange?) throws")
        XCTAssertTrue(
            playBody.contains("let isChainResume = chainModel != nil"),
            "A same-asset, same-loop, position-close resume must preserve the pre-scheduled queue instead of rescheduling (D-094)."
        )

        let stopNodesCall = try XCTUnwrap(playBody.range(of: "stopNodes()"))
        let scheduleCall = try XCTUnwrap(playBody.range(of: "schedule(from: startElapsed)"))
        XCTAssertLessThan(
            stopNodesCall.lowerBound,
            scheduleCall.lowerBound,
            "A stale chain must be flushed before a linear schedule; otherwise its dead-loop completions top it back up behind the linear tail."
        )
    }

    func testSetSectionLoopCapturesHadPendingBeforeCancelling() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let setSectionLoopBody = try methodBody(source, signature: "func setSectionLoop(_ range: PracticeLoopRange?)")
        XCTAssertTrue(
            setSectionLoopBody.contains("let hadPending = pendingLoopEditTask != nil"),
            "Without hadPending, a same-range call landing inside the debounce window would cancel the armed task and permanently drop the settling edit."
        )
        XCTAssertTrue(
            setSectionLoopBody.contains("pendingLoopEditTask = Task { @MainActor [weak self] in"),
            "Per-pixel bounds drags coalesce behind a trailing debounce before rebuilding the chain."
        )
    }

    func testCurrentElapsedPrefersTheChainModelOverTheTransportClock() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let currentElapsedBody = try methodBody(source, signature: "func currentElapsed() -> TimeInterval")
        XCTAssertTrue(
            currentElapsedBody.contains("if let chainModel"),
            "While a chain is active, position must come from the model's frame mapping, not the linear transport clock."
        )
        XCTAssertTrue(
            currentElapsedBody.contains("clock.elapsed(renderedSeconds:"),
            "The no-chain path must still fall back to the existing transport clock read."
        )
    }

    func testRenderedFramesConvertsIntoFileDomainFrames() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let renderedFramesBody = try methodBody(source, signature: "private func renderedFrames(on node: AVAudioPlayerNode) -> Int64?")
        XCTAssertTrue(
            renderedFramesBody.contains("activeSampleRate / playerTime.sampleRate"),
            "The graph is connected format-nil, so the node's output rate can differ from the file rate; raw sampleTime is not file-domain."
        )
    }

    func testBuildChainValidatesBeforeFlushingTheRunningSchedule() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let buildChainBody = try methodBody(source, signature: "private func buildChain(anchoredAt elapsed: TimeInterval, range: PracticeLoopRange, snapOutsideToStart: Bool) -> Bool")
        let firstValidate = try XCTUnwrap(buildChainBody.range(of: "LoopPositionModel.validated("))
        let flush = try XCTUnwrap(buildChainBody.range(of: "stopNodes()"))
        XCTAssertLessThan(
            firstValidate.lowerBound,
            flush.lowerBound,
            "A degenerate edit must never kill a running schedule — validate as a pure precheck before flushing."
        )
    }

    func testHandleConfigurationChangeFlushesAPausedChain() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let handleConfigurationChangeBody = try methodBody(source, signature: "private func handleConfigurationChange()")
        XCTAssertTrue(
            handleConfigurationChangeBody.contains("if !isPlaybackActive, chainModel != nil"),
            "A paused preserved queue must not survive a hardware swap onto a stale graph."
        )
    }

    func testHandleConfigurationChangeReanchorsTheClockAtTheCommittedPosition() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let handleConfigurationChangeBody = try methodBody(source, signature: "private func handleConfigurationChange()")
        XCTAssertTrue(
            handleConfigurationChangeBody.contains("clock.prepare(atElapsed: resumeElapsed"),
            "stopNodes zeroes the clock; without re-anchoring, engine reads after an interruption (marker capture, relative seeks) report 0:00 instead of the committed position."
        )
    }

    func testDebounceHandleClearsOnSettleAndOnFlush() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let setSectionLoopBody = try methodBody(source, signature: "func setSectionLoop(_ range: PracticeLoopRange?)")
        XCTAssertTrue(
            setSectionLoopBody.contains("self?.pendingLoopEditTask = nil"),
            "The debounce body must clear the handle before applying: a stale non-nil handle keeps hadPending permanently true and the same-range no-op guard dead — every no-op edit would rebuild the live chain (audible glitch, D-094)."
        )
        let stopNodesBody = try methodBody(source, signature: "private func stopNodes()")
        XCTAssertTrue(
            stopNodesBody.contains("pendingLoopEditTask = nil"),
            "stopNodes must nil the handle, not just cancel it — a cancelled Task is still non-nil and poisons hadPending."
        )
    }

    func testApplySectionLoopEditSkipsSameRangeRebuilds() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let applyBody = try methodBody(source, signature: "private func applySectionLoopEdit()")
        XCTAssertTrue(
            applyBody.contains("range == chainAppliedLoop"),
            "A drag that settles back on the applied bounds must not tear down a chain already rendering exactly that loop (D-094: no-op edits must not glitch the seam)."
        )
    }

    func testAnchorSnapAppliesOnlyToSettledBoundsEdits() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let playBody = try methodBody(source, signature: "func play(asset: PlaybackAsset, startElapsed: TimeInterval, volume: Double, speed: Double, normalizationGainDB: Double, sectionLoop: PracticeLoopRange?) throws")
        XCTAssertTrue(
            playBody.contains("snapOutsideToStart: false"),
            "Play/seek anchors keep today's pre-roll UX (below A plays through to B); only settled bounds edits snap."
        )
        let seekBody = try methodBody(source, signature: "func seek(to elapsed: TimeInterval, autoplay: Bool, volume: Double, speed: Double, normalizationGainDB: Double) throws")
        XCTAssertTrue(seekBody.contains("snapOutsideToStart: false"))
        let applyBody = try methodBody(source, signature: "private func applySectionLoopEdit()")
        XCTAssertTrue(
            applyBody.contains("snapOutsideToStart: true"),
            "A bounds edit with the playhead outside the new range snaps to A — the old enforcePracticeLoopBounds contract."
        )
    }

    func testSeekPreservesTheActiveSectionLoop() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        let seekBody = try methodBody(source, signature: "func seek(to elapsed: TimeInterval, autoplay: Bool, volume: Double, speed: Double, normalizationGainDB: Double) throws")
        XCTAssertTrue(
            seekBody.contains("sectionLoop: activeSectionLoop"),
            "A scrub during an active loop must rebuild the chain, not silently drop the loop."
        )
    }

    func testEngineStartFailureNeverReachesNodePlay() throws {
        let source = try readSource("Sources/Backbeat/Services/SingleFilePlaybackEngine.swift")

        XCTAssertTrue(
            source.contains("private func ensureEngineRunning() -> Bool"),
            "node.play() on a dead engine raises an uncatchable NSException; internal restart paths must gate on a checked engine start."
        )
        let resumeBody = try methodBody(source, signature: "private func resumeChainPlayback()")
        XCTAssertTrue(resumeBody.contains("guard ensureEngineRunning() else { return }"))
        let dismantleBody = try methodBody(source, signature: "private func dismantleChainToLinear()")
        XCTAssertTrue(
            dismantleBody.contains("if wasActive, ensureEngineRunning() {"),
            "The failed-start path must fall through to the paused clock.prepare branch, never to node.play()."
        )
    }

    private func methodBody(_ source: String, signature: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "Missing method: \(signature)")
        let searchRange = start.upperBound..<source.endIndex
        let boundaries = [
            source.range(of: "\n    func ", range: searchRange),
            source.range(of: "\n    private func ", range: searchRange)
        ]
        let end = boundaries.compactMap { $0?.lowerBound }.min() ?? source.endIndex
        return String(source[start.lowerBound..<end])
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
