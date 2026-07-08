import BackbeatCore
import BackbeatSeparationMLX
import Foundation

// Mirrors what the app does per imported track: read metadata, then run the full native
// render that the background queue executes (in-process custom-engine separation →
// native StemMixdown — no demucs, no ffmpeg). Needs the htdemucs checkpoint present and
// the colocated mlx.metallib. Queue mechanics are covered hermetically by
// RenderQueueCoordinatorTests.
//
// The app resolves the checkpoint from its own bundle; this CLI has no bundle resource,
// so it resolves the same bytes from `BACKBEAT_WEIGHTS` or the machine-local weights
// cache the app's build script populates (~/Library/Caches/backline-boost/weights/).
@main
struct BackbeatWorkflowSmoke {
    static func main() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["BACKBEAT_SMOKE_AUDIO"] else {
            throw SmokeFailure("Set BACKBEAT_SMOKE_AUDIO to the path of a local audio file to run the workflow smoke.")
        }

        // Resolve the checkpoint up front so a missing file fails clearly here rather than
        // as a lower-level "weights not ready" deep inside the render.
        let weightsURL = try resolveWeights()

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let metadata = try await AudioMetadataReader().read(url: sourceURL)
        let track = BackbeatTrack(
            title: sourceURL.deletingPathExtension().lastPathComponent,
            duration: metadata.duration,
            status: .imported,
            sourceURL: sourceURL
        )

        // Bind the engine to the resolved checkpoint (the CLI has no app bundle to read it
        // from). The converted MLX cache lands in the default Application Support location,
        // exactly as in the app.
        let separator = CustomHTDemucsSeparator(weightsURL: weightsURL)
        let renderResult = try await BoostedDrumsRenderer(separator: separator).render(track: track)
        try validateAudioFile(renderResult.drumsURL, minimumBytes: 100_000)
        let drumsMetadata = try await AudioMetadataReader().read(url: renderResult.drumsURL)
        guard abs(drumsMetadata.duration - metadata.duration) < 1.0 else {
            throw SmokeFailure("drums duration \(drumsMetadata.duration) did not match source \(metadata.duration)")
        }
        print("drums_output: \(renderResult.drumsURL.path)")
        try validateAudioFile(renderResult.drumlessURL, minimumBytes: 1_000_000)
        let drumlessMetadata = try await AudioMetadataReader().read(url: renderResult.drumlessURL)
        guard abs(drumlessMetadata.duration - metadata.duration) < 1.0 else {
            throw SmokeFailure("drumless duration \(drumlessMetadata.duration) did not match source \(metadata.duration)")
        }
        print("drumless_output: \(renderResult.drumlessURL.path)")

        // The smoke's track never enters a library, so nothing ever supersedes these
        // UUID-named outputs — delete them or every run leaks a full-track render pair
        // into the real user directories.
        for url in [renderResult.drumsURL, renderResult.drumlessURL] {
            try? FileManager.default.removeItem(at: url)
        }
        print("cleanup: removed smoke outputs")
    }

    private static func validateAudioFile(_ url: URL, minimumBytes: Int) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= minimumBytes else {
            throw SmokeFailure("audio output was missing or too small: \(url.path)")
        }
    }

    /// Resolve the same htdemucs checkpoint bytes the app bundles: an explicit
    /// `BACKBEAT_WEIGHTS` override, else the machine-local weights cache the app's build
    /// script (`script/build_and_run.sh`) populates and verifies by SHA-256.
    private static func resolveWeights() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BACKBEAT_WEIGHTS"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                throw SmokeFailure("BACKBEAT_WEIGHTS points at a missing file: \(url.path)")
            }
            return url
        }
        let cached = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/backline-boost/weights/\(WeightsIdentity.htdemucs.filename)")
        guard fileManager.fileExists(atPath: cached.path) else {
            throw SmokeFailure(
                "The htdemucs checkpoint was not found. Build the app once "
                    + "(./script/build_and_run.sh populates \(cached.deletingLastPathComponent().path)), "
                    + "or set BACKBEAT_WEIGHTS to a local \(WeightsIdentity.htdemucs.filename).")
        }
        return cached
    }
}

struct SmokeFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
