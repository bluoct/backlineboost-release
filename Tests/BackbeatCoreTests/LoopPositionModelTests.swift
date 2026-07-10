import XCTest
@testable import BackbeatCore

final class LoopPositionModelTests: XCTestCase {

    // MARK: - Head mapping

    func testHeadMappingAnchorMidLoopMapsRenderedToAnchorPlusRendered() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1050,
            generation: 1
        ))

        XCTAssertEqual(model.positionFrame(forRenderedFrames: 0), 1050)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: 10), 1060)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: 49), 1099)
    }

    func testHeadBoundarySeamRenderedEqualsHeadCountMapsExactlyToLoopStartFrame() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1050,
            generation: 1
        ))

        XCTAssertEqual(model.headFrames.count, 50)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: 50), 1000)
    }

    // MARK: - Modulo wrap across multiple iterations

    func testModuloWrapAcrossThreeIterationsMapsBackToLoopStartPlusRemainder() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1050,
            generation: 1
        ))
        let head = model.headFrames.count
        let loop = model.loopFrameCount

        for k: Int64 in 1...3 {
            for r: Int64 in [0, 25, 99] {
                let rendered = head + k * loop + r
                XCTAssertEqual(
                    model.positionFrame(forRenderedFrames: rendered),
                    model.loopStartFrame + r,
                    "k=\(k) r=\(r)"
                )
            }
        }
    }

    // MARK: - Pre-roll anchor

    func testPreRollAnchorHeadSpansAnchorToLoopEndCrossingLoopStart() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 950,
            generation: 2
        ))

        XCTAssertEqual(model.headFrames.count, 150)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: 0), 950)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: 49), 999)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: 50), 1000)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: 149), 1099)
    }

    func testPreRollAnchorPostHeadIterationsMapFromLoopStart() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 950,
            generation: 2
        ))
        let head = model.headFrames.count

        XCTAssertEqual(model.positionFrame(forRenderedFrames: head), 1000)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: head + 50), 1050)
        XCTAssertEqual(model.positionFrame(forRenderedFrames: head + 99), 1099)
    }

    // MARK: - Anchor clamps

    func testAnchorAtOrPastLoopEndClampsToLoopStart() throws {
        let atLoopEnd = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1100,
            generation: 3
        ))
        let pastLoopEnd = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1200,
            generation: 3
        ))

        XCTAssertEqual(atLoopEnd.anchorFrame, 1000)
        XCTAssertEqual(pastLoopEnd.anchorFrame, 1000)
    }

    func testAnchorOneFrameBeforeLoopEndKeepsOneFrameHead() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1099,
            generation: 3
        ))

        XCTAssertEqual(model.anchorFrame, 1099)
        XCTAssertEqual(model.headFrames.count, 1)
    }

    func testNegativeAnchorClampsToZeroAndStaysLegalPreRollBelowLoopStart() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: -50,
            generation: 3
        ))

        XCTAssertEqual(model.anchorFrame, 0)
        XCTAssertLessThan(model.anchorFrame, model.loopStartFrame)
        XCTAssertEqual(model.headFrames.start, 0)
    }

    // MARK: - headFrames / iterationFrames invariants

    func testHeadFramesAndIterationFramesForMidLoopAnchor() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1050,
            generation: 1
        ))

        XCTAssertEqual(model.headFrames.start, 1050)
        XCTAssertEqual(model.headFrames.count, 50)
        XCTAssertEqual(model.headFrames.start + model.headFrames.count, model.loopEndFrame)
        XCTAssertEqual(model.iterationFrames.start, model.loopStartFrame)
        XCTAssertEqual(model.iterationFrames.count, model.loopFrameCount)
    }

    func testHeadFramesAndIterationFramesForPreRollAnchor() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 950,
            generation: 2
        ))

        XCTAssertEqual(model.headFrames.start, 950)
        XCTAssertEqual(model.headFrames.count, 150)
        XCTAssertEqual(model.headFrames.start + model.headFrames.count, model.loopEndFrame)
        XCTAssertEqual(model.iterationFrames.start, model.loopStartFrame)
        XCTAssertEqual(model.iterationFrames.count, model.loopFrameCount)
    }

    func testHeadFramesAndIterationFramesForSnappedAnchor() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1200,
            generation: 3
        ))

        XCTAssertEqual(model.headFrames.start, 1000)
        XCTAssertEqual(model.headFrames.count, 100)
        XCTAssertEqual(model.headFrames.start + model.headFrames.count, model.loopEndFrame)
        XCTAssertEqual(model.iterationFrames.start, model.loopStartFrame)
        XCTAssertEqual(model.iterationFrames.count, model.loopFrameCount)
    }

    // MARK: - Negative rendered frames

    func testNegativeRenderedFramesClampToAnchor() throws {
        let midLoop = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1050,
            generation: 1
        ))
        let preRoll = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 950,
            generation: 2
        ))

        XCTAssertEqual(midLoop.positionFrame(forRenderedFrames: -10), 1050)
        XCTAssertEqual(preRoll.positionFrame(forRenderedFrames: -1), 950)
    }

    // MARK: - validated()

    func testValidatedReturnsNilWhenLoopEndDoesNotExceedLoopStart() {
        XCTAssertNil(LoopPositionModel.validated(
            loopStartFrame: 100,
            loopEndFrame: 100,
            anchorFrame: 100,
            generation: 1
        ))
        XCTAssertNil(LoopPositionModel.validated(
            loopStartFrame: 100,
            loopEndFrame: 50,
            anchorFrame: 100,
            generation: 1
        ))
    }

    func testValidatedEnforcesMinimumFrameCountFloor() {
        // At 48 kHz the engines pass ceil(0.05 * 48000) = 2400 frames.
        XCTAssertNil(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 2399,
            anchorFrame: 0,
            generation: 1,
            minimumFrameCount: 2400
        ))
        XCTAssertNotNil(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 2400,
            anchorFrame: 0,
            generation: 1,
            minimumFrameCount: 2400
        ))
    }

    func testValidatedAllowsOneFrameLoopAtDefaultFloor() {
        let model = LoopPositionModel.validated(
            loopStartFrame: 500,
            loopEndFrame: 501,
            anchorFrame: 500,
            generation: 1
        )

        XCTAssertNotNil(model)
        XCTAssertEqual(model?.loopFrameCount, 1)
    }

    // MARK: - Wrap-invariant sweep

    func testWrapInvariantSweepNeverReachesLoopEndFrame() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 100,
            loopEndFrame: 130,
            anchorFrame: 110,
            generation: 5
        ))
        let head = model.headFrames.count
        let loop = model.loopFrameCount
        let lowerBound = min(model.anchorFrame, model.loopStartFrame)

        for rendered: Int64 in 0...(head + 4 * loop) {
            let position = model.positionFrame(forRenderedFrames: rendered)

            XCTAssertGreaterThanOrEqual(position, lowerBound, "rendered=\(rendered)")
            XCTAssertLessThan(position, model.loopEndFrame, "rendered=\(rendered)")
            XCTAssertNotEqual(position, model.loopEndFrame, "rendered=\(rendered)")

            if rendered >= head {
                XCTAssertGreaterThanOrEqual(position, model.loopStartFrame, "rendered=\(rendered)")
                XCTAssertLessThan(position, model.loopEndFrame, "rendered=\(rendered)")
            }
        }
    }

    // MARK: - iterationsToKeepQueued

    func testIterationsToKeepQueuedForMultiSecondLoop() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 480_000,
            anchorFrame: 0,
            generation: 1
        ))

        XCTAssertEqual(model.iterationsToKeepQueued(sampleRate: 48_000), 2)
    }

    func testIterationsToKeepQueuedForShortLoopAtDefaultTarget() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 2400,
            anchorFrame: 0,
            generation: 1
        ))

        XCTAssertEqual(model.iterationsToKeepQueued(sampleRate: 48_000), 40)
    }

    func testIterationsToKeepQueuedCapsAtSixtyFour() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 100,
            anchorFrame: 0,
            generation: 1
        ))

        XCTAssertEqual(model.iterationsToKeepQueued(sampleRate: 48_000), 64)
    }

    func testIterationsToKeepQueuedDegradesToTwoForNonPositiveSampleRate() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 2400,
            anchorFrame: 0,
            generation: 1
        ))

        XCTAssertEqual(model.iterationsToKeepQueued(sampleRate: 0), 2)
        XCTAssertEqual(model.iterationsToKeepQueued(sampleRate: -1), 2)
        XCTAssertEqual(model.iterationsToKeepQueued(sampleRate: .nan), 2)
    }

    // MARK: - Generation

    func testValidatedStampsGeneration() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 100,
            anchorFrame: 0,
            generation: 7
        ))

        XCTAssertEqual(model.generation, 7)
    }

    func testIsCurrentInGenerationMatchesOwnGenerationOnly() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 100,
            anchorFrame: 0,
            generation: 7
        ))

        XCTAssertTrue(model.isCurrent(inGeneration: 7))
        XCTAssertFalse(model.isCurrent(inGeneration: 8))
    }

    func testModelsWithIdenticalBoundsButDifferentGenerationsAreNotEqual() throws {
        let generationOne = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 100,
            anchorFrame: 0,
            generation: 1
        ))
        let generationTwo = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 0,
            loopEndFrame: 100,
            anchorFrame: 0,
            generation: 2
        ))

        XCTAssertNotEqual(generationOne, generationTwo)
    }

    // MARK: - frame(forSeconds:sampleRate:)

    func testFrameForSecondsExactRounding() {
        XCTAssertEqual(LoopPositionModel.frame(forSeconds: 1.0, sampleRate: 44_100), 44_100)
    }

    func testFrameForSecondsRoundsHalfFrameAwayFromZero() {
        // 0.5 s at 3 Hz = 1.5 frames; .rounded() ties away from zero -> 2.
        XCTAssertEqual(LoopPositionModel.frame(forSeconds: 0.5, sampleRate: 3), 2)
    }

    func testFrameForSecondsClampsNegativeSecondsToZero() {
        XCTAssertEqual(LoopPositionModel.frame(forSeconds: -5, sampleRate: 44_100), 0)
    }

    func testFrameForSecondsReturnsZeroForNonFiniteInputs() {
        XCTAssertEqual(LoopPositionModel.frame(forSeconds: .nan, sampleRate: 44_100), 0)
        XCTAssertEqual(LoopPositionModel.frame(forSeconds: .infinity, sampleRate: 44_100), 0)
        XCTAssertEqual(LoopPositionModel.frame(forSeconds: 1.0, sampleRate: .nan), 0)
        XCTAssertEqual(LoopPositionModel.frame(forSeconds: 1.0, sampleRate: .infinity), 0)
    }

    // MARK: - positionSeconds(forRenderedFrames:sampleRate:)

    func testPositionSecondsBridgesFrameToRate() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1050,
            generation: 1
        ))

        XCTAssertEqual(
            model.positionSeconds(forRenderedFrames: 0, sampleRate: 44_100),
            1050.0 / 44_100.0,
            accuracy: 1e-9
        )
    }

    func testPositionSecondsReturnsZeroForNonPositiveOrNaNSampleRate() throws {
        let model = try XCTUnwrap(LoopPositionModel.validated(
            loopStartFrame: 1000,
            loopEndFrame: 1100,
            anchorFrame: 1050,
            generation: 1
        ))

        XCTAssertEqual(model.positionSeconds(forRenderedFrames: 0, sampleRate: 0), 0)
        XCTAssertEqual(model.positionSeconds(forRenderedFrames: 0, sampleRate: -1), 0)
        XCTAssertEqual(model.positionSeconds(forRenderedFrames: 0, sampleRate: .nan), 0)
    }
}
