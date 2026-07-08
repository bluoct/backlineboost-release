import Foundation

/// Measures a track's integrated loudness and derives a normalization gain. This is
/// the orchestration layer over the native, in-process `LoudnessAnalyzer` (ITU-R
/// BS.1770-4) that replaced the ffmpeg `loudnorm` subprocess: it decodes + measures
/// off the main actor and folds the result into a `TrackLoudnessProfile` via
/// `PlaybackNormalizationSettings`.
public struct TrackLoudnessAnalyzer: Sendable {
    public enum Error: LocalizedError {
        case decodeFailed(URL)
        case missingMeasuredLoudness

        public var errorDescription: String? {
            switch self {
            case .decodeFailed(let url):
                "Loudness analysis could not read the audio file: \(url.lastPathComponent)."
            case .missingMeasuredLoudness:
                "Loudness analysis did not produce a measurable loudness."
            }
        }
    }

    private let settings: PlaybackNormalizationSettings

    public init(settings: PlaybackNormalizationSettings = .default) {
        self.settings = settings
    }

    @concurrent
    public func analyze(sourceURL: URL, analyzedAt: Date = Date()) async throws -> TrackLoudnessProfile {
        // `@concurrent` pins this off the caller's actor: the background loudness task
        // awaits it from the main actor, and the synchronous decode + BS.1770 DSP
        // (~seconds) must not run there. The attribute makes that guarantee explicit
        // and immune to a future `nonisolated(nonsending)`-by-default flip.
        try Task.checkCancellation()
        let measurement: LoudnessAnalyzer.Measurement
        do {
            measurement = try LoudnessAnalyzer().analyze(url: sourceURL)
        } catch {
            throw Error.decodeFailed(sourceURL)
        }

        guard measurement.integratedLUFS.isFinite else {
            throw Error.missingMeasuredLoudness
        }

        return TrackLoudnessProfile(
            integratedLUFS: measurement.integratedLUFS,
            // `samplePeakDBFS` (a schema-compat field name) carries the BS.1770 *true*
            // peak; the old ffmpeg path likewise stored loudnorm's `input_tp`.
            samplePeakDBFS: measurement.truePeakDBFS,
            suggestedGainDB: settings.suggestedGainDB(
                integratedLUFS: measurement.integratedLUFS,
                samplePeakDBFS: measurement.truePeakDBFS
            ),
            analyzedAt: analyzedAt,
            analyzerVersion: TrackLoudnessAnalyzerVersion.current
        )
    }
}
