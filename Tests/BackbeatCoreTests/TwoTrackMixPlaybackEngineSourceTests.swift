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
        XCTAssertTrue(source.contains("try validatePair(drumlessFile: candidateDrumlessFile, drumsFile: candidateDrumsFile)"))

        let loadMethod = try XCTUnwrap(source.range(of: "private func load(asset: TwoTrackMixAsset) throws"))
        let validateCall = try XCTUnwrap(source.range(of: "try validatePair(drumlessFile: candidateDrumlessFile, drumsFile: candidateDrumsFile)", range: loadMethod.lowerBound..<source.endIndex))
        let drumlessAssignment = try XCTUnwrap(source.range(of: "drumlessFile = candidateDrumlessFile", range: loadMethod.lowerBound..<source.endIndex))
        let drumsAssignment = try XCTUnwrap(source.range(of: "drumsFile = candidateDrumsFile", range: loadMethod.lowerBound..<source.endIndex))
        let activeAssignment = try XCTUnwrap(source.range(of: "activeAsset = asset", range: loadMethod.lowerBound..<source.endIndex))

        XCTAssertLessThan(validateCall.lowerBound, drumlessAssignment.lowerBound)
        XCTAssertLessThan(validateCall.lowerBound, drumsAssignment.lowerBound)
        XCTAssertLessThan(validateCall.lowerBound, activeAssignment.lowerBound)
    }

    func testTransportDurationDerivesFromRenderedFilesNotThePersistedEstimate() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        XCTAssertTrue(
            source.contains("private var pairDuration: TimeInterval = 0"),
            "The transport duration must be derived from the rendered files, not the persisted track.duration estimate (F1)."
        )
        XCTAssertTrue(
            source.contains("var transportDuration: TimeInterval { pairDuration }"),
            "The controller must be able to read the file-derived pairDuration off the engine (F1 companion fix)."
        )
        XCTAssertTrue(
            source.contains("clock.start(fromElapsed: startElapsed, duration: pairDuration"),
            "play() must clock the file-derived pairDuration, not activeAsset.duration."
        )
        XCTAssertTrue(source.contains("clock.prepare(atElapsed: elapsed, duration: pairDuration)"))
        XCTAssertFalse(
            source.contains("activeAsset?.duration") || source.contains("activeAsset.duration"),
            "No transport read may consult the estimated activeAsset.duration anymore."
        )
        XCTAssertFalse(
            source.contains("abs(asset.duration"),
            "The asset.duration ± 0.25s validation gate — which permanently blocked Drum Boost on VBR drift — must be gone (F1)."
        )
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

    func testPauseCommitsElapsedThenPausesEngineOnlyKeepingTheStemsLockstep() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let pauseBody = try methodBody(source, signature: "func pause()")
        let commit = try XCTUnwrap(pauseBody.range(of: "let committed = currentElapsed()"))
        let enginePause = try XCTUnwrap(pauseBody.range(of: "engine.pause()"))
        let clockPause = try XCTUnwrap(pauseBody.range(of: "clock.pause(committing: committed)"))

        XCTAssertLessThan(commit.lowerBound, enginePause.lowerBound)
        XCTAssertLessThan(enginePause.lowerBound, clockPause.lowerBound)
        XCTAssertFalse(
            pauseBody.contains("drumlessNode.pause()") || pauseBody.contains("drumsNode.pause()"),
            "Per-node pauses can straddle a render cycle and freeze the stems ~11ms apart — a desync a preserved queue would make permanent."
        )
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

    func testEngineObservesHardwareConfigurationChanges() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        XCTAssertTrue(
            source.contains("AVAudioEngineConfigurationChange"),
            "An output-device or hardware-format change stops the engine and silently kills audio; it must be observed (F3)."
        )
        XCTAssertTrue(
            source.contains("onPlaybackInterrupted"),
            "The engine must report an interruption so the controller can reflect paused instead of 'playing' silence (F3)."
        )
    }

    func testScheduleChainSegmentSchedulesBothNodesWithIdenticalFrameCounts() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let scheduleChainSegmentBody = try methodBody(source, signature: "private func scheduleChainSegment(start: Int64, count: Int64, generation: UInt64)")
        XCTAssertTrue(scheduleChainSegmentBody.contains("drumlessNode.scheduleSegment("))
        XCTAssertTrue(scheduleChainSegmentBody.contains("drumsNode.scheduleSegment("))

        let startingFrameOccurrences = scheduleChainSegmentBody.components(separatedBy: "startingFrame: AVAudioFramePosition(start)").count - 1
        XCTAssertEqual(
            startingFrameOccurrences,
            2,
            "Identical frame counts on both nodes keep the stems lockstep — one helper, two scheduleSegment calls."
        )

        let completionCallbackOccurrences = scheduleChainSegmentBody.components(separatedBy: "completionCallbackType").count - 1
        XCTAssertEqual(
            completionCallbackOccurrences,
            1,
            "Completion rides ONLY the drumless (position-reporting) segment — the drums schedule must not attach its own completion."
        )
    }

    func testBuildChainClampsToThePairFrameLimitNotTrackDuration() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let buildChainBody = try methodBody(source, signature: "private func buildChain(anchoredAt elapsed: TimeInterval, range: PracticeLoopRange, snapOutsideToStart: Bool) -> Bool")
        XCTAssertTrue(
            buildChainBody.contains("min(drumlessFile.length, drumsFile.length)"),
            "The 0.12s validatePair tolerance would silently desync the stems if the loop were bounded by track.duration instead of the coherent pair."
        )
    }

    func testResumeChainPlaybackRebuildsOnMixedNodeState() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let resumeChainPlaybackBody = try methodBody(source, signature: "private func resumeChainPlayback()")
        XCTAssertTrue(
            resumeChainPlaybackBody.contains("drumlessNode.isPlaying != drumsNode.isPlaying"),
            "A mixed node state should not occur; defensively rebuild rather than start one stem late."
        )
    }

    func testChainCompletionHopsToMainActorAndTopUpGuardsGeneration() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

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
        XCTAssertTrue(
            topUpChainBody.contains("while queuedSegmentCount < chainTargetDepth"),
            "Each completion tops up to the target depth rather than scheduling exactly one — self-healing if a completion is ever lost."
        )
    }

    func testStopNodesInvalidatesTheChainGeneration() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

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
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let playBody = try methodBody(source, signature: "func play(asset: TwoTrackMixAsset, startElapsed: TimeInterval, volume: Double, speed: Double, normalizationGainDB: Double, sectionLoop: PracticeLoopRange?) throws")
        XCTAssertTrue(
            playBody.contains("let isChainResume = chainModel != nil"),
            "A same-asset, same-loop, position-close resume must preserve the pre-scheduled queue instead of rescheduling — no new sync-start delay (D-094)."
        )

        let stopNodesCall = try XCTUnwrap(playBody.range(of: "stopNodes()"))
        let scheduleCall = try XCTUnwrap(playBody.range(of: "schedulePair(from: startElapsed)"))
        XCTAssertLessThan(
            stopNodesCall.lowerBound,
            scheduleCall.lowerBound,
            "A stale chain must be flushed before a linear schedule; otherwise its dead-loop completions top it back up behind the linear tail."
        )
    }

    func testSetSectionLoopCapturesHadPendingBeforeCancelling() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

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
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

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
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let renderedFramesBody = try methodBody(source, signature: "private func renderedFrames(on node: AVAudioPlayerNode) -> Int64?")
        XCTAssertTrue(
            renderedFramesBody.contains("activeSampleRate / playerTime.sampleRate"),
            "The graph is connected format-nil, so the node's output rate can differ from the file rate; raw sampleTime is not file-domain."
        )
    }

    func testBuildChainValidatesBeforeFlushingTheRunningSchedule() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

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
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let handleConfigurationChangeBody = try methodBody(source, signature: "private func handleConfigurationChange()")
        XCTAssertTrue(
            handleConfigurationChangeBody.contains("if !isPlaybackActive, chainModel != nil"),
            "A paused preserved queue must not survive a hardware swap onto a stale graph."
        )
    }

    func testHandleConfigurationChangeReanchorsTheClockAtTheCommittedPosition() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let handleConfigurationChangeBody = try methodBody(source, signature: "private func handleConfigurationChange()")
        XCTAssertTrue(
            handleConfigurationChangeBody.contains("clock.prepare(atElapsed: resumeElapsed"),
            "stopNodes zeroes the clock; without re-anchoring, engine reads after an interruption (marker capture, relative seeks) report 0:00 instead of the committed position."
        )
    }

    func testDebounceHandleClearsOnSettleAndOnFlush() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

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
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let applyBody = try methodBody(source, signature: "private func applySectionLoopEdit()")
        XCTAssertTrue(
            applyBody.contains("range == chainAppliedLoop"),
            "A drag that settles back on the applied bounds must not tear down a chain already rendering exactly that loop (D-094: no-op edits must not glitch the seam)."
        )
    }

    func testAnchorSnapAppliesOnlyToSettledBoundsEdits() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let playBody = try methodBody(source, signature: "func play(asset: TwoTrackMixAsset, startElapsed: TimeInterval, volume: Double, speed: Double, normalizationGainDB: Double, sectionLoop: PracticeLoopRange?) throws")
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
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        let seekBody = try methodBody(source, signature: "func seek(to elapsed: TimeInterval, autoplay: Bool, volume: Double, speed: Double, normalizationGainDB: Double) throws")
        XCTAssertTrue(
            seekBody.contains("sectionLoop: activeSectionLoop"),
            "A scrub during an active loop must rebuild the chain, not silently drop the loop."
        )
    }

    func testEngineStartFailureNeverReachesNodePlay() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

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

    func testDismantleAndResumeKeepTheSynchronizedStart() throws {
        let source = try readSource("Sources/Backbeat/Services/TwoTrackMixPlaybackEngine.swift")

        for signature in ["private func dismantleChainToLinear()", "private func resumeChainPlayback()"] {
            let body = try methodBody(source, signature: signature)
            XCTAssertTrue(
                body.contains("drumlessNode.play(at: startTime)"),
                "\(signature) must start both nodes through the synchronized play(at:), or the stems drift a scheduler quantum apart."
            )
            XCTAssertTrue(body.contains("drumsNode.play(at: startTime)"))
        }
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
