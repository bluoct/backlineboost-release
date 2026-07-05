import BackbeatCore
import Foundation

// Mirrors what the app does per imported track: read metadata, then run the
// full Demucs render that the background queue executes. Queue mechanics are
// covered hermetically by RenderQueueCoordinatorTests.
@main
struct BackbeatWorkflowSmoke {
    static func main() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["BACKBEAT_SMOKE_AUDIO"] else {
            throw SmokeFailure("Set BACKBEAT_SMOKE_AUDIO to the path of a local audio file to run the workflow smoke.")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let metadata = try await AudioMetadataReader().read(url: sourceURL)
        let track = BackbeatTrack(
            title: sourceURL.deletingPathExtension().lastPathComponent,
            duration: metadata.duration,
            status: .imported,
            sourceURL: sourceURL
        )

        let renderResult = try await BoostedDrumsRenderer().render(track: track)
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

        // The smoke's track never enters a library, so nothing ever supersedes
        // these UUID-named outputs — delete them or every run leaks a
        // full-track render pair into the real user directories.
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
