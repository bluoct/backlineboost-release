import AVFoundation
import CoreMedia
import Foundation

public struct AudioMetadata: Equatable, Sendable {
    public let fileName: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int
    public let artworkData: Data?

    public init(
        fileName: String,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        artworkData: Data? = nil
    ) {
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.artworkData = artworkData
    }

    public var resolvedTitle: String {
        title?.trimmedNonEmpty ?? fileName
    }
}

public struct AudioMetadataReader: Sendable {
    public init() {}

    /// A slim precise-duration probe: no metadata, artwork, or track loading.
    /// Used by the launch backfill sweep so re-checking a track's duration
    /// never pays the cost of a full `read(url:)`.
    public func preciseDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let durationTime = try await asset.load(.duration)
        return CMTimeGetSeconds(durationTime)
    }

    public func read(url: URL) async throws -> AudioMetadata {
        // Prefer precise timing so VBR sources (e.g. VBR MP3) persist an
        // accurate duration instead of AVFoundation's fast estimate, which can
        // drift by more than the render-pair validation tolerance (F1).
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let durationTime = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let firstTrack = tracks.first
        let commonMetadata = try await asset.load(.commonMetadata)

        var sampleRate = 0.0
        var channelCount = 0

        if let firstTrack {
            let descriptions = try await firstTrack.load(.formatDescriptions)
            if let description = descriptions.first,
               let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                sampleRate = streamDescription.pointee.mSampleRate
                channelCount = Int(streamDescription.pointee.mChannelsPerFrame)
            }
        }

        let artworkData = await artworkValue(in: commonMetadata)
        return AudioMetadata(
            fileName: url.deletingPathExtension().lastPathComponent,
            title: await stringValue(for: .commonIdentifierTitle, in: commonMetadata),
            artist: await stringValue(for: .commonIdentifierArtist, in: commonMetadata),
            album: await stringValue(for: .commonIdentifierAlbumName, in: commonMetadata),
            duration: CMTimeGetSeconds(durationTime),
            sampleRate: sampleRate,
            channelCount: channelCount,
            artworkData: artworkData
        )
    }

    private func stringValue(for identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
            if let value = try? await item.load(.stringValue),
               let trimmed = value.trimmedNonEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func artworkValue(in metadata: [AVMetadataItem]) async -> Data? {
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue),
               !data.isEmpty {
                return data
            }
        }
        return nil
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
