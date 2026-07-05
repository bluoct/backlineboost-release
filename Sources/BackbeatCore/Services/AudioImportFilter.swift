import Foundation
import UniformTypeIdentifiers

public enum AudioImportFilter {
    public static let supportedAudioExtensions: Set<String> = [
        "aac", "aif", "aiff", "flac", "m4a", "mp3", "wav"
    ]

    public static let supportedContentTypes: [UTType] = {
        let explicitTypes: [UTType] = [
            .audio,
            .mpeg4Audio,
            .mp3,
            .wav,
            .aiff
        ]
        let extensionTypes = supportedAudioExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        return uniqueTypes(explicitTypes + extensionTypes)
    }()

    public static func audioFileURLs(from urls: [URL]) -> [URL] {
        urls.filter(isSupportedAudioFile(_:))
    }

    public static func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    private static func uniqueTypes(_ types: [UTType]) -> [UTType] {
        var seenIdentifiers = Set<String>()
        return types.filter { type in
            seenIdentifiers.insert(type.identifier).inserted
        }
    }
}
