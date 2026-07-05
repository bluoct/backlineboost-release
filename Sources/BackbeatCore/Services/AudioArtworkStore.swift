import Foundation

public struct AudioArtworkStore: Sendable {
    public let artworkDirectory: URL

    public init(artworkDirectory: URL = BackbeatFileLocations.artworkDirectory) {
        self.artworkDirectory = artworkDirectory
    }

    public func storeArtwork(_ data: Data?, contentType: String?, trackID: UUID) throws -> URL? {
        guard let data, !data.isEmpty else { return nil }

        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let url = artworkDirectory.appendingPathComponent("\(trackID.uuidString).\(fileExtension(for: contentType, data: data))")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func fileExtension(for contentType: String?, data: Data) -> String {
        let normalizedType = contentType?.lowercased() ?? ""
        if normalizedType.contains("png") || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if normalizedType.contains("jpeg") || normalizedType.contains("jpg") || data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        if normalizedType.contains("gif") || data.starts(with: [0x47, 0x49, 0x46]) {
            return "gif"
        }
        return "artwork"
    }
}
