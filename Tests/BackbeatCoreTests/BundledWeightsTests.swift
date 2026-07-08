import XCTest
@testable import BackbeatCore

/// Locks the bundled-weights model that replaced the first-run downloader: the pinned
/// checkpoint identity, its bundle resolution, the one-time cleanup of the download-era
/// artifacts, the build-script ⇄ identity single-source cross-check, and the guarantee
/// that no network code survives in the app.
final class BundledWeightsTests: XCTestCase {
    // MARK: - Pinned identity

    func testHtdemucsIdentityIsPinned() {
        let identity = WeightsIdentity.htdemucs
        XCTAssertEqual(identity.filename, "955717e8-8726e21a.th")
        XCTAssertEqual(identity.sha256, "8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4")
        XCTAssertEqual(identity.byteCount, 84_141_911)
        XCTAssertEqual(identity.provenanceURL.host, "dl.fbaipublicfiles.com")
    }

    func testBundledURLResolvesToTheCheckpointResource() {
        // Bundle.main in the test runner has no such resource, so this exercises the
        // deterministic Contents/Resources fallback — the file name is what matters.
        let url = WeightsIdentity.htdemucs.bundledURL()
        XCTAssertEqual(url.lastPathComponent, "955717e8-8726e21a.th")
    }

    // MARK: - Build-script pin cross-check (single source of truth)

    func testBuildScriptPinsMatchTheIdentity() throws {
        let script = try readSource("script/build_and_run.sh")
        XCTAssertTrue(script.contains(WeightsIdentity.htdemucs.sha256),
                      "build_and_run.sh WEIGHTS_SHA256 must match WeightsIdentity.htdemucs.sha256")
        XCTAssertTrue(script.contains(WeightsIdentity.htdemucs.filename),
                      "build_and_run.sh WEIGHTS_FILENAME must match WeightsIdentity.htdemucs.filename")
        XCTAssertTrue(script.contains(WeightsIdentity.htdemucs.provenanceURL.absoluteString),
                      "build_and_run.sh WEIGHTS_URL must match WeightsIdentity.htdemucs.provenanceURL")
        XCTAssertTrue(script.contains(String(WeightsIdentity.htdemucs.byteCount)),
                      "build_and_run.sh WEIGHTS_BYTES must match WeightsIdentity.htdemucs.byteCount")
    }

    // MARK: - One-time cleanup of the download-era and vendored-port artifacts

    func testPurgeRemovesOrphanedArtifactsAndStaleCachesButKeepsLiveCache() throws {
        let fileManager = FileManager.default
        let models = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: models) }

        let filename = WeightsIdentity.htdemucs.filename
        let orphanCheckpoint = models.appendingPathComponent(filename)
        let manifest = models.appendingPathComponent("manifest.json")
        let partial = models.appendingPathComponent(".\(filename).partial")
        // The vendored port's stale conversion caches (Phase 5 cut-over: no code
        // can read them anymore) and the custom engine's live v3 cache.
        let staleV1 = models.appendingPathComponent("mlx-htdemucs-v1", isDirectory: true)
        let staleV2 = models.appendingPathComponent("mlx-htdemucs-v2", isDirectory: true)
        let liveV3 = models.appendingPathComponent("mlx-htdemucs-v3", isDirectory: true)
        let staleV1Tensors = staleV1.appendingPathComponent("htdemucs.safetensors")
        let staleV2Tensors = staleV2.appendingPathComponent("htdemucs.safetensors")
        let liveV3Tensors = liveV3.appendingPathComponent("htdemucs.safetensors")
        for directory in [staleV1, staleV2, liveV3] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for url in [orphanCheckpoint, manifest, partial, staleV1Tensors, staleV2Tensors, liveV3Tensors] {
            try Data("x".utf8).write(to: url)
        }

        LegacyWeightsCleanup.purgeLegacyArtifacts(modelsDirectory: models)

        // The downloaded .th, its manifest, staging, and the vendored caches are gone…
        XCTAssertFalse(fileManager.fileExists(atPath: orphanCheckpoint.path))
        XCTAssertFalse(fileManager.fileExists(atPath: manifest.path))
        XCTAssertFalse(fileManager.fileExists(atPath: partial.path))
        XCTAssertFalse(fileManager.fileExists(atPath: staleV1.path))
        XCTAssertFalse(fileManager.fileExists(atPath: staleV2.path))
        // …but the custom engine's live cache is preserved (no re-conversion on upgrade).
        XCTAssertTrue(fileManager.fileExists(atPath: liveV3Tensors.path))
    }

    func testPurgeIsSafeWhenNothingIsPresent() {
        let models = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // The directory does not exist; the fail-soft cleanup must not throw or crash.
        LegacyWeightsCleanup.purgeLegacyArtifacts(modelsDirectory: models)
    }

    // MARK: - Zero network code

    func testNoNetworkCodeRemainsInSources() throws {
        let sources = packageRoot().appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        // API-name needles that don't collide with the legitimate local-file
        // `Data(contentsOf:)` idiom or the inert `WeightsIdentity.provenanceURL` literal.
        // Covers the realistic reintroduction vectors: URLSession/URLRequest, the older
        // NSURLConnection/URLProtocol, Network.framework, and raw BSD sockets.
        let needles = [
            "URLSession", ".dataTask", ".downloadTask", "URLRequest",
            "NSURLConnection", "URLProtocol", "import Network", "NWConnection",
            "NWListener", "CFStream", "CFSocketCreate", "getaddrinfo",
        ]
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in needles where text.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "the app must contain no network code after bundling; found \(offenders)")
    }

    // MARK: - Helpers

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }
}
