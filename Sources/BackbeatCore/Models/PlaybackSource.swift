import Foundation

public enum PlaybackSource: String, CaseIterable, Hashable, Sendable {
    case original
    case drumBoost
    case drumless
    case drums

    public static var boostedDrums: PlaybackSource { .drumBoost }
    public static var controlCases: [PlaybackSource] { [.original, .drumBoost, .drumless] }

    public init(renderVariant: RenderVariant) {
        switch renderVariant {
        case .boostedDrums:
            self = .drumBoost
        case .drums:
            self = .drums
        case .drumless:
            self = .drumless
        }
    }

    public var displayLabel: String {
        switch self {
        case .original:
            "Original"
        case .drumBoost:
            "Drum Boost"
        case .drumless:
            "Drumless"
        case .drums:
            "Drums"
        }
    }
}

extension PlaybackSource: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case Self.original.rawValue:
            self = .original
        case Self.drumBoost.rawValue, "boostedDrums":
            self = .drumBoost
        case Self.drumless.rawValue:
            self = .drumless
        case Self.drums.rawValue:
            self = .drums
        default:
            self = .original
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PlaybackAsset: Equatable, Sendable {
    public let trackID: BackbeatTrack.ID
    public let preferredSource: PlaybackSource
    public let effectiveSource: PlaybackSource
    public let fileURL: URL

    public init(
        trackID: BackbeatTrack.ID,
        preferredSource: PlaybackSource,
        effectiveSource: PlaybackSource,
        fileURL: URL
    ) {
        self.trackID = trackID
        self.preferredSource = preferredSource
        self.effectiveSource = effectiveSource
        self.fileURL = fileURL
    }
}

public struct TwoTrackMixAsset: Equatable, Sendable {
    public let trackID: BackbeatTrack.ID
    public let drumlessURL: URL
    public let drumsURL: URL
    public let duration: TimeInterval
    public let settings: DrumMixSettings

    public init(
        trackID: BackbeatTrack.ID,
        drumlessURL: URL,
        drumsURL: URL,
        duration: TimeInterval,
        settings: DrumMixSettings
    ) {
        self.trackID = trackID
        self.drumlessURL = drumlessURL
        self.drumsURL = drumsURL
        self.duration = duration
        self.settings = settings
    }
}

public struct BackbeatPlaylist: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var trackIDs: [BackbeatTrack.ID]
    public var defaultPlaybackSource: PlaybackSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        trackIDs: [BackbeatTrack.ID] = [],
        defaultPlaybackSource: PlaybackSource = .drumBoost,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.defaultPlaybackSource = defaultPlaybackSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PlaybackRepeatMode: String, CaseIterable, Codable, Hashable, Sendable {
    case off
    case all
    case one
}

public struct PlaybackQueue: Codable, Equatable, Sendable {
    public var playlistID: BackbeatPlaylist.ID?
    public var trackIDs: [BackbeatTrack.ID]
    public var currentIndex: Int
    public var preferredSource: PlaybackSource
    public var repeatMode: PlaybackRepeatMode
    public var isShuffleEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case playlistID
        case trackIDs
        case currentIndex
        case preferredSource
        case repeatMode
        case isShuffleEnabled
    }

    public init(
        playlistID: BackbeatPlaylist.ID? = nil,
        trackIDs: [BackbeatTrack.ID],
        currentIndex: Int = 0,
        preferredSource: PlaybackSource,
        repeatMode: PlaybackRepeatMode = .off,
        isShuffleEnabled: Bool = false
    ) {
        self.playlistID = playlistID
        self.trackIDs = trackIDs
        self.currentIndex = min(max(0, currentIndex), max(0, trackIDs.count - 1))
        self.preferredSource = preferredSource
        self.repeatMode = repeatMode
        self.isShuffleEnabled = isShuffleEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlistID = try container.decodeIfPresent(BackbeatPlaylist.ID.self, forKey: .playlistID)
        trackIDs = try container.decode([BackbeatTrack.ID].self, forKey: .trackIDs)
        let decodedIndex = try container.decode(Int.self, forKey: .currentIndex)
        currentIndex = min(max(0, decodedIndex), max(0, trackIDs.count - 1))
        preferredSource = try container.decode(PlaybackSource.self, forKey: .preferredSource)
        repeatMode = try container.decodeIfPresent(PlaybackRepeatMode.self, forKey: .repeatMode) ?? .off
        isShuffleEnabled = try container.decodeIfPresent(Bool.self, forKey: .isShuffleEnabled) ?? false
    }

    public var currentTrackID: BackbeatTrack.ID? {
        guard trackIDs.indices.contains(currentIndex) else { return nil }
        return trackIDs[currentIndex]
    }
}
