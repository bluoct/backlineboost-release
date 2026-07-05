import Foundation

/// Pasteboard vocabulary and metadata parsing for drags that originate in the
/// Apple Music app. Music is iTunes-descended: its drags carry legacy
/// Carbon-style file promises plus an iTunes metadata property list whose
/// track dictionaries hold a `Location` file URL for local tracks.
public enum MusicPasteboardMetadataParser {
    /// Candidate identifiers for the iTunes/Music metadata plist flavor. The
    /// exact identifier is confirmed from the on-machine drag logging; extend
    /// this list if the logged payload uses a different type. Current Music
    /// (Music/TV share one metadata provider) vends `com.apple.tv.metadata`;
    /// the iTunes/Music names remain for older macOS releases.
    public static let metadataTypeIdentifiers: [String] = [
        "com.apple.tv.metadata",
        "com.apple.itunes.metadata",
        "com.apple.music.metadata"
    ]

    /// Legacy Carbon file-promise flavors (kPasteboardTypeFileURLPromise and
    /// kPasteboardTypeFilePromiseContent). Music vends these instead of the
    /// modern NSFilePromiseProvider metadata.
    public static let filePromiseURLTypeIdentifier = "com.apple.pasteboard.promised-file-url"
    public static let filePromiseContentTypeIdentifier = "com.apple.pasteboard.promised-file-content-type"

    public static var filePromiseTypeIdentifiers: [String] {
        [filePromiseURLTypeIdentifier, filePromiseContentTypeIdentifier]
    }

    /// Extracts local audio-file URLs from a Music/iTunes metadata plist of
    /// unknown shape. Walks nested dictionaries and arrays collecting every
    /// `Location` string (the iTunes XML shape is `{"Tracks": {id: dict}}`,
    /// but single dicts and arrays are accepted too), then keeps unique file
    /// URLs whose extension the import filter supports. Malformed input
    /// yields an empty array.
    public static func locationURLs(from data: Data) -> [URL] {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return []
        }

        var locations: [String] = []
        collectLocations(root, into: &locations)

        var seen = Set<String>()
        return locations.compactMap { raw in
            guard seen.insert(raw).inserted else { return nil }
            guard let url = URL(string: raw), url.isFileURL else { return nil }
            let standardized = url.standardizedFileURL
            guard AudioImportFilter.isSupportedAudioFile(standardized) else { return nil }
            return standardized
        }
    }

    /// A track that the Music metadata plist stores as a real local file yet
    /// Backbeat cannot import — a DRM-protected Apple Music download (`.m4p`)
    /// or an unsupported format. Surfaced so a rejected drop explains itself
    /// instead of silently doing nothing.
    public struct UnimportableTrack: Equatable, Sendable {
        public let title: String
        public let isProtected: Bool

        public init(title: String, isProtected: Bool) {
            self.title = title
            self.isProtected = isProtected
        }
    }

    /// Walks the same metadata plist as `locationURLs(from:)` but returns the
    /// tracks whose local `Location` is *not* importable: DRM-protected
    /// downloads or unsupported extensions. Importable tracks are omitted (the
    /// caller imports those); malformed input yields an empty array.
    public static func unimportableTracks(from data: Data) -> [UnimportableTrack] {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return []
        }

        var tracks: [UnimportableTrack] = []
        collectUnimportable(root, into: &tracks)

        var seenTitles = Set<String>()
        return tracks.filter { seenTitles.insert($0.title).inserted }
    }

    private static func collectUnimportable(_ node: Any, into tracks: inout [UnimportableTrack]) {
        if let dictionary = node as? [String: Any] {
            if let raw = dictionary["Location"] as? String,
               let url = URL(string: raw), url.isFileURL {
                let standardized = url.standardizedFileURL
                let isProtected = (dictionary["Protected"] as? Bool) ?? false
                if isProtected || !AudioImportFilter.isSupportedAudioFile(standardized) {
                    let title = (dictionary["Name"] as? String)
                        ?? standardized.deletingPathExtension().lastPathComponent
                    tracks.append(UnimportableTrack(title: title, isProtected: isProtected))
                }
            }
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key] {
                    collectUnimportable(value, into: &tracks)
                }
            }
        } else if let array = node as? [Any] {
            for element in array {
                collectUnimportable(element, into: &tracks)
            }
        }
    }

    private static func collectLocations(_ node: Any, into locations: inout [String]) {
        if let dictionary = node as? [String: Any] {
            if let location = dictionary["Location"] as? String {
                locations.append(location)
            }
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key] {
                    collectLocations(value, into: &locations)
                }
            }
        } else if let array = node as? [Any] {
            for element in array {
                collectLocations(element, into: &locations)
            }
        }
    }
}
