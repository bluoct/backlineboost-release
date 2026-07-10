import XCTest

/// Phase 4 robustness census (charter gate 4): the custom engine lives in
/// `BackbeatSeparationMLX`, which the test target can't import, so its
/// load-bearing wiring is pinned by reading the source (the project's
/// `*SourceTests` convention, same as `WeightsRenderGateSourceTests`). These
/// lock the seam the hermetic Core tests actually cover to the seam the engine
/// actually calls: swap out `SeparationInputLoader` or the scheduler types and
/// the census breaks loudly instead of the decode-seam tests silently pinning
/// a path the engine no longer uses.
final class CustomEngineSeamSourceTests: XCTestCase {
    func testCustomEngineDecodesThroughTheTestedInputLoader() throws {
        let source = try readSource("Sources/BackbeatSeparationMLX/Engine/CustomHTDemucsSeparator.swift")
        // The ONLY input path is the Phase 1 loader — the exact type carrying the
        // truncation-stall guard, zero-frame rejection, and anti-aliased SRC pins
        // (`SeparationInputLoaderTests`).
        XCTAssertTrue(source.contains("SeparationInputLoader().load(url: source)"))
        // No second decode path inside the separator.
        XCTAssertFalse(source.contains("AVAudioFile("))
    }

    func testCustomEngineSchedulesThroughTheTestedSchedulerTypes() throws {
        let source = try readSource("Sources/BackbeatSeparationMLX/Engine/CustomHTDemucsSeparator.swift")
        // Planning, normalization, and overlap-add are the Core types pinned by
        // `HTDemucsSchedulerTests` (incl. the silent-track end-to-end deviation).
        XCTAssertTrue(source.contains("HTDemucsScheduler.plan(trackLength: trackLength, overlap: overlap)"))
        XCTAssertTrue(source.contains("HTDemucsTrackNormalization.measure(channels)"))
        XCTAssertTrue(source.contains("accumulator.finalize(denormalizingWith: normalization)"))
    }

    func testCustomEngineBuildPhaseKeepsCancellationCheckpoints() throws {
        let source = try readSource("Sources/BackbeatSeparationMLX/Engine/CustomHTDemucsSeparator.swift")
        // G4/R8: the first-run conversion + weight-load + graph-build phases are
        // cooperatively cancellable — checkpoints surround the conversion gate.
        XCTAssertTrue(source.contains("HTDemucsConversion.ensureCustomEngineConverted"))
        XCTAssertTrue(source.contains("try Task.checkCancellation()"))
    }

    func testCustomEngineRebuildsCacheWhenLoadOrBuildFails() throws {
        let source = try readSource("Sources/BackbeatSeparationMLX/Engine/CustomHTDemucsSeparator.swift")
        // A converted cache that passes the bare fileExists check but can't be
        // loaded/built from must be invalidated and rebuilt once, not fail every
        // render forever (F10).
        XCTAssertTrue(source.contains("private func buildPipeline()"))
        XCTAssertTrue(source.contains("private func convertLoadAndBuild()"))
        XCTAssertTrue(
            source.contains("removeItem"),
            "A failed load/build must delete the stale cache before retrying (F10)."
        )
    }

    func testCompiledForwardDoesNotRetainThePipeline() throws {
        let source = try readSource("Sources/BackbeatSeparationMLX/Engine/CustomHTDemucsPipeline.swift")
        // The compiled forward is a stored lazy closure; a strong [self] capture
        // pinned the ~340 MB fp32 weight set for the process lifetime (F11).
        XCTAssertTrue(source.contains("MLX.compile { [weak self]"))
        XCTAssertFalse(source.contains("MLX.compile { [self]"))
        // The per-window output slice is load-bearing (compiled functions recycle
        // their output buffers) and must not be removed while touching this file.
        XCTAssertTrue(source.contains("combined[window]"))
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
