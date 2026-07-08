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

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
