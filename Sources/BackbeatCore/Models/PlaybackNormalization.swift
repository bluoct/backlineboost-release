import Foundation

public struct TrackLoudnessProfile: Equatable, Codable, Sendable {
    public var integratedLUFS: Double
    public var samplePeakDBFS: Double?
    public var suggestedGainDB: Double
    public var analyzedAt: Date
    public var analyzerVersion: Int

    public init(
        integratedLUFS: Double,
        samplePeakDBFS: Double?,
        suggestedGainDB: Double,
        analyzedAt: Date = Date(),
        analyzerVersion: Int = TrackLoudnessAnalyzerVersion.current
    ) {
        self.integratedLUFS = integratedLUFS
        self.samplePeakDBFS = samplePeakDBFS
        self.suggestedGainDB = suggestedGainDB
        self.analyzedAt = analyzedAt
        self.analyzerVersion = analyzerVersion
    }
}

public enum TrackLoudnessAnalyzerVersion {
    public static let current = 1
}

public struct PlaybackNormalizationSettings: Equatable, Codable, Sendable {
    public var isEnabled: Bool
    public var targetLUFS: Double
    public var maxBoostDB: Double
    public var maxCutDB: Double
    public var outputCeilingDBFS: Double

    public static let `default` = PlaybackNormalizationSettings(
        isEnabled: true,
        targetLUFS: -12,
        maxBoostDB: 6,
        maxCutDB: -1.5,
        outputCeilingDBFS: -1
    )

    public static let disabled = PlaybackNormalizationSettings(
        isEnabled: false,
        targetLUFS: -12,
        maxBoostDB: 6,
        maxCutDB: -1.5,
        outputCeilingDBFS: -1
    )

    public init(
        isEnabled: Bool,
        targetLUFS: Double,
        maxBoostDB: Double,
        maxCutDB: Double,
        outputCeilingDBFS: Double
    ) {
        self.isEnabled = isEnabled
        self.targetLUFS = targetLUFS
        self.maxBoostDB = maxBoostDB
        self.maxCutDB = maxCutDB
        self.outputCeilingDBFS = outputCeilingDBFS
    }

    public func suggestedGainDB(integratedLUFS: Double, samplePeakDBFS: Double?) -> Double {
        guard integratedLUFS.isFinite else { return 0 }
        let rawGain = targetLUFS - integratedLUFS
        let clamped = min(max(rawGain, maxCutDB), maxBoostDB)
        guard clamped > 0, let samplePeakDBFS, samplePeakDBFS.isFinite else {
            return clamped
        }
        let peakHeadroom = outputCeilingDBFS - samplePeakDBFS
        return max(0, min(clamped, peakHeadroom))
    }
}

public enum PlaybackNormalization {
    public static func gainDB(for track: BackbeatTrack, settings: PlaybackNormalizationSettings) -> Double {
        guard settings.isEnabled, let profile = track.loudnessProfile else { return 0 }
        return min(max(profile.suggestedGainDB, settings.maxCutDB), settings.maxBoostDB)
    }

    public static func linearGain(fromDB gainDB: Double) -> Float {
        guard gainDB.isFinite else { return 1 }
        return Float(pow(10, gainDB / 20))
    }
}
