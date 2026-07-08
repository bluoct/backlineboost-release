import XCTest

/// The native-engine injection and its weight resolution live in the `Backbeat`
/// executable and the `BackbeatSeparationMLX` target, which the test target can't
/// import, so they are pinned by reading the source (the project's `*SourceTests`
/// convention). These lock the load-bearing wiring after the bundled-weights cut-over:
/// one shared engine injected into the render queue, the checkpoint resolved from the
/// app bundle, renders enqueued unconditionally (no first-run download gate), and the
/// build script fetching + SHA-256-verifying + bundling the checkpoint.
final class WeightsRenderGateSourceTests: XCTestCase {
    func testAppInjectsOneSharedNativeEngineIntoTheRenderQueue() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")
        XCTAssertTrue(source.contains("import BackbeatSeparationMLX"))
        // One shared custom engine, injected into the queue's RenderExecution closure
        // (Phase 5 cut-over: the vendored MLXStemSeparator is gone).
        XCTAssertTrue(source.contains("let separator = CustomHTDemucsSeparator()"))
        XCTAssertFalse(source.contains("MLXStemSeparator"))
        XCTAssertTrue(source.contains("RenderQueueCoordinator(store: store)"))
        XCTAssertTrue(source.contains("BoostedDrumsRenderer(separator: separator)"))
    }

    func testRootViewEnqueuesRendersUnconditionallyAndPurgesOrphanWeights() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")
        // The checkpoint is bundled, so there is no first-run readiness gate: renders
        // enqueue unconditionally. The download-era symbols are gone.
        XCTAssertFalse(source.contains("renderingAllowed"))
        XCTAssertFalse(source.contains("weightsStore"))
        XCTAssertFalse(source.contains(".prepare()"))
        XCTAssertTrue(source.contains("renderQueue.enqueueMissingRenders()"))
        // Upgrading users' orphaned downloaded checkpoint and the vendored port's
        // stale v1/v2 conversion caches are purged once at launch (v3 kept).
        XCTAssertTrue(source.contains("LegacyWeightsCleanup.purgeLegacyArtifacts()"))
    }

    func testEngineResolvesTheCheckpointFromTheAppBundle() throws {
        let source = try readSource("Sources/BackbeatSeparationMLX/Engine/CustomHTDemucsSeparator.swift")
        // Single load path: the checkpoint bundled in the app.
        XCTAssertTrue(source.contains("WeightsIdentity.htdemucs.bundledURL()"))
        // The dev/bench override is retained (parity harness + BackbeatSepBench use it).
        XCTAssertTrue(source.contains("BACKBEAT_WEIGHTS"))
    }

    func testBuildScriptFetchesVerifiesAndBundlesTheCheckpoint() throws {
        let source = try readSource("script/build_and_run.sh")
        // Fetch-at-build from the pinned Meta URL, machine-cached and SHA-256-verified,
        // then copied into the app bundle (before codesign seals it).
        XCTAssertTrue(source.contains("dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th"))
        XCTAssertTrue(source.contains("shasum -a 256"))
        XCTAssertTrue(source.contains("cp \"$WEIGHTS_CACHE_FILE\" \"$WEIGHTS_DEST\""))
        // The bytes actually placed in the bundle are re-verified (not just the cache),
        // so this final gate can't be silently dropped.
        XCTAssertTrue(source.contains("weights_sha_ok \"$WEIGHTS_DEST\""))
        // A checksum mismatch fails the build rather than shipping unverified bytes.
        XCTAssertTrue(source.contains("exit 1"))
        // The app never downloads at runtime — the fetch is a build step only.
        XCTAssertFalse(source.contains("URLSession"))
    }

    func testBuildScriptBundlesTheMLXMetallibNextToTheBinary() throws {
        let source = try readSource("script/build_and_run.sh")
        // The native engine needs mlx.metallib colocated with the app binary; the build
        // script must build it if missing and copy it into Contents/MacOS.
        XCTAssertTrue(source.contains("build_mlx_metallib.sh"))
        XCTAssertTrue(source.contains("cp \"$MLX_METALLIB\" \"$APP_MACOS/mlx.metallib\""))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
