import Foundation

/// ffmpeg decode plan for mono Float32 PCM extraction. Lives beside its only
/// consumer since the spectrum preview analyzer was removed.
public enum AudioSpectrumAnalysisPlan {
    public static func decodedPCMURL(jobDirectory: URL) -> URL {
        jobDirectory.appendingPathComponent("analysis_mono.f32")
    }

    public static func decodeCommand(
        ffmpegPath: String,
        sourceURL: URL,
        sampleRate: Double,
        outputURL: URL
    ) -> CommandSpec {
        CommandSpec(
            executablePath: ffmpegPath,
            arguments: [
                "-y",
                "-hide_banner",
                "-loglevel", "error",
                "-i", sourceURL.path,
                "-vn",
                "-ac", "1",
                "-ar", String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), sampleRate),
                "-f", "f32le",
                "-acodec", "pcm_f32le",
                outputURL.path
            ]
        )
    }
}

/// Decodes an audio file to mono Float32 PCM samples via ffmpeg. Shared by
/// the spectrum and waveform analyzers so the decode pipeline exists once.
public struct MonoPCMDecoder: Sendable {
    private let sampleRate: Double
    private let temporaryRootURL: URL
    private let commandResolver: RenderPreflight.CommandResolver
    private let commandRunner: RenderCommandRunner

    public init(
        sampleRate: Double,
        temporaryRootURL: URL,
        commandResolver: @escaping RenderPreflight.CommandResolver,
        commandExecutor: any RenderCommandExecuting
    ) {
        self.sampleRate = sampleRate
        self.temporaryRootURL = temporaryRootURL
        self.commandResolver = commandResolver
        self.commandRunner = RenderCommandRunner(executor: commandExecutor)
    }

    public func decodeSamples(url: URL) async throws -> [Float] {
        guard let ffmpegPath = commandResolver("ffmpeg") else {
            throw BoostedDrumsRenderError.missingCommand("ffmpeg")
        }

        let jobDirectory = temporaryRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: jobDirectory)
        }

        let pcmURL = AudioSpectrumAnalysisPlan.decodedPCMURL(jobDirectory: jobDirectory)
        let command = AudioSpectrumAnalysisPlan.decodeCommand(
            ffmpegPath: ffmpegPath,
            sourceURL: url,
            sampleRate: sampleRate,
            outputURL: pcmURL
        )
        try await commandRunner.runOrThrow(command)
        try RenderCommandRunner.requireNonEmptyFile(pcmURL)

        let data = try Data(contentsOf: pcmURL)
        return data.withUnsafeBytes { rawBuffer in
            let floatCount = rawBuffer.count / MemoryLayout<Float>.size
            let typedBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(typedBuffer.prefix(floatCount))
        }
    }
}
