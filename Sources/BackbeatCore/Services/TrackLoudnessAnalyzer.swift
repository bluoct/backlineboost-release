import Foundation

public struct TrackLoudnessAnalyzer: Sendable {
    public enum Error: LocalizedError {
        case missingCommand(String)
        case commandFailed(String)
        case missingMeasuredLoudness

        public var errorDescription: String? {
            switch self {
            case .missingCommand(let command):
                "Required audio tool is not available: \(command)."
            case .commandFailed(let output):
                "Loudness analysis failed. \(output)"
            case .missingMeasuredLoudness:
                "Loudness analysis did not return measured LUFS."
            }
        }
    }

    private let commandResolver: RenderPreflight.CommandResolver
    private let commandExecutor: any RenderCommandExecuting
    private let settings: PlaybackNormalizationSettings

    public init(
        settings: PlaybackNormalizationSettings = .default,
        commandResolver: @escaping RenderPreflight.CommandResolver = RenderPreflight.resolveCommand(_:),
        commandExecutor: any RenderCommandExecuting = ProcessRenderCommandExecutor()
    ) {
        self.settings = settings
        self.commandResolver = commandResolver
        self.commandExecutor = commandExecutor
    }

    public func analyze(sourceURL: URL, analyzedAt: Date = Date()) async throws -> TrackLoudnessProfile {
        guard let ffmpegPath = commandResolver("ffmpeg") else {
            throw Error.missingCommand("ffmpeg")
        }

        let result = try await commandExecutor.run(Self.loudnormCommand(ffmpegPath: ffmpegPath, sourceURL: sourceURL))
        guard result.terminationStatus == 0 else {
            throw Error.commandFailed(result.output)
        }
        return try Self.profile(from: result.output, settings: settings, analyzedAt: analyzedAt)
    }

    public static func loudnormCommand(ffmpegPath: String, sourceURL: URL) -> CommandSpec {
        CommandSpec(
            executablePath: ffmpegPath,
            arguments: [
                "-hide_banner",
                "-nostats",
                "-i", sourceURL.path,
                "-af", "loudnorm=I=-12.0:TP=-1.0:LRA=11.0:print_format=json",
                "-f", "null",
                "/dev/null"
            ]
        )
    }

    public static func profile(
        from output: String,
        settings: PlaybackNormalizationSettings,
        analyzedAt: Date = Date()
    ) throws -> TrackLoudnessProfile {
        let json = try extractJSON(from: output)
        let measured = try JSONDecoder().decode(LoudnormOutput.self, from: Data(json.utf8))
        guard let integratedLUFS = Double(measured.input_i) else {
            throw Error.missingMeasuredLoudness
        }
        let peak = measured.input_tp.flatMap(Double.init)
        return TrackLoudnessProfile(
            integratedLUFS: integratedLUFS,
            samplePeakDBFS: peak,
            suggestedGainDB: settings.suggestedGainDB(
                integratedLUFS: integratedLUFS,
                samplePeakDBFS: peak
            ),
            analyzedAt: analyzedAt,
            analyzerVersion: TrackLoudnessAnalyzerVersion.current
        )
    }

    // Anchors on the last "[Parsed_loudnorm" banner so stray braces in earlier
    // ffmpeg output (e.g. metadata containing "{") cannot shift the slice, then
    // brace-matches forward so trailing noise cannot over-extend it.
    private static func extractJSON(from output: String) throws -> String {
        let searchStart: String.Index
        if let marker = output.range(of: "[Parsed_loudnorm", options: .backwards) {
            searchStart = marker.upperBound
        } else {
            searchStart = output.startIndex
        }
        guard let start = output[searchStart...].firstIndex(of: "{") else {
            throw Error.missingMeasuredLoudness
        }
        var depth = 0
        var index = start
        while index < output.endIndex {
            let character = output[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(output[start...index])
                }
            }
            index = output.index(after: index)
        }
        throw Error.missingMeasuredLoudness
    }

    private struct LoudnormOutput: Decodable {
        let input_i: String
        let input_tp: String?
    }
}
