import Foundation

public enum TrackStatus: String, CaseIterable, Codable, Sendable {
    case imported
    case rendering
    case ready
    case renderFailed
    case sourceMissing

    // Libraries saved before the preview step was removed can contain the
    // retired "choosingDrumLevel" status; those tracks decode as imported so
    // the launch scan re-enqueues their render instead of dropping the track.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "choosingDrumLevel" {
            self = .imported
            return
        }
        guard let status = TrackStatus(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown TrackStatus value: \(rawValue)"
            )
        }
        self = status
    }

    public var displayLabel: String {
        switch self {
        case .imported:
            "Imported"
        case .rendering:
            "Rendering..."
        case .ready:
            "Ready"
        case .renderFailed:
            "Render failed"
        case .sourceMissing:
            "Source missing"
        }
    }
}
public enum RenderVariant: String, CaseIterable, Codable, Hashable, Sendable {
    case boostedDrums
    case drums
    case drumless

    public var displayLabel: String {
        switch self {
        case .boostedDrums:
            "Legacy Boosted Drums"
        case .drums:
            "Drums"
        case .drumless:
            "Drumless"
        }
    }
}

public struct DrumMixSettings: Equatable, Codable, Sendable {
    public var boostDB: Double

    private enum CodingKeys: String, CodingKey {
        case boostDB
    }

    public init(boostDB: Double = 4) {
        guard boostDB.isFinite else {
            self.boostDB = 4
            return
        }

        self.boostDB = min(max(boostDB, 0), 8)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(boostDB: try container.decode(Double.self, forKey: .boostDB))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(boostDB, forKey: .boostDB)
    }
}

public struct RenderRecord: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let variant: RenderVariant
    public let fileURL: URL
    public let boostDB: Double
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        variant: RenderVariant,
        fileURL: URL,
        boostDB: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.variant = variant
        self.fileURL = fileURL
        self.boostDB = boostDB
        self.createdAt = createdAt
    }
}

public struct BackbeatTrack: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval
    public var status: TrackStatus
    public var sourceURL: URL
    public var artworkURL: URL?
    public var drumMixSettings: DrumMixSettings
    public var loudnessProfile: TrackLoudnessProfile?
    public private(set) var activeRenders: [RenderVariant: RenderRecord]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case duration
        case status
        case sourceURL
        case artworkURL
        case drumMixSettings
        case loudnessProfile
        case activeRenders
    }

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval,
        status: TrackStatus,
        sourceURL: URL,
        artworkURL: URL? = nil,
        drumMixSettings: DrumMixSettings = DrumMixSettings(),
        loudnessProfile: TrackLoudnessProfile? = nil,
        activeRenders: [RenderVariant: RenderRecord] = [:]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.status = status
        self.sourceURL = sourceURL
        self.artworkURL = artworkURL
        self.drumMixSettings = drumMixSettings
        self.loudnessProfile = loudnessProfile
        self.activeRenders = activeRenders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        status = try container.decode(TrackStatus.self, forKey: .status)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        drumMixSettings = try container.decodeIfPresent(DrumMixSettings.self, forKey: .drumMixSettings) ?? DrumMixSettings()
        loudnessProfile = try container.decodeIfPresent(TrackLoudnessProfile.self, forKey: .loudnessProfile)
        activeRenders = try container.decodeIfPresent([RenderVariant: RenderRecord].self, forKey: .activeRenders) ?? [:]
    }

    public func activeRender(for variant: RenderVariant) -> RenderRecord? {
        activeRenders[variant]
    }

    public mutating func promote(render: RenderRecord) {
        activeRenders[render.variant] = render
        status = .ready
    }

    public mutating func removeRender(for variant: RenderVariant) {
        activeRenders.removeValue(forKey: variant)
    }
}
